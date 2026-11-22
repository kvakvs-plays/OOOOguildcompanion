-- Host test of the gap check of the shared database (.agents/sync-design.md, section 4.5;
-- Addon/Src/Sync/SyncGaps.lua): the counts per hour, the fill of a hole below the clock, the messages `C`,
-- `G`, and `F`, and replicas on the fake network that lose records which their clock covers.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

-- The replicas of this file run the gap check, as the game does
Replica.withGaps = true

local codec = Replica.codec
local TABLE = "guildchat"
local HOUR = 3600

---Copies a value with all its tables.
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = deepCopy(item)
  end
  return result
end

---Makes a network with replicas that are logged in and have ended their discovery.
---@param names string[]
---@param prepare (fun(replica: TestReplica, index: integer))? Called for each replica before its login
---@return Fakenet net
---@return TestReplica[] replicas
---@return fun(m: integer?, n: integer?): number random
local function start(names, prepare)
  local random = T.newRandom()
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index, name in ipairs(names) do
    replicas[index] = Replica.new(net, name, { random = random })
    if prepare then
      prepare(replicas[index], index)
    end
    replicas[index]:Login()
  end
  net:Advance(100)
  return net, replicas, random
end

---Lets a replica write lines of its own character into the guild chat, all in one second.
---@param replica TestReplica
---@param lines string[]
---@return string[] ids
local function say(replica, lines)
  local ids = {}
  for index, text in ipairs(lines) do
    ids[index] = replica:Hear(text, replica.name)
    T.ok(ids[index], "the line of the test is written")
  end
  return ids
end

---Returns the texts of the stored lines of a replica, in their order.
---@param replica TestReplica
---@return string[]
local function texts(replica)
  local result = {}
  for index, line in ipairs(replica.ns.guildChat:Lines()) do
    result[index] = line.text
  end
  return result
end

---Takes a record out of a replica without a trace in its clock: the hole that the clock does not show.
---@param replica TestReplica
---@param id string
local function punch(replica, id)
  local tbl = replica.sync:GetTable(TABLE)
  T.ok(tbl.records[id], "the record that the test removes is there")
  tbl.records[id] = nil
  replica.ns.guildChat.keys = nil
end

---Counts the logged messages of one type, optionally from one sender, to one target, and from a time on.
---@param net Fakenet
---@param messageType string
---@param from string?
---@param target string?
---@param since number?
---@return integer
local function count(net, messageType, from, target, since)
  return net:Count(function(entry)
    return codec.decode(entry.text) == messageType and (not from or entry.from == from)
      and (not target or entry.target == target) and (not since or entry.time >= since)
  end)
end

---Makes a replica behave like one with an addon from before the gap check: its codec drops the three new
---types as unknown, and it never sends its counts.
---@param replica TestReplica
local function makeOld(replica)
  local deliver = replica.transport.onMessage
  replica.transport.onMessage = function(sender, messageType, fields)
    if messageType ~= "C" and messageType ~= "G" and messageType ~= "F" then
      deliver(sender, messageType, fields)
    end
  end
  replica.session.StartGaps = function() end
end

