-- Host test of the officer tables (.agents/00-plan.md, sections 14.3 and 14.5, step 13.2): the write rule in
-- Addon/Src/Sync/SyncTables.lua, and in the session the push, the pull, the sources, and the announced
-- versions of a table with `writers = "officer"`.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local OFFICER_RANK, MEMBER_RANK = 0, 5
local TABLE = "debugofficer"

---Makes a replica with the developer tables.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param seeded (fun(m: integer?, n: integer?): number)?
---@return TestReplica
local function replica(net, name, rankIndex, seeded)
  return Replica.new(net, name, { random = seeded or random, rankIndex = rankIndex, developerTables = true })
end

---Joins a member that runs no session and records the checked whispers that it receives.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return table member { endpoint, got = { { type, fields, sender } }, Send(type, target, ...), Of(type) }
local function joinRaw(net, name, rankIndex)
  local member = { endpoint = net:Join(name, rankIndex), got = {} }
  member.endpoint.receive = function(text, distribution, sender)
    local messageType, fields = codec.decode(text)
    if distribution == "WHISPER" then
      member.got[#member.got + 1] = { type = messageType, fields = fields, sender = sender }
    end
  end
  ---Sends a hand-made message on the channel of its type.
  function member:Send(messageType, target, ...)
    self.endpoint:Send(codec.encode(messageType, ...), Replica.protocol.CHANNELS[messageType], target)
  end
  ---Returns the fields of the received messages of one type.
  function member:Of(messageType)
    local list = {}
    for _, message in ipairs(self.got) do
      if message.type == messageType then
        list[#list + 1] = message.fields
      end
    end
    return list
  end
  return member
end

---Returns a table version that no replica has: an id of the given time and origin and a fingerprint.
---@param versionId table
---@param time integer
---@param origin string
---@return string
local function versionOf(versionId, time, origin)
  return versionId.make(time, origin, 0) .. "!!!!!"
end

-- Put, Delete, and Append: a member is refused, an officer writes
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local member = replica(net, "Member One")
  local tbl = member.sync:GetTable(TABLE)
  local before = member:Version(TABLE)
  T.eq({ member.sync:Put(TABLE, "key", "text") }, { nil, "not an officer" }, "a Put of a member is refused")
  T.eq(officer.sync:Put(TABLE, "key", "text"), true, "a Put of an officer works")
  T.eq(member:Version(TABLE), before, "a refused Put makes no id")
  -- The record of the officer, as a pull brings it to the member
  member.ns.syncStore.apply(tbl, "key", officer.sync:GetId(TABLE, "key"), "text")
  before = member:Version(TABLE)
  T.eq({ member.sync:Delete(TABLE, "key") }, { nil, "not an officer" }, "a Delete of a member is refused")
  T.eq({ member:Version(TABLE), member.sync:Get(TABLE, "key") }, { before, "text" }, "and changes nothing")
  T.eq(officer.sync:Delete(TABLE, "key"), true, "a Delete of an officer works")
  T.eq({ member.sync:Append(TABLE, "line") }, { nil, "not an officer" }, "an Append of a member is refused")
  T.eq(member:Version(TABLE), before, "and makes no id")
  local id = officer.sync:Append(TABLE, "line")
  T.ok(id, "an Append of an officer works")
  T.eq(officer.sync:Get(TABLE, id), "line", "and stores the record under its id")

  -- NewId and GetId
  T.eq(officer.sync:GetId(TABLE, id), id, "GetId gives the id of a stored record")
  T.eq(officer.sync:GetId(TABLE, "key"), nil, "and nil for a deleted one")
  T.eq(officer.sync:GetId(TABLE, "never"), nil, "and for a missing one")
  local fresh = officer.sync:NewId(TABLE)
  T.ok(fresh > officer.sync:GetTable(TABLE).maxId, "NewId gives an id above everything that the table has seen")
  T.ok(officer.sync:NewId(TABLE) > fresh, "and a greater one the next time")
  T.eq(officer.sync:NewId("no_such_table"), nil, "and nil for a table that is not registered")

  -- The rank follows the roster
  net:SetRank("Member One", OFFICER_RANK)
  T.eq(member.sync:Put(TABLE, "promoted", "text"), true, "a promoted member writes")
  net:SetRank("Member One", MEMBER_RANK)
  T.eq({ member.sync:Put(TABLE, "demoted", "text") }, { nil, "not an officer" }, "a demoted one does not")
  T.eq(member.sync:Put("debug", "open", "text"), true, "a member still writes the table debug")

  -- An officer table names characters inside free keys only
  T.raises(function()
    officer.sync:RegisterTable({ name = "ranked", schema = 1, keyKind = "character", writers = "officer",
      validate = function() return true end, maxRecordBytes = 100 })
  end, "an officer table keyed by character is refused", "writers")
  officer.sync:RegisterTable({ name = "ranked", schema = 1, keyKind = "free", writers = "officer",
    validate = function() return true end, maxRecordBytes = 100 })
  T.eq(officer.sync.definitions.ranked.writers, "officer", "an officer table with free keys is accepted")
end

-- A hand-made push of a member changes nothing, with the own flag true and false
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local member = replica(net, "Member One")
  officer:Login()
  member:Login()
  net:Advance(100)
  local versionId = member.ns.versionId
  local raw = joinRaw(net, "Raw Member")
  local now = math.floor(net:Now())
  local other = versionOf(versionId, now - 5, "RRRR")
  local before = { officer:Version(TABLE), member:Version(TABLE) }
  for index, own in ipairs({ true, false }) do
    raw:Send("P", nil, TABLE, 1, other, other, own, { XXXX = versionId.ZERO },
      Replica.protocol.packRecords({ { key = "forged" .. index, id = versionId.make(now - 10, "XXXX", index),
        payload = "text" } }), { YYYY = versionId.make(now - 9, "YYYY", 0) })
    net:Advance(1)
    for _, receiver in ipairs({ officer, member }) do
      T.eq(receiver.sync:GetTable(TABLE).clock, {}, receiver.name .. " takes no record and no clock value (own "
        .. tostring(own) .. ")")
      T.eq(receiver.session.delayedPullTimer, nil, receiver.name .. " schedules no pull (own " .. tostring(own) .. ")")
      T.eq(receiver.session.peers["Raw Member"].versions[TABLE], other, receiver.name .. " keeps the version")
    end
  end
  T.eq({ officer:Version(TABLE), member:Version(TABLE) }, before, "no version changed")
  net:Advance(600)
  T.eq(Replica.count(net, "Q"), 0, "and nobody asks the member for the table")
  T.eq(officer.session:DifferingTables(officer.session.peers["Raw Member"]), {},
    "the status shows no newer data at the member")

  -- The same push into a table that is not protected is applied
  raw:Send("P", nil, "debug", 1, other, other, true, { XXXX = versionId.ZERO },
    Replica.protocol.packRecords({ { key = "open", id = versionId.make(now - 8, "XXXX", 0), payload = "text" } }))
  net:Advance(1)
  T.eq(member.sync:Get("debug", "open"), "text", "a push of a member into the table debug is applied")

  -- A pull request of a member for an officer table: a member is no source, an officer is
  raw:Send("Q", "Member One", TABLE, 1, 5, "")
  raw:Send("Q", "Officer One", TABLE, 1, 6, "")
  net:Advance(5)
  T.eq(raw:Of("B"), { { table = TABLE, nonce = 5, reason = "source", retry = 3600 } },
    "a member refuses a pull of an officer table with the reason source")
  T.eq(#raw:Of("D"), 1, "an officer answers it")
end

-- A hand-made delta: from the source while it is an officer it is applied, after its demotion it is not
do
  local net = Fakenet.new({ random = random })
  local member = replica(net, "Member One")
  member:Login()
  net:Advance(100)
  local versionId = member.ns.versionId
  local source, stranger = joinRaw(net, "Raw Officer", OFFICER_RANK), joinRaw(net, "Raw Member")
  local now = math.floor(net:Now())
  ---Lets the raw officer announce a version and waits for the pull request of the member.
  ---@return integer nonce
  local function awaitRequest(version)
    source.got = {}
    source:Send("S", nil, { [TABLE] = version })
    local waited = 0
    -- In small steps: the pull ends when no batch comes for a minute
    while #source:Of("Q") == 0 and waited < 130 do
      net:Advance(0.5)
      waited = waited + 0.5
    end
    local requests = source:Of("Q")
    T.eq(#requests, 1, "the member asks the officer")
    return requests[1].nonce
  end
  local nonce = awaitRequest(versionOf(versionId, now - 5, "OOOO"))
  local good = versionId.make(now - 50, "OOOO", 0)
  stranger:Send("D", "Member One", TABLE, nonce, 1, true,
    Replica.protocol.packRecords({ { key = "forged", id = versionId.make(now - 60, "XXXX", 0), payload = "x" } }))
  net:Advance(1)
  T.eq(member.sync:GetTable(TABLE).clock, {}, "a delta from a member who is not the source changes nothing")
  source:Send("D", "Member One", TABLE, nonce, 1, true,
    Replica.protocol.packRecords({ { key = "good", id = good, payload = "text" } }))
  net:Advance(1)
  T.eq(member.sync:Get(TABLE, "good"), "text", "a delta from the officer is applied")

  nonce = awaitRequest(versionOf(versionId, now + 5, "OOOO"))
  local before = member:Version(TABLE)
  net:SetRank("Raw Officer", MEMBER_RANK)
  source:Send("D", "Member One", TABLE, nonce, 1, true,
    Replica.protocol.packRecords({ { key = "late", id = versionId.make(now - 40, "OOOO", 0), payload = "text" } }))
  net:Advance(1)
  T.eq({ member:Version(TABLE), member.sync:Get(TABLE, "late") }, { before, nil },
    "a delta of the source after its demotion changes nothing")
end

-- Sources: a member with a newer version is not asked, an officer with an older one is
do
  local pull = Replica.new(Fakenet.new({ random = random }), "Lone One", { random = random }).ns.syncPull
  local newer, older = "!!!!#NNNN!!!!!!!", "!!!!\"OOOO!!!!!!!"
  local peers = {
    { name = "Member", versions = { [TABLE] = newer }, order = 1 },
    { name = "Officer", versions = { [TABLE] = older }, order = 2 },
  }
  local own = "!!!!!!!!!!!!!!!!"
  T.eq(pull.chooseSource(peers, TABLE, own, nil, 0).name, "Member", "without a filter the newest is the source")
  T.eq(pull.chooseSource(peers, TABLE, own, nil, 0, function(peer) return peer.name == "Officer" end).name,
    "Officer", "with the filter of officers the older officer is")
  T.eq(pull.chooseSource(peers, TABLE, own, nil, 0, function() return false end), nil,
    "and nobody when no peer passes")

  local net = Fakenet.new({ random = random })
  local member = replica(net, "Member One")
  member:Login()
  net:Advance(100)
  local versionId = member.ns.versionId
  local now = math.floor(net:Now())
  local rawMember, rawOfficer = joinRaw(net, "Raw Member"), joinRaw(net, "Raw Officer", OFFICER_RANK)
  rawMember:Send("S", nil, { [TABLE] = versionOf(versionId, now - 5, "NNNN") })
  rawOfficer:Send("S", nil, { [TABLE] = versionOf(versionId, now - 50, "OOOO") })
  net:Advance(500)
  T.ok(#rawOfficer:Of("Q") >= 1, "the member asks the officer with the older version")
  T.eq(#rawMember:Of("Q"), 0, "and never the member with the newer one")
  T.eq(member.session:DifferingTables(member.session.peers["Raw Member"]), {},
    "the status shows no newer data at the member")
end

-- A member's announcement does not hold back the answer or the summary of an officer
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local member = replica(net, "Member One")
  officer:Login()
  member:Login()
  net:Advance(100)
  officer.sync:Put(TABLE, "key", "text")
  net:Advance(100)
  T.eq(member:Version(TABLE), officer:Version(TABLE), "the member holds the officer's version")
  local asker, rawMember = joinRaw(net, "Asker One"), joinRaw(net, "Raw Member")
  local rawOfficer = joinRaw(net, "Raw Officer", OFFICER_RANK)
  local other = "!!!!!ZZZZ!!!!!!!"
  -- The real member would answer too; it is taken offline, so that only the hand-made messages count
  member:Logout()
  net:Advance(10)
  local since = net:Now()
  asker:Send("H", nil, { [TABLE] = other })
  net:Advance(0.5)
  rawMember:Send("S", nil, { [TABLE] = officer:Version(TABLE) })
  net:Advance(20)
  T.eq(Replica.count(net, "S", "Officer One", since), 1, "the officer answers although a member announced its version")
  T.eq(officer.session.heardOwn[TABLE], nil, "and the member's summary does not count for the periodic one")

  since = net:Now()
  asker:Send("H", nil, { [TABLE] = other })
  net:Advance(0.5)
  rawOfficer:Send("S", nil, { [TABLE] = officer:Version(TABLE) })
  net:Advance(20)
  T.eq(Replica.count(net, "S", "Officer One", since), 0, "another officer with the same version holds it back")
  T.eq(officer.session.heardOwn[TABLE], officer:Version(TABLE), "also for the periodic summary")

  -- A member's own answer is held back by a member, as before
  member:Login()
  net:Advance(100)
  since = net:Now()
  asker:Send("H", nil, { [TABLE] = other })
  net:Advance(0.5)
  rawMember:Send("S", nil, { [TABLE] = member:Version(TABLE) })
  net:Advance(20)
  T.eq(Replica.count(net, "S", "Member One", since), 0, "a member's answer is held back by another member")
end

-- With no officer online, a member that logs in pulls nothing and asks nobody
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local first = replica(net, "Member One")
  officer:Login()
  first:Login()
  net:Advance(100)
  officer.sync:Put(TABLE, "key", "text")
  net:Advance(100)
  T.eq(first.sync:Get(TABLE, "key"), "text", "the member online has the officer's record")
  officer:Logout()
  net:Advance(10)
  local since = net:Now()
  local late = replica(net, "Member Two")
  late:Login()
  net:Advance(3600)
  T.ok(late.session.peers["Member One"], "the member that logged in knows the other member")
  T.eq(late.session.peers["Member One"].versions[TABLE], first:Version(TABLE), "with its version of the table")
  T.eq(Replica.count(net, "Q", nil, since), 0, "nobody is asked for the table")
  T.eq(late.sync:Get(TABLE, "key"), nil, "and the member that logged in does not have the record")
end

-- A demoted officer: its earlier records stay, its next push is ignored
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local member = replica(net, "Member One")
  officer:Login()
  member:Login()
  net:Advance(100)
  officer.sync:Put(TABLE, "early", "before the demotion")
  net:Advance(60)
  T.eq(member.sync:Get(TABLE, "early"), "before the demotion", "the member has the officer's record")
  officer.sync:Put(TABLE, "unsent", "written just before the demotion")
  net:SetRank("Officer One", MEMBER_RANK)
  net:Advance(600)
  T.eq(member.sync:Get(TABLE, "early"), "before the demotion", "the earlier record stays")
  T.eq(member.sync:Get(TABLE, "unsent"), nil, "a demoted officer does not push its unsent write")
  T.ok(officer.sync.dirtySince[TABLE], "which stays marked as unsent")
  T.eq({ officer.sync:Put(TABLE, "late", "text") }, { nil, "not an officer" }, "it cannot write any more")
  -- A push that its addon sends anyway
  local versionId, now = officer.ns.versionId, math.floor(net:Now())
  local origin = officer.sync:GetOrigin()
  local tbl = officer.sync:GetTable(TABLE)
  local forged = versionId.make(now + 1, origin, 0)
  officer.endpoint:Send(codec.encode("P", TABLE, 1, officer:Version(TABLE), officer:Version(TABLE), true,
    { [origin] = tbl.clock[origin] }, Replica.protocol.packRecords({ { key = "late", id = forged, payload = "x" } })),
    "GUILD")
  net:Advance(1)
  T.eq(member.sync:Get(TABLE, "late"), nil, "its next push is ignored")
  T.eq(member.sync:Get(TABLE, "unsent"), nil, "with the write before it")

  -- Promoted again, the unsent write goes out after the next login
  net:SetRank("Officer One", OFFICER_RANK)
  officer:Logout()
  net:Advance(10)
  officer:Login()
  net:Advance(200)
  T.eq(member.sync:Get(TABLE, "unsent"), "written just before the demotion", "the write waited for an officer")
end

-- An owner table and the table debug in the same network: a member writes, pushes, relays, and is a source
do
  local net = Fakenet.new({ random = random })
  local function withGear(name)
    local made = replica(net, name)
    made.sync:RegisterTable({ name = "gear", schema = 1, keyKind = "character", writers = "owner",
      validate = function(_key, payload) return type(payload) == "number" end, maxRecordBytes = 100,
      policy = { pushDelay = 10, minInterval = 30 } })
    return made
  end
  local a, b = withGear("Member One"), withGear("Member Two")
  a:Login()
  b:Login()
  net:Advance(100)
  T.eq(a.sync:Put("gear", "Member One", 1), true, "a member writes its record of an owner table")
  T.eq(a.sync:Put("debug", "key", "text"), true, "and a record of the table debug")
  net:Advance(60)
  T.eq({ b.sync:Get("gear", "Member One"), b.sync:Get("debug", "key") }, { 1, "text" }, "its push reaches a member")
  local c = withGear("Member Three")
  net:SetOnline("Member Three", false)
  c.sync:Put("gear", "Member Three", 3)
  c.sync:Put("debug", "offline", "written offline")
  local since = net:Now()
  c:Login()
  net:Advance(400)
  T.ok(Replica.count(net, "Q", "Member Three", since) >= 1, "the member that logs in asks a member")
  T.eq(c.sync:Get("gear", "Member One"), 1, "and gets the records from it")
  local relayed = false
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "P" and entry.from == "Member Three" and entry.time >= since and fields.own == false then
      relayed = true
    end
  end
  T.ok(relayed, "after the pull it passes its records on as a member")
  for _, other in ipairs({ a, b }) do
    T.eq({ other:Version("gear"), other:Version("debug") }, { c:Version("gear"), c:Version("debug") },
      other.name .. " ends equal")
  end
end

---Runs three officers and five members with random writes of the officers, loss, and offline periods, then
---lets the network settle with everybody online.
---@param seed integer
---@return TestReplica[]
local function simulate(seed)
  local seeded = T.newRandom(seed)
  local net = Fakenet.new({ random = seeded, loss = 0.05 })
  local replicas, online = {}, {}
  for index = 1, 8 do
    local isOfficer = index <= 3
    replicas[index] = replica(net, (isOfficer and "Officer " or "Member ") .. index,
      isOfficer and OFFICER_RANK or MEMBER_RANK, seeded)
    replicas[index]:Login()
    online[index] = true
  end
  net:Advance(100)
  for _ = 1, 120 do
    local index = seeded(1, 8)
    local current = replicas[index]
    local action = seeded(1, 10)
    if action <= 4 then
      -- A member's write is refused; an officer's goes out, also while it is offline (after its next login)
      current.sync:Put(TABLE, "key" .. seeded(1, 15), "text " .. seeded(1, 1000000))
    elseif action == 5 then
      current.sync:Delete(TABLE, "key" .. seeded(1, 15))
    elseif action == 6 then
      if online[index] then
        current:Logout()
      else
        current:Login()
      end
      online[index] = not online[index]
    end
    net:Advance(20)
  end
  for index, current in ipairs(replicas) do
    if not online[index] then
      current:Login()
    end
  end
  net:Advance(4 * 3600)
  return replicas
end

for seed = 1, 10 do
  local replicas = simulate(seed)
  local first = replicas[1]
  for index = 2, #replicas do
    T.eq(replicas[index]:Version(TABLE), first:Version(TABLE),
      "seed " .. seed .. ": version of " .. replicas[index].name)
    T.eq(replicas[index].sync:GetTable(TABLE).records, first.sync:GetTable(TABLE).records,
      "seed " .. seed .. ": records of " .. replicas[index].name)
  end
  T.ok(first.sync:Count(TABLE) > 0, "seed " .. seed .. ": the table is not empty")
  for index = 4, 8 do
    local origin = replicas[index].sync:GetOrigin()
    T.eq(first.sync:GetTable(TABLE).clock[origin], nil, "seed " .. seed .. ": no write of member " .. index)
  end
end

T.finish()
