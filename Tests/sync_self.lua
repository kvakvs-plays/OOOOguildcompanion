-- Host test of the self tables (.agents/00-plan.md, sections 14.3 and 14.4): the character origins and the
-- push marks per origin (step 13.3) in Addon/Src/Sync/SyncTables.lua and SyncPush.lua.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local random = T.newRandom()
local FILES = { "Addon/Src/Slash.lua", "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncTables.lua",
  "Addon/Src/Sync/SyncCharacter.lua" }

---The definition of a self table with a text payload
local function selfDefinition()
  return { name = "mine", schema = 1, keyKind = "character", writers = "self", maxRecordBytes = 200,
    validate = function(_key, payload) return type(payload) == "string" end }
end

---Loads a registry with the table `mine` and a free table `open`, and connects it to a stored database.
---@param data table
---@param playerName fun(): string|nil
---@param now fun(): integer
---@return table sync
---@return table ns
local function newSync(data, playerName, now)
  local ns = T.loadAll(FILES)
  ns.sync:RegisterTable(selfDefinition())
  ns.sync:RegisterTable({ name = "open", schema = 1, keyKind = "free", writers = "anyone", maxRecordBytes = 200,
    validate = function() return true end })
  ns.sync:Initialize(data, now, random, playerName)
  return ns.sync, ns
end

-- The registry: a self table is keyed by character
do
  local ns = T.loadAll(FILES)
  local definition = selfDefinition()
  definition.keyKind = "free"
  T.raises(function() ns.sync:RegisterTable(definition) end, "a self table with free keys is refused", "writers")
  ns.sync:RegisterTable(selfDefinition())
  T.eq(ns.sync.definitions.mine.writers, "self", "a self table keyed by character is accepted")
  T.eq(ns.sync:IsProtected("mine"), true, "and is protected")
  T.eq(ns.sync:IsProtected("character"), false, "an owner table is not")
end