--------------------------------------------------------------------------------
-- The store: counts per hour, ids of a range, the records that another replica lacks, the fill
--------------------------------------------------------------------------------
do
  local ns = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua",
    "Addon/Src/Sync/SyncStore.lua" })
  local store, versionId = ns.syncStore, ns.versionId
  local first = 498611
  local base = first * HOUR
  local tbl = store.newTable(1)
  local ids = {
    versionId.make(base + 10, "AAAA", 0),
    versionId.make(base + 20, "BBBB", 0),
    versionId.make(base + HOUR + 5, "AAAA", 0),
    versionId.make(base + 2 * HOUR + 1, "AAAA", 0),
  }
  store.apply(tbl, "one", ids[1], "a")
  store.apply(tbl, "two", ids[2], "b")
  store.apply(tbl, "three", ids[3], "c")
  store.apply(tbl, "four", ids[4], nil, true)
  local counts, sums = store.hourCounts(tbl, first, 3)
  T.eq(counts, { 2, 1, 1 }, "the records are counted per hour of their ids, a tombstone too")
  for index = 1, 3 do
    T.ok(sums[index] >= 0 and sums[index] < 8836, "a checksum fits into 2 characters")
  end
  T.eq({ store.hourCounts(tbl, first - 1, 2) }, { { 0, 2 }, { 0, sums[1] } }, "an hour without records is 0")
  T.eq((store.hourCounts(tbl, first, 3, base + HOUR + 5)), { 2, 0, 0 }, "a record at the cut time is left out")
  T.eq((store.hourCounts(tbl, first, 3, base + HOUR + 6)), { 2, 1, 0 }, "a record before the cut time counts")
  T.eq((store.hourCounts(tbl, first, 2, base + 9 * HOUR)), { 2, 1 }, "a cut after the hours changes nothing")

  -- Equal counts with other records give other checksums
  local other = store.newTable(1)
  store.apply(other, "one", ids[1], "a")
  store.apply(other, "else", versionId.make(base + 30, "BBBB", 0), "x")
  local otherCounts, otherSums = store.hourCounts(other, first, 1)
  T.eq(otherCounts, { 2 }, "the other table holds as many records in the hour")
  T.ok(otherSums[1] ~= sums[1], "and its checksum differs")

  T.eq(store.idsInRange(tbl, base, base + HOUR), { ids[1], ids[2] }, "the ids of a range come sorted")
  T.eq(store.idsInRange(tbl, base + 11, base + 20), {}, "the end of a range is outside")
  T.eq(store.idsInRange(tbl, base + 10, base + 21), { ids[1], ids[2] }, "the start of a range is inside")

  -- What another replica lacks, and what this one lacks of the other's ids
  local missing = versionId.make(base + 15, "AAAA", 0)
  local ahead = versionId.make(base + 40, "CCCC", 0)
  local records, lacking = store.selectMissing(tbl, base, base + HOUR,
    { [ids[1]] = true, [missing] = true, [ahead] = true })
  T.eq(records, { { key = "two", id = ids[2], payload = "b" } }, "the record that the other replica lacks")
  T.eq(lacking, 1, "an id below the clock that is not held is a hole; one above the clock is not")
  records, lacking = store.selectMissing(tbl, base + 2 * HOUR, base + 3 * HOUR, {})
  T.eq(records, { { key = "four", id = ids[4], tombstone = true } }, "a tombstone is given as one")
  T.eq(lacking, 0, "no ids, no holes")

  -- The fill
  local version = store.tableVersion(tbl)
  T.eq({ store.fill(tbl, "new", ahead, "y") }, { false, "ahead" }, "a record of an unknown origin is refused")
  T.eq({ store.fill(tbl, "new", versionId.make(base + 3 * HOUR, "AAAA", 0), "y") }, { false, "ahead" },
    "a record above the clock of its origin is refused")
  T.eq({ store.fill(tbl, "one", ids[1], "z") }, { false, "held" }, "a write that the table holds is refused")
  T.eq({ store.fill(tbl, "three", missing, "z") }, { false, "held" }, "an older write of a key is refused")
  T.eq({ store.fill(tbl, "hole", missing, "found") }, { true }, "a record below the clock is stored")
  T.eq(tbl.records.hole, { v = missing, d = "found" }, "with its id and payload")
  local deleted = versionId.make(base + 16, "AAAA", 0)
  T.eq({ store.fill(tbl, "gone", deleted, nil, true) }, { true }, "a tombstone too")
  T.eq(tbl.records.gone, { v = deleted, x = true }, "as a tombstone")
  T.eq(store.tableVersion(tbl), version, "a fill never changes the table version")
end

