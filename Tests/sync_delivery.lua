-- Host test of the delivery to the officers (.agents/00-plan.md, section 14.6, step 13.5) in
-- Addon/Src/Sync/SyncDelivery.lua: the whisper `K`, the held map of a member, the repeated push and its
-- limits, `IsBehind`, and the status line "held by".
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local TABLE = "debugself"
local OFFICER_RANK = 0

---Makes a replica with the developer tables.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param seeded (fun(m: integer?, n: integer?): number)?
---@return TestReplica
local function replica(net, name, rankIndex, seeded)
  return Replica.new(net, name, { random = seeded or random, rankIndex = rankIndex, developerTables = true })
end

---Makes a network with replicas that are logged in and have finished their discovery.
---@param officers string[]
---@param members string[]
---@return Fakenet net
---@return table<string, TestReplica> byName
local function setup(officers, members)
  local net = Fakenet.new({ random = random })
  local byName = {}
  for _, name in ipairs(officers) do
    byName[name] = replica(net, name, OFFICER_RANK)
  end
  for _, name in ipairs(members) do
    byName[name] = replica(net, name)
  end
  for _, current in pairs(byName) do
    current:Login()
  end
  net:Advance(100)
  return net, byName
end

---Returns the checked fields of the messages of one type in the log, optionally from one sender and since a
---time; each with `time` and `target`.
---@param net Fakenet
---@param messageType string
---@param from string?
---@param since number?
---@return table[]
local function messages(net, messageType, from, since)
  local list = {}
  for _, entry in ipairs(net.log) do
    local decoded, fields = codec.decode(entry.text)
    if decoded == messageType and (not from or entry.from == from) and (not since or entry.time >= since) then
      fields.time, fields.target = entry.time, entry.target
      list[#list + 1] = fields
    end
  end
  return list
end

---Returns the clock value of the own character origin of a replica in the self table.
---@param current TestReplica
---@return string|nil
local function ownTop(current)
  return current.sync:GetTable(TABLE).clock[current.sync:OriginFor(TABLE)]
end

-- The checks of K: a table name, an origin of 4 characters, and the zero id or a well-formed id of that origin
do
  local versionId = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua" }).versionId
  local id = versionId.make(1795000000, "AbCd", 7)
  local messageType, fields = codec.decode(codec.encode("K", TABLE, "AbCd", id))
  T.eq({ messageType, fields }, { "K", { table = TABLE, origin = "AbCd", id = id } }, "a K is read back")
  T.eq(codec.decode(codec.encode("K", TABLE, "AbCd", versionId.ZERO)), "K", "the zero id is accepted")
  local refused = {
    { "bad table name", 7, "AbCd", id },
    { "bad origin", TABLE, "AbC", id },
    { "bad origin", TABLE, 1234, id },
    { "bad id", TABLE, "WxYz", id },
    { "bad id", TABLE, "AbCd", id:sub(2) },
    { "bad id", TABLE, "AbCd", nil },
  }
  for index, case in ipairs(refused) do
    local refusedType, reason = codec.decode(codec.encode("K", case[2], case[3], case[4]))
    T.eq({ refusedType, reason }, { nil, case[1] }, "K case " .. index .. " is refused")
  end
end

-- A lost push is sent again and arrives; after the K no further push goes out
do
  local net, all = setup({ "Officer One" }, { "Member One" })
  local officer, member = all["Officer One"], all["Member One"]
  local lost = 0
  net.dropIf = function(entry, to)
    if to == "Officer One" and entry.from == "Member One" and codec.decode(entry.text) == "P" and lost == 0 then
      lost = lost + 1
      return true
    end
    return false
  end
  local since = net:Now()
  member.sync:Put(TABLE, "Member One", "text")
  net:Advance(15)
  T.eq(lost, 1, "the first push is lost to the officer")
  T.eq(officer.sync:Get(TABLE, "Member One"), nil, "which lacks the record")
  T.eq(#messages(net, "K", "Officer One", since), 0, "and sends no K")
  net:Advance(250)
  T.eq(#messages(net, "P", "Member One", since), 2, "the member pushes again")
  T.eq(officer.sync:Get(TABLE, "Member One"), "text", "and the officer has the record")
  local held = messages(net, "K", "Officer One", since)
  T.eq(#held, 1, "the officer whispers one K")
  T.eq({ held[1].table, held[1].origin, held[1].id, held[1].target },
    { TABLE, member.sync:OriginFor(TABLE), ownTop(member), "Member One" }, "with the member's origin and newest id")
  T.eq(member.session:HeldStatus(TABLE), "held by 1 of 1 officers online", "the member knows that it is held")
  member.ns.syncSession.current = member.session
  local line
  for _, text in ipairs(member.ns.syncCommands.statusLines()) do
    if text:find("^" .. TABLE .. ": ") then
      line = text
    end
  end
  T.ok(line and line:find(", held by 1 of 1 officers online$"), "and the status line of the table says so")
  T.eq(officer.session:HeldStatus(TABLE), nil, "an officer has no such line")
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since), 2, "after the K no further push goes out")
end

-- An officer with a gap answers with an older id and gets the records after it
do
  local net, all = setup({ "Officer One" }, { "Member One" })
  local officer, member = all["Officer One"], all["Member One"]
  local lost = 0
  net.dropIf = function(entry, to)
    if to == "Officer One" and entry.from == "Member One" and codec.decode(entry.text) == "P" and lost == 0 then
      lost = lost + 1
      return true
    end
    return false
  end
  local since = net:Now()
  member.sync:Put(TABLE, "Member One", "first")
  net:Advance(11)
  T.eq(lost, 1, "the first push is lost to the officer")
  member.sync:Put(TABLE, "Member One:2", "second")
  net:Advance(40)
  -- The officer answers every push of the member: the one with the gap, and the repeated one
  local held = messages(net, "K", "Officer One", since)
  T.eq(#held, 2, "the officer answers the push that it cannot apply, and the repeated one")
  T.eq(held[1].id, member.ns.versionId.ZERO, "first with the id that it holds: none")
  local pushed = messages(net, "P", "Member One", since)
  T.eq(#pushed, 3, "the member pushes once more")
  T.ok(pushed[3].time > held[1].time and pushed[3].time - held[1].time < 1, "at once after the K")
  T.eq(pushed[3].base, { [member.sync:OriginFor(TABLE)] = member.ns.versionId.ZERO }, "from that id")
  T.eq(#pushed[3].records, 2, "with both records")
  T.eq({ officer.sync:Get(TABLE, "Member One"), officer.sync:Get(TABLE, "Member One:2") }, { "first", "second" },
    "the officer gets the records after its id")
  T.eq(held[2].id, ownTop(member), "and then tells that it holds the newest own write")
  T.eq(member.session:HeldStatus(TABLE), "held by 1 of 1 officers online", "which the member notes")
  net:Advance(600)
  T.eq(#messages(net, "P", "Member One", since), 3, "and nothing more is pushed")
end

-- A K from a member is ignored; a K from an officer starts a push at once
do
  local net, all = setup({}, { "Member One" })
  local member = all["Member One"]
  local zero = member.ns.versionId.ZERO
  local olderVersion = member:Version(TABLE)
  member.sync:Put(TABLE, "Member One", "text")
  net:Advance(60)
  local rawMember, rawOfficer = net:Join("Raw Member"), net:Join("Raw Officer", OFFICER_RANK)
  local since = net:Now()
  local origin = member.sync:OriginFor(TABLE)
  rawMember:Send(codec.encode("K", TABLE, origin, zero), "WHISPER", "Member One")
  net:Advance(5)
  T.eq(#messages(net, "P", "Member One", since), 0, "a K from a member is ignored")
  T.eq(member.session.delivery.held[TABLE], nil, "and noted nowhere")
  rawOfficer:Send(codec.encode("K", TABLE, "ZZZZ", zero), "WHISPER", "Member One")
  net:Advance(5)
  T.eq(#messages(net, "P", "Member One", since), 0, "a K for another origin is ignored")
  rawOfficer:Send(codec.encode("K", TABLE, origin, zero), "WHISPER", "Member One")
  net:Advance(5)
  T.eq(#messages(net, "P", "Member One", since), 1, "a K of an officer with an older id starts a push at once")
  T.eq(member.session.delivery.held[TABLE]["Raw Officer"], zero, "and the member notes what the officer holds")
  T.ok(member.session.peers["Raw Officer"], "the officer is a peer")
  -- At most three repeated pushes for one officer
  for _ = 1, 5 do
    rawOfficer:Send(codec.encode("K", TABLE, origin, zero), "WHISPER", "Member One")
    net:Advance(5)
  end
  T.eq(#messages(net, "P", "Member One", since), 3, "at most three repeated pushes for one officer")
  net:Advance(600)
  T.eq(#messages(net, "P", "Member One", since), 3, "also by the periodic check")
  -- A hello of the officer clears what the member knew
  rawOfficer:Send(codec.encode("H", {}), "GUILD")
  net:Advance(1)
  T.eq(member.session.delivery.held[TABLE]["Raw Officer"], nil, "a hello of the officer clears the held id")
  net:Advance(600)
  T.eq(#messages(net, "P", "Member One", since), 3, "an officer whose hello does not name the table gets no push")
  -- An older version starts a pull from the officer, which never answers; the check pushes after it
  rawOfficer:Send(codec.encode("H", { [TABLE] = olderVersion }), "GUILD")
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since), 6, "a hello that names the table clears the count: 3 more pushes")
end

-- An officer logs in with an equal version: no member pushes. With an older one: each member delivers once.
do
  local net, all = setup({ "Officer One" }, { "Member One", "Member Two" })
  local officer, first, second = all["Officer One"], all["Member One"], all["Member Two"]
  first.sync:Put(TABLE, "Member One", "one")
  second.sync:Put(TABLE, "Member Two", "two")
  net:Advance(200)
  T.eq(first:Version(TABLE), officer:Version(TABLE), "all hold the same")
  officer:Logout()
  net:Advance(10)
  local since = net:Now()
  officer:Login()
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since) + #messages(net, "P", "Member Two", since), 0,
    "an officer with an equal version gets no push")
  T.eq(first.session:HeldStatus(TABLE), "held by 1 of 1 officers online", "the hello tells that it holds all")

  officer:Logout()
  net:Advance(10)
  first.sync:Put(TABLE, "Member One", "one, changed while the officer was away")
  second.sync:Put(TABLE, "Member Two:2", "two, written while the officer was away")
  net:Advance(100)
  since = net:Now()
  officer:Login()
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since), 1, "the first member delivers its newer writes once")
  T.eq(#messages(net, "P", "Member Two", since), 1, "the second too")
  T.eq(officer.sync:Get(TABLE, "Member One"), "one, changed while the officer was away", "the officer has them")
  T.eq(officer.sync:Get(TABLE, "Member Two:2"), "two, written while the officer was away", "all of them")
  T.eq(officer:Version(TABLE), first:Version(TABLE), "and ends equal to the members")
end

-- No officer online: nothing is sent again, for an hour
do
  local net, all = setup({}, { "Member One", "Member Two" })
  local since = net:Now()
  all["Member One"].sync:Put(TABLE, "Member One", "text")
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since), 1, "one push, and no repeated one")
  T.eq(all["Member Two"].sync:Get(TABLE, "Member One"), "text", "the member online has the record")
  T.eq(all["Member One"].session:HeldStatus(TABLE), "held by 0 of 0 officers online", "the status says so")
end

---Joins an endpoint without an addon that sends raw messages and keeps the whispers that it gets.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return table raw With `endpoint`, `got` (the decoded whispers), `Send`, and `Whispers`
local function joinRaw(net, name, rankIndex)
  local raw = { endpoint = net:Join(name, rankIndex), got = {} }
  raw.endpoint.receive = function(text, distribution)
    local messageType, fields = codec.decode(text)
    if distribution == "WHISPER" then
      raw.got[#raw.got + 1] = { type = messageType, fields = fields }
    end
  end
  ---Sends a message on the channel of its type.
  ---@param messageType string
  ---@param target string|nil The receiver of a whisper
  function raw:Send(messageType, target, ...)
    self.endpoint:Send(codec.encode(messageType, ...), Replica.protocol.CHANNELS[messageType], target)
  end
  ---Returns the whispers of one type that the endpoint got.
  ---@param messageType string
  ---@return table[] fields
  function raw:Whispers(messageType)
    local list = {}
    for _, message in ipairs(self.got) do
      if message.type == messageType then
        list[#list + 1] = message.fields
      end
    end
    return list
  end
  return raw
end

-- An officer peer that never names the table (an older addon, or the table turned off) sends no K: it does not
-- count, and the member pushes nothing again for it
do
  local net, all = setup({}, { "Member One" })
  local member = all["Member One"]
  local rawOfficer = joinRaw(net, "Raw Officer", OFFICER_RANK)
  rawOfficer:Send("H", nil, {})
  net:Advance(10)
  T.ok(member.session.peers["Raw Officer"], "the officer is a peer")
  local since = net:Now()
  member.sync:Put(TABLE, "Member One", "text")
  net:Advance(3600)
  T.eq(#messages(net, "P", "Member One", since), 1, "one push, and no repeated one for that officer")
  T.eq(member.session:HeldStatus(TABLE), "held by 0 of 0 officers online", "the officer does not count")
end

-- One push of a member costs one K per member and table, for the origin of its last record that names the
-- sender; a later push before the K replaces the origin
do
  local net, all = setup({ "Officer One" }, {})
  local officer = all["Officer One"]
  local versionId, base94 = officer.ns.versionId, officer.ns.base94
  local rawMember = joinRaw(net, "Raw Member")
  local now = math.floor(net:Now())
  local version = "!!!!!RRRR!!!!!!!"
  ---Makes a push of records of the raw member, one per origin.
  ---@param first integer The number of the first origin
  ---@param count integer
  ---@return table base, string packed, string lastOrigin
  local function forged(first, count)
    local records, base, origin = {}, {}, nil
    for index = first, first + count - 1 do
      origin = base94.encode(1000 + index, 4)
      records[#records + 1] = { key = "Raw Member", id = versionId.make(now - 200 + index, origin, 0), payload = "x" }
      base[origin] = versionId.ZERO
    end
    return base, Replica.protocol.packRecords(records), origin
  end
  local base, packed, lastOrigin = forged(1, 60)
  rawMember:Send("P", nil, TABLE, 1, version, version, true, base, packed, {})
  net:Advance(30)
  local held = rawMember:Whispers("K")
  T.eq(#held, 1, "a push with 60 origins gets one K")
  T.eq(held[1].origin, lastOrigin, "for the origin of the last record")
  local firstBase, firstPacked = forged(70, 1)
  local secondBase, secondPacked, secondOrigin = forged(80, 1)
  rawMember:Send("P", nil, TABLE, 1, version, version, true, firstBase, firstPacked, {})
  rawMember:Send("P", nil, TABLE, 1, version, version, true, secondBase, secondPacked, {})
  net:Advance(30)
  held = rawMember:Whispers("K")
  T.eq(#held, 2, "two pushes in a row get one K more")
  T.eq(held[2].origin, secondOrigin, "for the origin of the later push")
end

-- A member's push into a self table never makes its version merged: an empty push that names the version of an
-- officer does not stop the pull from that officer. An honest push causes no pull.
do
  for _, forge in ipairs({ false, true }) do
    local net, all = setup({ "Officer One" }, {})
    local officer = all["Officer One"]
    local versionId = officer.ns.versionId
    local rawOfficer, rawMember = joinRaw(net, "Raw Officer", OFFICER_RANK), joinRaw(net, "Raw Member")
    local announced = versionId.make(math.floor(net:Now()) - 50, "OOOO", 0) .. "!!!!!"
    rawOfficer:Send("S", nil, { [TABLE] = announced })
    if forge then
      rawMember:Send("P", nil, TABLE, 1, announced, officer:Version(TABLE), true, {}, Replica.protocol.packRecords({}),
        {})
    end
    net:Advance(200)
    local label = forge and "after an empty member push that names it: " or "without a member push: "
    local merged = officer.session.merged[TABLE]
    T.eq(merged and merged[announced], nil, label .. "the officer's version is not counted as merged")
    T.eq(#rawOfficer:Whispers("Q"), 1, label .. "the officer pulls from the officer that announced it")
  end
  local net, all = setup({ "Officer One" }, { "Member One", "Member Two" })
  local since = net:Now()
  all["Member One"].sync:Put(TABLE, "Member One", "text")
  net:Advance(600)
  T.eq(#messages(net, "Q", nil, since), 0, "an honest member's push causes no pull")
  T.eq({ all["Officer One"].sync:Get(TABLE, "Member One"), all["Member Two"].sync:Get(TABLE, "Member One") },
    { "text", "text" }, "and its record arrives")
  T.eq(all["Officer One"].sync:IsBehind(TABLE), false, "the officer is not behind")
end

-- IsBehind: true for an officer after a member announced a newer maxId that no online officer holds
do
  local net, all = setup({ "Officer One", "Officer Two" }, { "Member One" })
  local first, second, member = all["Officer One"], all["Officer Two"], all["Member One"]
  local officerTable = "debugofficer"
  T.eq(first.sync:IsBehind(officerTable), false, "an officer that is level is not behind")
  first:Logout()
  net:Advance(10)
  second.sync:Put(officerTable, "decision", "written while the first officer was away")
  net:Advance(60)
  T.eq(member.sync:Get(officerTable, "decision"), "written while the first officer was away", "the member has it")
  second:Logout()
  net:Advance(10)
  first:Login()
  net:Advance(100)
  T.eq(first.sync:Get(officerTable, "decision"), nil, "the first officer cannot get it from a member")
  T.eq(first.sync:IsBehind(officerTable), true, "and is behind")
  T.eq(first.sync:IsBehind("debug"), false, "a table that is not protected is never behind")
  T.eq(member.sync:IsBehind(officerTable), false, "the member, which holds the newest, is not")
  second:Login()
  net:Advance(400)
  T.eq(first.sync:Get(officerTable, "decision"), "written while the first officer was away",
    "the pull from the second officer brings it")
  T.eq(first.sync:IsBehind(officerTable), false, "and the first officer is no longer behind")
end

---Runs officers and members under 30% message loss: every member writes a record, and the run checks that
---every online officer holds every member's record.
---@param seed integer
local function lossy(seed)
  local seeded = T.newRandom(seed)
  local net = Fakenet.new({ random = seeded, loss = 0.3 })
  local officers, members = {}, {}
  for index = 1, 3 do
    officers[index] = replica(net, "Officer " .. index, OFFICER_RANK, seeded)
    officers[index]:Login()
  end
  for index = 1, 4 do
    members[index] = replica(net, "Member " .. index, nil, seeded)
    members[index]:Login()
  end
  net:Advance(200)
  for index, member in ipairs(members) do
    member.sync:Put(TABLE, member.name, "record " .. index)
    net:Advance(seeded(1, 60))
  end
  net:Advance(2 * 3600)
  for _, officer in ipairs(officers) do
    for index, member in ipairs(members) do
      T.eq(officer.sync:Get(TABLE, member.name), "record " .. index,
        "seed " .. seed .. ": " .. officer.name .. " holds the record of " .. member.name)
    end
  end
end

for seed = 1, 8 do
  lossy(seed)
end

T.finish()