-- Character origins: one per install and character, the install origin elsewhere
do
  local data = { origin = "XXXX", tables = {} }
  local player = "Nota Scam" ---@type string|nil
  local clock = 1795000000
  local sync, ns = newSync(data, function() return player end, function() return clock end)
  local base94, versionId = ns.base94, ns.versionId
  local scam = sync:OriginFor("mine")
  T.eq(scam, base94.encode(base94.hash("XXXX:Nota Scam") % 78074896, 4), "the origin is the hash of install and name")
  T.eq(#scam, 4, "of 4 characters")
  T.ok(base94.isValid(scam), "of base 94")
  T.eq(sync:OriginFor("open"), "XXXX", "another table has the install origin")
  T.eq(sync:OriginFor("character"), "XXXX", "also an owner table")
  T.eq(sync:OriginFor("no_such_table"), nil, "a table that is not registered has none")
  player = "Nota Tall"
  local tall = sync:OriginFor("mine")
  T.ok(tall ~= scam and tall ~= "XXXX", "an alt of the same install has another origin")
  player = nil
  T.eq(sync:OriginFor("mine"), nil, "without the name of the character there is no origin")
  T.eq({ sync:Put("mine", "Nota Scam", "text") }, { nil, "not ready" }, "and a write is refused as not ready")
  T.eq(sync:NewId("mine"), nil, "and NewId gives nothing")
  T.eq(sync:Put("open", "key", "text"), true, "another table is written without the name")

  -- Ids: of the origin of the table, increasing
  player = "Nota Scam"
  local previous = versionId.ZERO
  for index = 1, 20 do
    T.eq(sync:Put("mine", "Nota Scam:" .. index, "text"), true, "a write under the own name works")
    local id = sync:GetId("mine", "Nota Scam:" .. index)
    T.eq(versionId.originOf(id), scam, "its id has the character origin")
    T.ok(id > previous, "the ids of one origin increase")
    previous = id
    if index % 5 == 0 then
      -- Other origins write in between, also in the same second
      ns.syncStore.apply(data.tables.mine, "Other One", versionId.make(clock + 1, "ZZZZ", index), "x")
    end
  end
  T.eq(versionId.originOf(sync:GetId("open", "key")), "XXXX", "the id in another table has the install origin")
  T.eq(versionId.originOf(sync:NewId("mine")), scam, "NewId of a self table has the character origin")
  T.eq(versionId.originOf(sync:NewId("open")), "XXXX", "and of another table the install origin")
  player = "Nota Tall"
  T.eq(sync:Put("mine", "Nota Tall", "alt"), true, "the alt writes under its own name")
  local altId = sync:GetId("mine", "Nota Tall")
  T.eq(versionId.originOf(altId), tall, "with its own origin")
  T.ok(altId > previous, "above everything that the table has seen")
  T.eq(data.tables.mine.clock[scam], previous, "the clock keeps one entry per character")
  T.eq(data.tables.mine.clock[tall], altId, "and one for the alt")

  -- Another session of the same install: the same origins
  clock = clock + 3600
  local again = newSync(data, function() return "Nota Scam" end, function() return clock end)
  T.eq(again:OriginFor("mine"), scam, "the origin of a character is the same in every session")
  T.eq(again:Put("mine", "Nota Scam:again", "text"), true, "and a write after the login works")
  T.ok(again:GetId("mine", "Nota Scam:again") > previous, "with an id above the earlier ones")
  T.eq(versionId.originOf(again:GetId("mine", "Nota Scam:again")), scam, "of the same origin")
  local other = newSync({ origin = "YYYY", tables = {} }, function() return "Nota Scam" end,
    function() return clock end)
  T.ok(other:OriginFor("mine") ~= scam, "the same name on another install has another origin")
end

-- The push mark of a character origin is kept per origin; the install origin keeps `pushed`
do
  local Fakenet = dofile("Tests/fakenet.lua")
  local Replica = dofile("Tests/fixtures/replica.lua")(T)
  local net = Fakenet.new({ random = random })
  local function withMine(name, rankIndex)
    local made = Replica.new(net, name, { random = random, rankIndex = rankIndex })
    local definition = selfDefinition()
    definition.policy = { pushDelay = 10, minInterval = 30 }
    made.sync:RegisterTable(definition)
    return made
  end
  -- The writer is an officer: in this step a self table takes only what an officer sends
  local a, b = withMine("Nota Scam", 0), withMine("Other One")
  a:Login()
  b:Login()
  net:Advance(100)
  a.sync:Put("mine", "Nota Scam", "text")
  a.sync:Put("debug", "key", "text")
  net:Advance(60)
  local mine, debug = a.sync:GetTable("mine"), a.sync:GetTable("debug")
  local origin = a.sync:OriginFor("mine")
  T.eq(mine.pushedBy, { [origin] = mine.clock[origin] }, "the push mark of the character origin is kept per origin")
  T.eq(mine.pushed, nil, "the mark of the install origin is not touched")
  T.eq(debug.pushed, debug.clock[a.sync:GetOrigin()], "another table keeps its mark in pushed")
  T.eq(b.sync:Get("mine", "Nota Scam"), "text", "the record arrives")
  local count = Replica.count(net, "P", "Nota Scam")
  a:Logout()
  net:Advance(10)
  a:Login()
  net:Advance(200)
  T.eq(Replica.count(net, "P", "Nota Scam"), count, "after the next login nothing is pushed again")
  a.sync:Reset("mine")
  T.eq(mine.pushedBy, { [origin] = mine.pushedBy[origin] }, "an emptied table keeps the push mark")
end

--------------------------------------------------------------------------------
-- Step 13.4: the rules of a self table, with the developer table `debugself`
--------------------------------------------------------------------------------

local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)
local codec = Replica.codec
local TABLE = "debugself"
local OFFICER_RANK = 0

---Makes a replica with the developer tables.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param options table? Further options of `Replica.new`
---@return TestReplica
local function replica(net, name, rankIndex, options)
  options = options or {}
  options.random = options.random or random
  options.rankIndex = rankIndex
  options.developerTables = true
  return Replica.new(net, name, options)
end

---Joins a member that runs no session and records the checked whispers that it receives.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return table member
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
  ---Returns the fields of the received whispers of one type.
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

---Sends a hand-made push of records of one origin with the zero base, which is never a gap.
---@param member table From `joinRaw`
---@param own boolean
---@param origin string
---@param records OOOOSyncWireRecord[]
---@param rest table<string, string>?
local function pushAs(member, own, origin, records, rest)
  local version = "!!!!!RRRR!!!!!!!"
  -- A clock rest is taken only for an origin with a base
  local base = { [origin] = "!!!!!!!!!!!" }
  for restOrigin in pairs(rest or {}) do
    base[restOrigin] = "!!!!!!!!!!!"
  end
  member:Send("P", nil, TABLE, 1, version, version, own, base, Replica.protocol.packRecords(records), rest)