--------------------------------------------------------------------------------
-- The messages
--------------------------------------------------------------------------------
do
  local protocol = Replica.protocol
  local versionId = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua" }).versionId
  local serializer = dofile("Tests/fixtures/stub_serializer.lua")
  local base = 498611 * HOUR
  ---Decodes a message that is serialized as given, without the checks of `encode`.
  local function decodeRaw(...)
    return (codec.decode(serializer:Serialize(1, ...)))
  end
  T.eq(protocol.CHANNELS.C, "GUILD", "the counts travel on GUILD")
  T.eq(protocol.CHANNELS.G, "WHISPER", "a gap request travels on WHISPER")
  T.eq(protocol.CHANNELS.F, "WHISPER", "a fill travels on WHISPER")
  T.eq(protocol.VERSION, 1, "the protocol version is the one of the addons before the gap check")

  local text = protocol.packCounts({ 0, 3, 9000 }, { 0, 8835, 17 })
  T.eq(#text, 12, "4 characters per hour")
  T.eq({ codec.decode(codec.encode("C", TABLE, base + 5, text)) },
    { "C", { table = TABLE, cut = base + 5, counts = { 0, 3, 8835 }, sums = { 0, 8835, 17 } } },
    "the counts come back; a count over the limit is the limit")
  T.eq(decodeRaw("C", TABLE, base, ""), nil, "no counts are refused")
  T.eq(decodeRaw("C", TABLE, base, "!!!!!"), nil, "a text that is no multiple of 4 is refused")
  T.eq(decodeRaw("C", TABLE, base, "!! !"), nil, "a character outside base 94 is refused")
  T.eq(decodeRaw("C", TABLE, base, string.rep("!", 4 * 97)), nil, "more than 96 hours are refused")
  T.eq(decodeRaw("C", TABLE, 0, text), nil, "the cut time 0 is refused")
  T.eq(decodeRaw("C", TABLE, 1.5, text), nil, "a cut time with a fraction is refused")
  T.eq(decodeRaw("C", TABLE, HOUR, text), nil, "hours before the time 0 are refused")
  T.eq(decodeRaw("C", "Bad Name", base, text), nil, "a bad table name is refused")

  local one, two = versionId.make(base + 10, "AAAA", 0), versionId.make(base + 20, "BBBB", 3)
  T.eq({ codec.decode(codec.encode("G", TABLE, 1, 77, base, base + HOUR, one .. two)) },
    { "G", { table = TABLE, schema = 1, nonce = 77, from = base, to = base + HOUR,
      have = { [one] = true, [two] = true } } }, "a gap request comes back, its ids as a set")
  T.eq({ codec.decode(codec.encode("G", TABLE, 1, 77, base, base + 1, "")) },
    { "G", { table = TABLE, schema = 1, nonce = 77, from = base, to = base + 1, have = {} } },
    "a gap request without ids is valid")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base, ""), nil, "an empty range is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + HOUR + 1, ""), nil, "a range over two hours is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base + 11, base + HOUR, one), nil, "an id before the range is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + 20, two), nil, "an id at the end of the range is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + HOUR, one .. one), nil, "a repeated id is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + HOUR, one:sub(1, 10)), nil, "a cut id is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + HOUR, string.rep(one, 1001)), nil, "over 1000 ids are refused")
  T.eq(decodeRaw("G", TABLE, 1, 0, base, base + HOUR, one), nil, "a bad nonce is refused")
  T.eq(decodeRaw("G", TABLE, 1, 77, base, base + HOUR, 5), nil, "ids that are no text are refused")

  local records = { { key = one, id = one, payload = { s = "Nota Scam", t = "hello" } },
    { key = "gone", id = two, tombstone = true } }
  T.eq({ codec.decode(codec.encode("F", TABLE, 77, 2, true, protocol.packRecords(records))) },
    { "F", { table = TABLE, nonce = 77, batch = 2, last = true, records = records } }, "a fill comes back")
  T.eq(decodeRaw("F", TABLE, 77, 0, true, {}), nil, "a batch number 0 is refused")
  T.eq(decodeRaw("F", TABLE, 77, 1, "yes", {}), nil, "a last flag that is no boolean is refused")
  T.eq(decodeRaw("F", TABLE, 77, 1, true, { { one } }), nil, "a record without an id is refused")
end

