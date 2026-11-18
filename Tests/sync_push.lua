-- Host test of the push in Addon/Src/Sync/SyncPush.lua: the push of local changes, its timer and
-- conditions, and the receiving side with and without a gap.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec

---Makes a network with replicas that are logged in and have finished their discovery. The `debug` table
---of the tests has a push delay of 10 seconds and a shortest interval of 30 seconds.
---@param names string[]
---@return Fakenet net
---@return TestReplica ... One per name
local function setup(names)
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index, name in ipairs(names) do
    replicas[index] = Replica.new(net, name, { random = random })
    replicas[index]:Login()
  end
  net:Advance(100)
  return net, table.unpack(replicas)
end

---Returns the checked fields of the pushes in the log, optionally from one sender.
---@param net Fakenet
---@param from string?
---@return table[] pushes Each with `time`, the clock value at which it was sent
local function pushes(net, from)
  local list = {}
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "P" and (not from or entry.from == from) then
      fields.time = entry.time
      list[#list + 1] = fields
    end
  end
  return list
end

-- 10 Puts within the push delay give one P; a Put on one replica reaches four others without a pull
do
  local net, a, b, c, d, e = setup({ "Nota Scam", "Other One", "Third One", "Fourth One", "Fifth One" })
  T.eq(net:Count(), 5, "five equal replicas send five hellos and nothing else")
  local zero = a.ns.versionId.ZERO
  local origin = a.sync:GetOrigin()
  local start = net:Now()
  for index = 1, 10 do
    a.sync:Put("debug", "key" .. index, "text " .. index)
    net:Advance(0.5)
  end
  T.eq(#pushes(net), 0, "no push before the push delay has passed")
  net:Advance(20)
  local sent = pushes(net)
  T.eq(#sent, 1, "10 Puts within the push delay give one push")
  local tbl = a.sync:GetTable("debug")
  T.eq(sent[1].time - start, 10, "it goes out when the delay has passed since the first change")
  T.eq({ sent[1].table, sent[1].schema, sent[1].own }, { "debug", 1, true }, "it names the table and is marked as own")
  T.eq(#sent[1].records, 10, "it holds the 10 records")
  T.eq(sent[1].base, { [origin] = zero }, "its base is the zero id, because nothing was pushed before")
  T.eq(sent[1].rest, {}, "it has no clock rest, because the records carry the clock")
  T.eq(sent[1].version, a:Version("debug"), "it carries the table version of the sender")
  T.eq(tbl.pushed, tbl.clock[origin], "the last pushed id is stored with the table")
  T.eq(a.sync.dirtySince.debug, nil, "the table is no longer marked as changed")
  for _, replica in ipairs({ b, c, d, e }) do
    T.eq(replica:Version("debug"), a:Version("debug"), replica.name .. " has the records")
    T.eq(replica.sync:Get("debug", "key10"), "text 10", replica.name .. " has the payload")
  end
  net:Advance(300)
  T.eq(Replica.count(net, "Q"), 0, "no pull was needed")
  T.eq(Replica.count(net, "S"), 0, "and no summary")

  -- Two changes that are a push delay apart but within the shortest interval: the second push waits
  local first = pushes(net)[1].time
  start = net:Now()
  a.sync:Put("debug", "key1", "changed")
  net:Advance(15)
  T.eq(#pushes(net), 2, "a change long after the last push goes out after the push delay")
  local second = pushes(net)[2]
  T.eq(second.time - start, 10, "after 10 seconds")
  T.eq(second.base, { [origin] = sent[1].records[10].id }, "its base is the last pushed id")
  T.eq(#second.records, 1, "it holds only the new record")
  a.sync:Put("debug", "key2", "changed")
  net:Advance(15)
  T.eq(#pushes(net), 2, "a change within the shortest interval of the last push waits")
  net:Advance(10)
  T.eq(#pushes(net), 3, "it goes out when the interval has passed")
  T.eq(pushes(net)[3].time - second.time, 30, "30 seconds after the push before it")
  T.ok(first < second.time, "the pushes are in order")
  net:Advance(1)
  T.eq(e:Version("debug"), a:Version("debug"), "the others follow")

  -- A delete is pushed as a tombstone
  a.sync:Delete("debug", "key3")
  net:Advance(60)
  T.eq(pushes(net)[4].records[1].tombstone, true, "a delete travels as a tombstone")
  T.eq(e.sync:Get("debug", "key3"), nil, "and deletes the record on the others")
  T.eq(e:Version("debug"), a:Version("debug"), "with equal versions")

  -- A Put that changes nothing pushes nothing
  a.sync:Put("debug", "key1", "changed")
  net:Advance(60)
  T.eq(#pushes(net), 4, "a Put of the stored payload sends nothing")
end

-- Two replicas push at the same moment: everybody ends equal, and nobody pulls
do
  local net, a, b, c = setup({ "Nota Scam", "Other One", "Third One" })
  a.sync:Put("debug", "from a", "text")
  b.sync:Put("debug", "from b", "text")
  net:Advance(15)
  local sent = pushes(net)
  T.eq(#sent, 2, "both push")
  T.eq(sent[1].was, sent[2].was, "both name the same version before their push")
  T.ok(sent[1].version ~= sent[2].version, "and each its own version after it")
  for _, replica in ipairs({ a, b }) do
    T.eq(replica:Version("debug"), c:Version("debug"), replica.name .. " ends equal to the third replica")
  end
  T.ok(c:Version("debug") ~= sent[1].version and c:Version("debug") ~= sent[2].version,
    "the common version is neither of the two that were announced")
  for _, message in ipairs(sent) do
    T.eq(c.session.merged.debug[message.version], true, "the third replica knows that it holds an announced version")
  end
  net:Advance(300)
  T.eq(Replica.count(net, "Q"), 0, "nobody pulls from a peer whose announced version is only out of date")
end

-- A push while in combat is held and goes out after the state changes
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  a:SetState({ inCombat = true })
  a.sync:Put("debug", "key", "text")
  net:Advance(100)
  T.eq(#pushes(net), 0, "no push in combat")
  T.ok(a.sync.dirtySince.debug, "the change stays marked")
  a:SetState({ inCombat = false })
  net:Advance(1)
  T.eq(#pushes(net), 1, "the push goes out when the fight is over")
  T.eq(b:Version("debug"), a:Version("debug"), "and arrives")

  -- The condition of the table: resting
  a.overrides.debug = { when = "resting", pushDelay = 5 }
  a.sync:Put("debug", "key", "again")
  net:Advance(100)
  T.eq(#pushes(net), 1, "a table that needs resting does not push outside a city")
  a:SetState({ resting = true })
  net:Advance(1)
  T.eq(#pushes(net), 2, "it pushes in a city")

  -- A table that is turned off
  a.overrides.debug = { enabled = false }
  a.sync:Put("debug", "key", "off")
  net:Advance(100)
  T.eq(#pushes(net), 2, "a table that is turned off does not push")
  a.overrides.debug = nil
  a:SetState({})
  net:Advance(100)
  T.eq(#pushes(net), 3, "the change goes out when the table is turned on again")

  -- A receiver that has the table turned off takes nothing
  b.overrides.debug = { enabled = false }
  local before = b:Version("debug")
  a.sync:Put("debug", "key", "not for b")
  net:Advance(100)
  T.eq(b:Version("debug"), before, "a replica that has the table turned off applies no push")
end

-- A lost push: the next one has a base that shows the gap; the receiver ignores it and pulls
do
  local net, a, b, c = setup({ "Nota Scam", "Other One", "Third One" })
  local losing = true
  net.dropIf = function(entry, to)
    return losing and to == "Other One" and codec.decode(entry.text) == "P"
  end
  a.sync:Put("debug", "one", "first")
  net:Advance(40)
  losing = false
  T.eq(c.sync:Get("debug", "one"), "first", "a receiver without loss has the first record")
  T.eq(b.sync:Get("debug", "one"), nil, "the receiver that lost the push does not")
  a.sync:Put("debug", "two", "second")
  net:Advance(15)
  local sent = pushes(net)
  T.eq(sent[2].base, { [a.sync:GetOrigin()] = sent[1].records[1].id }, "the next push has the first one as base")
  T.eq(c.sync:Get("debug", "two"), "second", "a receiver without a gap applies it")
  T.eq(c:Version("debug"), a:Version("debug"), "and is equal to the sender")
  T.eq(b.sync:Get("debug", "two"), nil, "a receiver with a gap ignores the records")
  T.eq(b.sync:GetTable("debug").clock, {}, "and its clock does not move")
  T.ok(b.session.delayedPullTimer, "it has a pull scheduled")
  T.eq(c.session.delayedPullTimer, nil, "the receiver without a gap has none")
  T.eq(Replica.count(net, "Q"), 0, "the pull waits")
  net:Advance(24)
  T.eq(Replica.count(net, "Q"), 0, "for at least 30 seconds")
  net:Advance(100)
  T.eq(Replica.count(net, "Q", "Other One"), 1, "then the receiver with the gap pulls")
  T.eq(b:Version("debug"), a:Version("debug"), "and ends equal to the sender")
  T.eq(Replica.count(net, "Q"), 1, "nobody else pulls")
end

-- Hand-made pushes: the checks of the receiver
do
  local net, b = setup({ "Other One" })
  local versionId, store = b.ns.versionId, b.ns.syncStore
  local raw = net:Join("Nota Scam")
  local tbl = b.sync:GetTable("debug")
  local now = math.floor(net:Now())
  local zero = versionId.ZERO
  local x1, x2, x3 = versionId.make(now - 50, "XXXX", 0), versionId.make(now - 40, "XXXX", 0),
    versionId.make(now - 30, "XXXX", 0)
  local y1 = versionId.make(now - 20, "YYYY", 0)
  local other = versionId.make(now - 5, "RRRR", 0) .. "!!!!!"
  local function send(schema, base, records, rest, tableName)
    raw:Send(codec.encode("P", tableName or "debug", schema, other, other, true, base,
      Replica.protocol.packRecords(records), rest), "GUILD")
    net:Advance(1)
  end

  send(2, { XXXX = zero }, { { key = "one", id = x1, payload = "first" } })
  T.eq(tbl.clock, {}, "a push with another schema is ignored")
  send(1, { XXXX = zero }, { { key = "one", id = x1, payload = "first" } }, nil, "future")
  T.eq(tbl.clock, {}, "a push for an unknown table is ignored")
  send(1, {}, { { key = "one", id = x1, payload = "first" } })
  T.eq(tbl.clock, {}, "records of an origin without a base are ignored")
  send(1, { XXXX = zero }, { { key = "one", id = x1, payload = "first" } })
  T.eq(b.sync:Get("debug", "one"), "first", "a push with the zero base is applied by a fresh replica")
  T.eq(b.session.peers["Nota Scam"].versions.debug, other, "the sender is a peer with the version of its push")

  -- Two origins in one push: one with a gap, one without
  send(1, { XXXX = x2, YYYY = zero }, {
    { key = "three", id = x3, payload = "third of X" },
    { key = "why", id = y1, payload = "of Y" },
  })
  T.eq(b.sync:Get("debug", "three"), nil, "the origin with a gap is ignored")
  T.eq(b.sync:Get("debug", "why"), "of Y", "the origin without a gap is applied")
  T.eq(tbl.clock, { XXXX = x1, YYYY = y1 }, "the clock follows only the applied origin")

  -- A base that the clock has passed is no gap
  send(1, { XXXX = zero }, { { key = "two", id = x2, payload = "second" } })
  T.eq(b.sync:Get("debug", "two"), "second", "a base below the clock is no gap")

  -- The clock rest: taken without a gap, and only when no record was dropped
  local w1 = versionId.make(now - 10, "WWWW", 0)
  send(1, { WWWW = w1 }, {}, { WWWW = versionId.make(now - 5, "WWWW", 0) })
  T.eq(tbl.clock.WWWW, nil, "a clock rest behind a gap is not taken")
  send(1, { WWWW = zero }, {}, { WWWW = w1 })
  T.eq(tbl.clock.WWWW, w1, "a clock rest without a gap is taken")
  local version = store.tableVersion(tbl)
  send(1, { XXXX = x2, YYYY = y1 }, { { key = "bad", id = x3, payload = 5 } },
    { YYYY = versionId.make(now - 2, "YYYY", 0) })
  T.eq(store.tableVersion(tbl), version, "with a dropped record neither the record nor the clock rest is taken")
  send(1, { YYYY = y1 }, {}, { YYYY = versionId.make(now + 1000, "YYYY", 0) })
  T.eq(tbl.clock.YYYY, y1, "a clock rest from the future is not taken")

  -- A record of a character outside the roster is counted as seen and not kept
  local characters = b.sync:GetTable("character")
  local c1, c2 = versionId.make(now - 9, "XXXX", 0), versionId.make(now - 8, "XXXX", 0)
  local payload = { class = "MAGE", level = 10, origins = { "XXXX" } }
  send(1, { XXXX = zero }, { { key = "Left Guild", id = c1, payload = payload },
    { key = "Nota Scam", id = c2, payload = payload } }, nil, "character")
  T.eq(b.sync:Get("character", "Left Guild"), nil, "a pushed record of a name outside the roster is not kept")
  T.eq(b.sync:Get("character", "Nota Scam"), payload, "the record of a member is")
  T.eq(characters.clock, { XXXX = c2 }, "and the clock counts both as seen")
end

-- A large push travels as several messages, chained by their bases
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  net:Advance(60)
  local sent = pushes(net)
  T.ok(#sent > 5, "300 records travel in several pushes")
  local origin, previous, total = a.sync:GetOrigin(), a.ns.versionId.ZERO, 0
  for _, message in ipairs(sent) do
    T.eq(message.base, { [origin] = previous }, "the base of a message is the last id of the one before")
    previous = message.records[#message.records].id
    total = total + #message.records
  end
  T.eq(total, 300, "every record is pushed once")
  T.eq(b:Version("debug"), a:Version("debug"), "the receiver applies the whole chain")
  T.eq(Replica.count(net, "Q"), 0, "without a pull")
end

-- A write of this install that another origin replaced: the push carries its clock value as rest
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  a.sync:Put("debug", "key", "of A")
  local tbl = a.sync:GetTable("debug")
  local mine = tbl.records.key.v
  -- Another origin overwrites the key before the push goes out
  a.ns.syncStore.apply(tbl, "key", a.ns.versionId.make(math.floor(net:Now()) + 1, "ZZZZ", 0), "of Z")
  net:Advance(60)
  local sent = pushes(net, "Nota Scam")
  T.eq(#sent[1].records, 0, "the replaced write has no record to push")
  T.eq(sent[1].rest, { [a.sync:GetOrigin()] = mine }, "its clock value travels as clock rest")
  T.eq(b.sync:GetTable("debug").clock[a.sync:GetOrigin()], mine, "the receiver takes it into its clock")
  T.eq(tbl.pushed, mine, "and it counts as pushed")
end

-- After a login: writes that were never pushed go out, and pushed ones do not go out again
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Other One", { random = random })
  b:Login()
  a.sync:Put("debug", "key", "written before the login")
  a:Login()
  net:Advance(25)
  T.eq(#pushes(net, "Nota Scam"), 0, "nothing is pushed before discovery has ended")
  net:Advance(100)
  T.eq(#pushes(net, "Nota Scam"), 1, "a write from before the login is pushed after discovery")
  a:Logout()
  net:Advance(10)
  a:Login()
  net:Advance(200)
  T.eq(#pushes(net, "Nota Scam"), 1, "what was pushed is not pushed again after the next login")
  -- A value in the saved variables that is not an id counts as nothing pushed
  a:Logout()
  a.sync:GetTable("debug").pushed = 5
  a:Login()
  net:Advance(200)
  T.eq(#pushes(net, "Nota Scam"), 2, "a broken stored id makes the table push again")
  T.eq(b:Version("debug"), a:Version("debug"), "which changes nothing on the receiver")

  -- A session that stops keeps the change marked and sends it after the next login
  a.sync:Put("debug", "late", "just before the logout")
  a:Logout()
  net:Advance(100)
  T.eq(#pushes(net, "Nota Scam"), 2, "a replica that has logged out pushes nothing")
  a:Login()
  net:Advance(200)
  T.eq(#pushes(net, "Nota Scam"), 3, "the change goes out after the next login")
  T.eq(b.sync:Get("debug", "late"), "just before the logout", "and arrives")
end

T.finish()