end

-- Put and Delete: under the own name only; an alt does not count
do
  local data = { origin = "XXXX", tables = {} }
  local player = "Nota Scam"
  local ns = T.loadAll(FILES)
  T.loadAll({ "Addon/Src/Sync/SyncCommands.lua" }, ns)
  ns.syncCommands.EnableDeveloperTables()
  local sync = ns.sync
  sync:Initialize(data, function() return 1795000000 end, random, function() return player end)
  sync:Put("character", "Nota Scam", { class = "MAGE", level = 10, origins = { "XXXX" } })
  player = "Nota Tall"
  sync:Put("character", "Nota Tall", { class = "MAGE", level = 10, origins = { "XXXX" } })
  T.eq(sync:IsAltOf("Nota Scam", "Nota Tall"), true, "the two characters are alts")
  player = "Nota Scam"
  T.eq(sync:Put(TABLE, "Nota Scam", "text"), true, "a Put under the own name works")
  T.eq(sync:Put(TABLE, "Nota Scam:2", "text"), true, "also with a joined key")
  T.eq({ sync:Put(TABLE, "Other One", "text") }, { nil, "not the owner" }, "a Put under another name is refused")
  T.eq({ sync:Put(TABLE, "Nota Tall", "text") }, { nil, "not the owner" }, "and under the name of an alt")
  T.eq({ sync:Append(TABLE, "text") }, { nil, "bad key" }, "an Append is refused: an id names no character")
  player = "Nota Tall"
  T.eq(sync:Put(TABLE, "Nota Tall", "alt"), true, "the alt writes its own key")
  T.eq({ sync:Delete(TABLE, "Nota Scam") }, { nil, "not the owner" }, "but cannot delete the key of its main")
  player = "Nota Scam"
  T.eq({ sync:Delete(TABLE, "Nota Tall") }, { nil, "not the owner" }, "nor the main the key of its alt")
  T.eq(sync:Delete(TABLE, "Nota Scam:2"), true, "a Delete under the own name works")
end