--------------------------------------------------------------------------------
-- The table definition, the ranges of a request, and the fill of received records
--------------------------------------------------------------------------------
do
  local net, replicas = start({ "Nota Scam" })
  local a = replicas[1]
  local ns = a.ns
  local gaps, versionId = ns.syncGaps, ns.versionId
  local function define(name, changes)
    local definition = { name = name, schema = 1, keyKind = "free", writers = "anyone", maxRecordBytes = 100,
      validate = function() return true end }
    for field, value in pairs(changes) do
      definition[field] = value
    end
    return function()
      ns.sync:RegisterTable(definition)
    end
  end
  T.eq(ns.sync.definitions[TABLE].gapCheckHours, 48, "the guild chat compares 48 hours")
  T.raises(define("gapa", { gapCheckHours = 0 }), "0 hours are refused", "gapCheckHours")
  T.raises(define("gapb", { gapCheckHours = 97 }), "97 hours are refused", "gapCheckHours")
  T.raises(define("gapc", { gapCheckHours = 1.5 }), "a fraction is refused", "gapCheckHours")
  T.raises(define("gapd", { gapCheckHours = 24, writers = "officer" }), "an officer table is refused", "protected")
  T.raises(define("gape", { gapCheckHours = 24, writers = "self", keyKind = "character" }),
    "a self table is refused", "protected")
  T.raises(define("gapf", { gapCheckHours = 24, maxAge = 24 * HOUR }), "hours up to maxAge are refused", "maxAge")
  define("gapg", { gapCheckHours = 24, maxAge = 25 * HOUR })()
  T.eq(ns.sync.definitions.gapg.gapCheckHours, 24, "a good definition keeps the hours")
  T.eq(ns.sync.definitions.debug.gapCheckHours, nil, "a table without the field has no gap check")

  -- Ranges: an hour with more ids than one request takes is cut by halving
  local base = 498611 * HOUR
  local ids = {}
  for index = 1, 10 do
    ids[index] = versionId.make(base + index * 300, "AAAA", index)
  end
  T.eq(gaps.splitRange(ids, base, base + HOUR, 10), { { from = base, to = base + HOUR, ids = ids } },
    "ids that fit give one range")
  T.eq(gaps.splitRange({}, base, base + HOUR, 10), { { from = base, to = base + HOUR, ids = {} } },
    "no ids give one range: the peer sends all that it holds")
  local ranges = gaps.splitRange(ids, base, base + HOUR, 3)
  local joined, position = {}, base
  for _, range in ipairs(ranges) do
    T.eq(range.from, position, "the ranges follow each other without a hole")
    T.ok(#range.ids <= 3, "no range has more ids than the limit")
    for _, id in ipairs(range.ids) do
      T.ok(versionId.parse(id) >= range.from and versionId.parse(id) < range.to, "an id lies in its range")
      joined[#joined + 1] = id
    end
    position = range.to
  end
  T.eq(position, base + HOUR, "the ranges cover the hour")
  T.eq(joined, ids, "every id is in one range")
  -- One second with more ids than the limit cannot be asked for
  local crowded = {}
  for index = 1, 5 do
    crowded[index] = versionId.make(base + 100, "AAAA", index)
  end
  crowded[6] = versionId.make(base + 200, "AAAA", 0)
  ranges = gaps.splitRange(crowded, base, base + HOUR, 3)
  joined = {}
  for _, range in ipairs(ranges) do
    T.ok(not (range.from <= base + 100 and range.to > base + 100), "the crowded second is in no range")
    for _, id in ipairs(range.ids) do
      joined[#joined + 1] = id
    end
  end
  T.eq(joined, { crowded[6] }, "the other ids are asked for")

  -- FillRemote: every record stands for itself
  local now = math.floor(net:Now())
  local own = say(a, { "mine" })[1]
  local tbl = a.sync:GetTable(TABLE)
  local origin = a.sync:GetOrigin()
  local version = a:Version(TABLE)
  local from, to = now - 500, now
  local function line(time, counter, lineOrigin)
    local id = versionId.make(time, lineOrigin or origin, counter)
    return { key = id, id = id, payload = { s = "Nota Scam", t = "filled" } }
  end
  local changedKeys = {}
  a.sync.RegisterCallback(changedKeys, "OnRecordChanged", function(_event, tableName, key, payload, isRemote)
    changedKeys[#changedKeys + 1] = { tableName, key, payload and payload.t, isRemote }
  end)
  local good, late = line(now - 100, 1), line(now - 50, 2)
  local filled, skipped = a.sync:FillRemote(TABLE, {
    line(now - 100, 1, "ZZZZ"), -- an origin that the clock does not know
    line(now - 600, 1), -- before the range
    { key = good.key, id = good.id, payload = { s = "", t = "bad payload" } },
    good,
    line(now, 1), -- at the end of the range
    late, -- the check of the caller refuses it
    { key = "other key", id = own, payload = { s = "Nota Scam", t = "x" } }, -- a key that is not its id
  }, from, to, function(record)
    return record.id ~= late.id or "seen"
  end)
  T.eq(filled, { good.key }, "only the record below the clock, in the range, and with a good payload is stored")
  T.eq(skipped, 6, "the other records are skipped, each for itself")
  T.eq(a.sync:Get(TABLE, good.key), { s = "Nota Scam", t = "filled" }, "the filled record is stored")
  T.eq(changedKeys, { { TABLE, good.key, "filled", true } }, "the callback fires once, as for a received record")
  T.eq(a:Version(TABLE), version, "the table version stays")
  T.eq(tbl.clock.ZZZZ, nil, "the clock got no entry")
  a.sync.UnregisterCallback(changedKeys, "OnRecordChanged")
end

--------------------------------------------------------------------------------
-- Replicas on the network
--------------------------------------------------------------------------------

-- A hole below the clock is found and filled; the table version never changes, and no pull runs
do
  local net, replicas = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2", "line 3" })
  net:Advance(200)
  T.eq(texts(b), { "line 1", "line 2", "line 3" }, "the push brings the lines to B")
  punch(b, ids[2])
  local version = a:Version(TABLE)
  T.eq(b:Version(TABLE), version, "the hole does not show in the table version")
  local changed = {}
  b.sync.RegisterCallback(changed, "OnRecordChanged", function(_event, tableName, key, _payload, isRemote)
    changed[#changed + 1] = { tableName, key, isRemote }
  end)
  local since = net:Now()
  net:Advance(2400)
  T.eq(texts(b), { "line 1", "line 2", "line 3" }, "B has its line again")
  T.eq(b.sync:GetTable(TABLE).records, a.sync:GetTable(TABLE).records, "the records of both are equal")
  T.eq(changed, { { TABLE, ids[2], true } }, "B's features hear of the filled line")
  T.eq(b:Version(TABLE), version, "the version of B is the same as before")
  T.eq(a:Version(TABLE), version, "and so is the version of A")
  T.eq(count(net, "G", b.name, a.name, since), 1, "B asked A once")
  T.eq(count(net, "G", a.name), 0, "A asked nobody")
  T.eq(count(net, "F", a.name, b.name, since), 1, "A answered with one batch")
  T.eq(count(net, "Q", nil, nil, since), 0, "no pull was needed")
  T.eq(b.session.gaps.stats.filled, 1, "the status counts one filled record")
  T.eq(b.session.gaps.stats.skipped, 0, "and none that was not taken")
  local status = table.concat(b.session:StatusLines(), "\n")
  T.ok(status:find("1 records filled", 1, true), "the status tells of the filled record")
  -- Equal again: later rounds ask for nothing
  net:Advance(6000)
  T.eq(count(net, "G"), 1, "no further request once the counts are equal")
end

-- Replicas with equal records send few counts between them and ask for nothing
do
  local names = {}
  for index = 1, 6 do
    names[index] = "Member " .. index
  end
  local net, replicas = start(names)
  say(replicas[1], { "one", "two" })
  say(replicas[4], { "three" })
  net:Advance(7200)
  for index = 2, 6 do
    T.eq(replicas[index].sync:GetTable(TABLE).records, replicas[1].sync:GetTable(TABLE).records,
      "the records of " .. names[index] .. " equal those of the first")
  end
  local sent = count(net, "C")
  -- One replica sends, the others hear their own counts and skip a round: two messages are at least 1200 s
  -- apart after the first round. Without that, 6 replicas would send about 30 in this time.
  T.ok(sent >= 2 and sent <= 8, "few messages with the counts: " .. sent)
  T.eq(count(net, "G"), 0, "nobody asks")
  T.eq(count(net, "F"), 0, "and nobody fills")
end

-- Two replicas that lack different lines of one hour hold the same number: the checksum tells them apart,
-- and each fills the other
do
  local net, replicas = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2", "line 3", "line 4" })
  net:Advance(200)
  punch(b, ids[2])
  punch(a, ids[3])
  T.eq(a:Version(TABLE), b:Version(TABLE), "the versions are equal")
  net:Advance(2400)
  T.eq(texts(a), { "line 1", "line 2", "line 3", "line 4" }, "A has all lines, its own lost one too")
  T.eq(texts(b), { "line 1", "line 2", "line 3", "line 4" }, "B has all lines")
end

-- A replica that holds fewer lines than the other and still one that the other lacks: the one with fewer
-- asks, and its request shows the other what that one lacks itself
do
  local net, replicas = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2", "line 3", "line 4" })
  net:Advance(200)
  punch(a, ids[2])
  punch(a, ids[3])
  punch(b, ids[1])
  local since = net:Now()
  net:Advance(2400)
  T.eq(texts(a), { "line 1", "line 2", "line 3", "line 4" }, "A has all lines")
  T.eq(texts(b), { "line 1", "line 2", "line 3", "line 4" }, "B has all lines")
  T.eq(count(net, "G", a.name, nil, since), 1, "A asked once")
  T.eq(count(net, "G", b.name, nil, since), 1, "B asked once, after A's request")
end

-- The case that the check is for: saved variables that were not written. A's client ends without saving,
-- A comes back with an older file and writes a line before its pull, so its clock covers the lost lines.
do
  local net, replicas, random = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  say(a, { "line 1", "line 2" })
  net:Advance(200)
  local saved = deepCopy(a.data)
  say(a, { "line 3", "line 4", "line 5" })
  net:Advance(200)
  T.eq(#texts(b), 5, "B holds the five lines")
  a:Logout()
  net:Advance(50)
  local again = Replica.new(net, a.name, { random = random, data = saved })
  again:Login()
  say(again, { "line 6" })
  net:Advance(300)
  T.eq(texts(b), { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6" }, "B gets the new line")
  T.eq(texts(again), { "line 1", "line 2", "line 6" }, "A lacks its own three lines")
  T.eq(again:Version(TABLE), b:Version(TABLE), "and the versions are equal: no pull will bring them")
  local version = b:Version(TABLE)
  net:Advance(3000)
  T.eq(texts(again), { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6" }, "the gap check brings them")
  T.eq(again.sync:GetTable(TABLE).records, b.sync:GetTable(TABLE).records, "the records of both are equal")
  T.eq(again:Version(TABLE), version, "the version is the same as before")
end

-- An hour with more ids than one request takes is asked for in parts
do
  local net, replicas = start({ "Nota Scam", "Other One" }, function(replica)
    replica.ns.syncGaps.MAX_IDS = 2
  end)
  local a, b = replicas[1], replicas[2]
  local ids = {}
  for index = 1, 7 do
    ids[index] = say(a, { "line " .. index })[1]
    net:Advance(3)
  end
  net:Advance(200)
  T.eq(#texts(b), 7, "B holds the seven lines")
  punch(b, ids[2])
  punch(b, ids[6])
  local since = net:Now()
  net:Advance(2400)
  T.eq(b.sync:GetTable(TABLE).records, a.sync:GetTable(TABLE).records, "B has all lines again")
  T.ok(count(net, "G", b.name, nil, since) >= 3, "B asked in several parts")
  T.eq(b.session.gaps.stats.filled, 2, "two records were filled")
end

-- A large gap: the peer sends no long answer. It answers `split`, and the hour is halved until each answer
-- is one short batch. Lines of one second cannot be halved and come in one answer of several batches.
do
  local net, replicas = start({ "Nota Scam", "Other One" }, function(replica)
    -- About 5 lines per batch
    replica.ns.syncGaps.BATCH_BYTES = 300
  end)
  local a, b = replicas[1], replicas[2]
  local ids = {}
  for index = 1, 40 do
    ids[index] = say(a, { "line " .. index })[1]
    net:Advance(4)
  end
  local crowded = {}
  for index = 1, 12 do
    crowded[index] = "crowded " .. index
  end
  local crowdedIds = say(a, crowded)
  net:Advance(200)
  T.eq(#texts(b), 52, "B holds all lines")
  for index = 3, 38 do
    punch(b, ids[index])
  end
  for index = 1, 12 do
    punch(b, crowdedIds[index])
  end
  local version = b:Version(TABLE)
  local since = net:Now()
  net:Advance(3000)
  T.eq(b.sync:GetTable(TABLE).records, a.sync:GetTable(TABLE).records, "B has all lines again")
  T.eq(b:Version(TABLE), version, "with the version from before")
  T.eq(b.session.gaps.stats.filled, 48, "48 records were filled")
  local splits, longAnswers, crowdedBatches = 0, 0, 0
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if entry.time >= since and messageType == "B" and fields.reason == "split" then
      splits = splits + 1
    elseif entry.time >= since and messageType == "F" then
      local isCrowded = fields.records[1] ~= nil and fields.records[1].payload.t:find("crowded", 1, true) ~= nil
      if isCrowded then
        crowdedBatches = crowdedBatches + 1
      elseif fields.batch > 1 or not fields.last then
        longAnswers = longAnswers + 1
      end
      T.ok(#fields.records <= 6, "no batch is longer than the limit")
    end
  end
  T.ok(splits >= 5, "the peer asked to halve the range: " .. splits .. " times")
  T.eq(b.session.gaps.stats.splits, splits, "the status counts the halved requests")
  T.eq(longAnswers, 0, "every answer that could be halved is one batch")
  T.ok(crowdedBatches >= 2, "the lines of one second come in one answer of several batches")
  T.eq(b.session.gaps.stats.timeouts, 0, "no request was left without an answer")
  T.eq(count(net, "G", a.name), 0, "A lacks nothing and asks nothing")
end

-- A peer that answers `split` whatever it is asked is given up after a limited number of halvings
do
  local net, replicas = start({ "Nota Scam", "Other One" }, function(replica, index)
    replica.ns.syncGaps.MAX_SPLITS = 5
    if index == 1 then
      -- The fields hide the handler of the session: every gap request is refused with `split`
      replica.session.parts.transport.onMessage = function(sender, messageType, fields)
        if messageType == "G" then
          replica.session:Refuse(sender, fields, "split", 0)
        else
          replica.session:OnMessage(sender, messageType, fields)
        end
      end
    end
  end)
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2" })
  net:Advance(200)
  punch(b, ids[1])
  net:Advance(2 * HOUR)
  T.eq(texts(b), { "line 2" }, "nothing comes from such a peer")
  local requests = count(net, "G", b.name)
  -- 2 tries for the state of the hour, each with its first request and 6 that follow a `split`
  T.ok(requests >= 7 and requests <= 14, "the halving ends: " .. requests .. " requests")
  T.eq(b.session.gaps.request, nil, "no request is left open")
end

-- No answer: a request ends after its timeout, and a peer that stays silent is asked a limited number of
-- times in a session
do
  local net, replicas = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2", "line 3" })
  net:Advance(200)
  punch(b, ids[2])
  net.dropIf = function(entry)
    return codec.decode(entry.text) == "F"
  end
  net:Advance(4 * HOUR)
  T.eq(texts(b), { "line 1", "line 3" }, "B still lacks the line")
  T.eq(count(net, "G", b.name), b.ns.syncGaps.MAX_SILENT, "B asked as often as the limit allows")
  T.eq(b.session.gaps.stats.timeouts, b.ns.syncGaps.MAX_SILENT, "every request timed out")
  T.eq(b.session.gaps.request, nil, "no request is left open")
  -- A new session asks again
  net.dropIf = nil
  b:Logout()
  net:Advance(10)
  b:Login()
  net:Advance(2400)
  T.eq(texts(b), { "line 1", "line 2", "line 3" }, "after a new login the line comes")
end

-- A busy peer is asked again, and the refused request does not count as a try
do
  local net, replicas = start({ "Nota Scam", "Other One" }, function(replica)
    replica.ns.syncGaps.MAX_TRIES = 1
  end)
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2", "line 3" })
  net:Advance(200)
  punch(b, ids[2])
  -- A answers the request of a third member for the whole time
  a.session:Gaps().serving = { peer = "Third One", table = TABLE, nonce = 1, batches = { {} }, sent = 1, left = 0,
    activeAt = net:Now() + 100000 }
  net:Advance(2400)
  T.eq(texts(b), { "line 1", "line 3" }, "B waits while A is busy")
  T.ok(count(net, "B", a.name, b.name) >= 2, "A refused more than once")
  T.eq(b.session.gaps.stats.timeouts, 0, "a refusal is no timeout")
  a.session.gaps.serving = nil
  net:Advance(100)
  T.eq(texts(b), { "line 1", "line 2", "line 3" }, "B gets the line when A is free")
end

-- In a fight nothing is asked; the request goes out afterwards
do
  local net, replicas = start({ "Nota Scam", "Other One" })
  local a, b = replicas[1], replicas[2]
  local ids = say(a, { "line 1", "line 2" })
  net:Advance(200)
  punch(b, ids[1])
  b:SetState({ inCombat = true })
  net:Advance(4000)
  T.eq(texts(b), { "line 2" }, "B asks for nothing in a fight")
  T.eq(count(net, "G"), 0, "no request went out")
  b:SetState({ inCombat = false })
  net:Advance(2400)
  T.eq(texts(b), { "line 1", "line 2" }, "after the fight the line comes")
  T.eq(count(net, "G", b.name, a.name), 1, "with one request")
end

--------------------------------------------------------------------------------
-- Members with an addon from before the gap check
--------------------------------------------------------------------------------

-- An old replica drops the new messages and is never asked; the new ones fill each other beside it, and
-- everything else goes on with the old one as before
do
  local net, replicas = start({ "Nota Scam", "Old One", "Third One" }, function(replica, index)
    if index == 2 then
      makeOld(replica)
    end
  end)
  local a, old, c = replicas[1], replicas[2], replicas[3]
  local ids = say(c, { "line 1", "line 2", "line 3" })
  net:Advance(200)
  T.eq(texts(old), { "line 1", "line 2", "line 3" }, "the old replica gets the lines by the push")
  punch(a, ids[2])
  net:Advance(2400)
  T.eq(texts(a), { "line 1", "line 2", "line 3" }, "A gets its line from the new replica")
  T.eq(count(net, "C", old.name), 0, "the old replica sends no counts")
  T.eq(count(net, "G", nil, old.name), 0, "nobody asks the old replica")
  T.eq(old.session.gaps, nil, "the old replica keeps no state of the gap check")
  -- The exchange that both know goes on
  say(old, { "from the old one" })
  say(a, { "from a new one" })
  net:Advance(300)
  for _, replica in ipairs({ a, old, c }) do
    T.eq(#texts(replica), 5, replica.name .. " holds all five lines")
  end
  T.eq(a:Version(TABLE), old:Version(TABLE), "the versions of old and new are equal")
end

-- With only an old replica beside it, a new one sends its counts into the void and nothing else happens
do
  local net, replicas = start({ "Nota Scam", "Old One" }, function(replica, index)
    if index == 2 then
      makeOld(replica)
    end
  end)
  local a, old = replicas[1], replicas[2]
  local ids = say(old, { "line 1", "line 2" })
  net:Advance(200)
  punch(a, ids[1])
  net:Advance(3 * HOUR)
  T.eq(texts(a), { "line 2" }, "the hole stays: the old replica cannot be asked")
  T.ok(count(net, "C", a.name) >= 1, "A has sent its counts")
  T.eq(count(net, "G"), 0, "no request")
  T.eq(count(net, "B"), 0, "no refusal")
  T.eq(a:Version(TABLE), old:Version(TABLE), "the versions stay equal")
end

-- Many replicas, lost messages, and holes at random: all end with the same lines. The gap check runs beside
-- the push, the pull, and the periodic summary, and none of them disturbs another.
do
  local random = T.newRandom()
  local net = Fakenet.new({ random = random, loss = 0.1 })
  local replicas = {}
  for index = 1, 6 do
    replicas[index] = Replica.new(net, "Member " .. index, { random = random })
    replicas[index]:Login()
  end
  net:Advance(100)
  local ids = {}
  for round = 1, 12 do
    local writer = replicas[random(1, #replicas)]
    ids[#ids + 1] = say(writer, { "line " .. round })[1]
    net:Advance(random(20, 400))
  end
  -- The messages that were lost are repaired by the summary and the pull
  net:Advance(3 * HOUR)
  for _, replica in ipairs(replicas) do
    T.eq(#texts(replica), #ids, replica.name .. " holds every line before the holes")
  end
  local version = replicas[1]:Version(TABLE)
  for index, replica in ipairs(replicas) do
    -- The first line is gone everywhere but on the first replica
    if index > 1 then
      punch(replica, ids[1])
    end
    for _ = 1, 3 do
      local line = random(2, #ids)
      -- Every line has one replica that keeps it: what nobody holds, nobody can give
      if line % #replicas + 1 ~= index and replica.sync:GetTable(TABLE).records[ids[line]] then
        punch(replica, ids[line])
      end
    end
  end
  local since = net:Now()
  net:Advance(12 * HOUR)
  for _, replica in ipairs(replicas) do
    T.eq(#texts(replica), #ids, replica.name .. " holds every line again")
    T.eq(replica:Version(TABLE), version, replica.name .. " has the version from before the holes")
  end
  T.eq(count(net, "Q", nil, nil, since), 0, "the holes caused no pull")
end

T.finish()