-- The commands of the developer table: the key is a name with a space
do
  local net = Fakenet.new({ random = random })
  local a = replica(net, "Nota Scam")
  local function run(command)
    a.ns.syncSlash:Dispatch(command)
    return a.notices[#a.notices]
  end
  T.eq(run("put debugself Nota Scam hello there"), "written: Nota Scam", "put takes the own name with a space")
  T.eq(a.sync:Get(TABLE, "Nota Scam"), "hello there", "and the rest as text")
  T.eq(run("put debugself me:2 second"), "written: Nota Scam:2", "me stands for the own name, with a suffix")
  T.eq(run("put debugself Nota Scam:3 third"), "written: Nota Scam:3", "the own name takes a suffix too")
  T.eq(run("put debugself Other One hello"), "not written: not the owner", "another name is refused")
  T.eq(run("get debugself Nota Scam"), "Nota Scam = hello there", "get reads by the name")
  T.eq(run("get debugself me:2"), "Nota Scam:2 = second", "also with me")
  T.eq(run("del debugself Nota Scam:3"), "deleted: Nota Scam:3", "del deletes by the name")
  T.eq(run("put debugself Nota Scam"), "Usage: /oooo sync put [debugofficer|debugself] <key> <text>",
    "a put without text prints its usage")
  T.eq(run("put debugofficer key text"), "not written: not an officer", "debugofficer names the officer table")
  T.eq(run("put key text"), "written: key", "without a table word the table is debug, as before")
  T.eq(a.sync:Get("debug", "key"), "text", "with the first word as key")
end

-- A hand-made push of a member: only the records that name the sender are taken, whatever the own flag
do
  local net = Fakenet.new({ random = random })
  local officer, member = replica(net, "Officer One", OFFICER_RANK), replica(net, "Member One")
  officer:Login()
  member:Login()
  net:Advance(100)
  local versionId = member.ns.versionId
  local raw = joinRaw(net, "Raw Member")
  local now = math.floor(net:Now())
  for index, own in ipairs({ true, false }) do
    local origin = own and "XXXX" or "WWWW"
    local first, foreign, later = versionId.make(now - 30, origin, index), versionId.make(now - 20, origin, index),
      versionId.make(now - 10, origin, index)
    pushAs(raw, own, origin, {
      { key = "Raw Member:" .. index, id = first, payload = "own record" },
      { key = "Member One", id = foreign, payload = "forged" },
      { key = "Raw Member", id = later, payload = "after the forged one" },
    }, { ZZZZ = versionId.make(now - 5, "ZZZZ", 0) })
    net:Advance(1)
    for _, receiver in ipairs({ officer, member }) do
      local what = receiver.name .. " (own " .. tostring(own) .. ")"
      T.eq(receiver.sync:Get(TABLE, "Raw Member:" .. index), "own record", what .. " applies the record of the sender")
      T.eq(receiver.sync:Get(TABLE, "Member One"), nil, what .. " drops the record of another name")
      T.eq(receiver.sync:Get(TABLE, "Raw Member"), nil, what .. " and the later records of its origin")
      T.eq(receiver.sync:GetTable(TABLE).clock[origin], first, what .. ": the clock stays before the dropped one")
      T.eq(receiver.sync:GetTable(TABLE).clock.ZZZZ, nil, what .. " ignores the clock rest of a member")
      T.eq(receiver.session.delayedPullTimer, nil, what .. " schedules no pull from a member")
    end
  end

  -- The same from an officer: every record and the clock rest are taken
  local rawOfficer = joinRaw(net, "Raw Officer", OFFICER_RANK)
  local x1, x2 = versionId.make(now - 9, "VVVV", 0), versionId.make(now - 8, "VVVV", 0)
  local rest = versionId.make(now - 7, "UUUU", 0)
  pushAs(rawOfficer, false, "VVVV", {
    { key = "Member One", id = x1, payload = "vouched" },
    { key = "Raw Member:9", id = x2, payload = "vouched too" },
  }, { UUUU = rest })
  net:Advance(1)
  T.eq({ member.sync:Get(TABLE, "Member One"), member.sync:Get(TABLE, "Raw Member:9") }, { "vouched", "vouched too" },
    "a push of an officer is applied with the records of any name")
  T.eq(member.sync:GetTable(TABLE).clock.UUUU, rest, "and with its clock rest")
end

-- A hand-made delta: a member is never the source, and a demoted source is no longer taken
do
  local net = Fakenet.new({ random = random })
  local member = replica(net, "Member One")
  member:Login()
  net:Advance(100)
  local versionId = member.ns.versionId
  local now = math.floor(net:Now())
  local rawMember, rawOfficer = joinRaw(net, "Raw Member"), joinRaw(net, "Raw Officer", OFFICER_RANK)
  rawMember:Send("S", nil, { [TABLE] = versionId.make(now, "NNNN", 0) .. "!!!!!" })
  rawOfficer:Send("S", nil, { [TABLE] = versionId.make(now - 50, "OOOO", 0) .. "!!!!!" })
  local waited = 0
  while #rawOfficer:Of("Q") == 0 and waited < 130 do
    net:Advance(0.5)
    waited = waited + 0.5
  end
  T.eq(#rawOfficer:Of("Q"), 1, "the member asks the officer")
  T.eq(#rawMember:Of("Q"), 0, "and not the member with the newer version")
  local nonce = rawOfficer:Of("Q")[1].nonce
  rawMember:Send("D", "Member One", TABLE, nonce, 1, true,
    Replica.protocol.packRecords({ { key = "Raw Member", id = versionId.make(now - 9, "NNNN", 0), payload = "x" } }))
  net:Advance(1)
  T.eq(member.sync:GetTable(TABLE).clock, {}, "a delta of a member changes nothing")
  net:SetRank("Raw Officer", 5)
  rawOfficer:Send("D", "Member One", TABLE, nonce, 1, true,
    Replica.protocol.packRecords({ { key = "Raw Officer", id = versionId.make(now - 9, "OOOO", 0), payload = "x" } }))
  net:Advance(1)
  T.eq(member.sync:GetTable(TABLE).clock, {}, "nor one of the source after its demotion")
end

-- firstHand: true for the push of the owner, false for the same record from an officer and for a pull
do
  local net = Fakenet.new({ random = random })
  local member = replica(net, "Member One")
  member:Login()
  net:Advance(100)
  local seen = {}
  member.sync.RegisterCallback(seen, "OnRecordChanged", function(_event, tableName, key, _payload, isRemote, firstHand)
    if tableName == TABLE then
      seen[#seen + 1] = { key = key, isRemote = isRemote, firstHand = firstHand }
    end
  end)
  local versionId = member.ns.versionId
  local now = math.floor(net:Now())
  local owner, rawOfficer = joinRaw(net, "Raw Member"), joinRaw(net, "Raw Officer", OFFICER_RANK)
  pushAs(owner, true, "XXXX", { { key = "Raw Member", id = versionId.make(now - 9, "XXXX", 0), payload = "first" } })
  net:Advance(1)
  pushAs(rawOfficer, false, "XXXX", { { key = "Raw Member", id = versionId.make(now - 8, "XXXX", 0),
    payload = "second" } })
  net:Advance(1)
  pushAs(rawOfficer, true, "OOOO", { { key = "Raw Officer", id = versionId.make(now - 7, "OOOO", 0),
    payload = "own" } })
  net:Advance(1)
  member.sync:Put(TABLE, "Member One", "local")
  T.eq(seen, {
    { key = "Raw Member", isRemote = true, firstHand = true },
    { key = "Raw Member", isRemote = true, firstHand = false },
    { key = "Raw Officer", isRemote = true, firstHand = true },
    { key = "Member One", isRemote = false, firstHand = true },
  }, "first hand: the owner's push and a local write; not the same record passed on by an officer")
  -- A pull is never first hand
  for index = #seen, 1, -1 do
    seen[index] = nil
  end
  rawOfficer:Send("S", nil, { [TABLE] = versionId.make(now - 1, "OOOO", 0) .. "!!!!!" })
  local waited = 0
  while #rawOfficer:Of("Q") == 0 and waited < 130 do
    net:Advance(0.5)
    waited = waited + 0.5
  end
  rawOfficer:Send("D", "Member One", TABLE, rawOfficer:Of("Q")[1].nonce, 1, true,
    Replica.protocol.packRecords({ { key = "Raw Officer", id = versionId.make(now - 1, "OOOO", 0), payload = "x" } }))
  net:Advance(1)
  T.eq(#seen, 1, "a pull brings the record")
  T.ok(not seen[1].firstHand, "and it is not first hand")
end

-- A member writes while no officer is online; an officer who logs in later gets it and passes it on
do
  local net = Fakenet.new({ random = random })
  local writer, other = replica(net, "Member One"), replica(net, "Member Two")
  local late, officer = replica(net, "Member Three"), replica(net, "Officer One", OFFICER_RANK)
  net:SetOnline("Member Three", false)
  net:SetOnline("Officer One", false)
  writer:Login()
  other:Login()
  net:Advance(100)
  writer.sync:Put(TABLE, "Member One", "written without an officer")
  net:Advance(60)
  T.eq(other.sync:Get(TABLE, "Member One"), "written without an officer", "the members online hold the record")
  -- The officer wrote while it was away, so its version differs from every member's. Its push misses the
  -- writer, which then pulls from the officer and gives it its record after the pull. (When the writer takes
  -- the push, it holds the officer's version and has no reason to pull; then the delivery of step 13.5 brings
  -- the record to the officer.)
  net.dropIf = function(entry, to)
    return to == "Member One" and entry.from == "Officer One" and codec.decode(entry.text) == "P"
  end
  officer.sync:Put(TABLE, "Officer One", "written offline")
  officer:Login()
  net:Advance(400)
  net.dropIf = nil
  T.eq(officer.sync:Get(TABLE, "Member One"), "written without an officer", "the officer gets it from the writer")
  T.eq(writer.sync:Get(TABLE, "Officer One"), "written offline", "and the writer the officer's record")
  late:Login()
  net:Advance(400)
  T.eq(late.sync:Get(TABLE, "Member One"), "written without an officer", "a member who was offline gets it")
  for _, current in ipairs({ writer, other, late }) do
    T.eq(current:Version(TABLE), officer:Version(TABLE), current.name .. " ends equal to the officer")
  end
end

-- An unsent write of an alt stays unsent while the main character plays, and goes out with the alt
do
  local net = Fakenet.new({ random = random })
  local officer, member = replica(net, "Officer One", OFFICER_RANK), replica(net, "Member Two")
  local main = replica(net, "Nota Scam")
  local alt = replica(net, "Nota Tall", nil, { data = main.data })
  net:SetOnline("Nota Scam", false)
  net:SetOnline("Nota Tall", false)
  officer:Login()
  member:Login()
  net:Advance(100)
  alt:Login()
  net:Advance(1)
  alt.sync:Put(TABLE, "Nota Tall", "written by the alt")
  -- Logged out before the push delay has passed
  alt:Logout()
  net:Advance(10)
  local since = net:Now()
  main:Login()
  main.sync:Put(TABLE, "Nota Scam", "written by the main")
  net:Advance(3600)
  T.eq(officer.sync:Get(TABLE, "Nota Scam"), "written by the main", "the main's write goes out")
  T.eq(officer.sync:Get(TABLE, "Nota Tall"), nil, "the alt's write stays unsent while the main plays")
  T.eq(member.sync:Get(TABLE, "Nota Tall"), nil, "also for a member")
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "P" and entry.from == "Nota Scam" and entry.time >= since then
      for _, record in ipairs(fields.records) do
        T.ok(record.key ~= "Nota Tall", "no push of the main carries the alt's record")
      end
    end
  end
  main:Logout()
  net:Advance(10)
  alt:Login()
  net:Advance(200)
  T.eq(officer.sync:Get(TABLE, "Nota Tall"), "written by the alt", "it reaches the officer when the alt logs in")
  T.eq(member.sync:Get(TABLE, "Nota Tall"), "written by the alt", "and the member")
end

-- A member holds a first-hand record that the only online officer lacks: no repeated pulls
do
  local net = Fakenet.new({ random = random })
  local officer = replica(net, "Officer One", OFFICER_RANK)
  local writer, holder = replica(net, "Member One"), replica(net, "Member Two")
  for _, current in ipairs({ officer, writer, holder }) do
    current:Login()
  end
  net:Advance(100)
  net.dropIf = function(entry, to)
    return to == "Officer One" and entry.from == "Member One" and codec.decode(entry.text) == "P"
  end
  writer.sync:Put(TABLE, "Member One", "the officer never gets this")
  net:Advance(60)
  T.eq(holder.sync:Get(TABLE, "Member One"), "the officer never gets this", "a member holds the record first hand")
  -- The officer writes too, so that its version is new to the members
  officer.sync:Put(TABLE, "Officer One", "of the officer")
  local since = net:Now()
  net:Advance(3600)
  T.eq(officer.sync:Get(TABLE, "Member One"), nil, "the officer still lacks the record")
  T.ok(holder:Version(TABLE) ~= officer:Version(TABLE), "so the versions differ")
  T.ok(Replica.count(net, "Q", "Member Two", since) <= 1, "the member who holds it pulls at most once in an hour")
  T.ok(Replica.count(net, "Q", "Member One", since) <= 1, "the writer too")
  T.eq(Replica.count(net, "Q", "Officer One"), 0, "the officer never pulls from a member")
  T.eq(holder.sync:Get(TABLE, "Officer One"), "of the officer", "the members have the officer's record")
end

---Runs three officers and five members who write their own records, with loss and offline periods. At the
---end everybody is online, and each officer writes once more an hour, so that every writer meets an officer.
---@param seed integer
---@return TestReplica[]
local function simulate(seed)
  local seeded = T.newRandom(seed)
  local net = Fakenet.new({ random = seeded, loss = 0.05 })
  local replicas, online = {}, {}
  for index = 1, 8 do
    local isOfficer = index <= 3
    replicas[index] = replica(net, (isOfficer and "Officer " or "Member ") .. index,
      isOfficer and OFFICER_RANK or nil, { random = seeded })
    replicas[index]:Login()
    online[index] = true
  end
  net:Advance(100)
  for _ = 1, 120 do
    local index = seeded(1, 8)
    local current = replicas[index]
    local action = seeded(1, 10)
    local key = current.name .. (seeded(1, 2) == 1 and "" or (":" .. seeded(1, 3)))
    if action <= 4 then
      current.sync:Put(TABLE, key, "text " .. seeded(1, 1000000))
    elseif action == 5 then
      current.sync:Delete(TABLE, key)
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
  net:Advance(1800)
  for round = 1, 3 do
    for index = 1, 3 do
      replicas[index].sync:Put(TABLE, replicas[index].name .. ":round", "round " .. round)
    end
    net:Advance(3600)
  end
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
  local names = {}
  for key in first.sync:Iterate(TABLE) do
    names[first.sync.keyName(key)] = true
  end
  T.ok(next(names) ~= nil, "seed " .. seed .. ": the table is not empty")
end

T.finish()
