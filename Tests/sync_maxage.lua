-- Host test of `Append`, of `maxAge` in a table definition, and of `Expire` (.agents/00-plan.md, step 10.1;
-- Addon/Src/Sync/SyncTables.lua, `CheckRecord` in SyncPull.lua, `ExpireTables` in SyncCleanup.lua).
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local DAY = 86400
local KEEP = 14 * DAY

---Returns the definition of a log table that keeps its records for 14 days.
---@param overrides table? Fields that replace those of the definition
---@return table
local function logDefinition(overrides)
  local definition = {
    name = "log",
    schema = 1,
    keyKind = "free",
    maxRecordBytes = 200,
    writers = "anyone",
    maxAge = KEEP,
    validate = function(_key, payload)
      return type(payload) == "string" and payload ~= "bad"
    end,
    policy = { when = "nocombat", pushDelay = 10, minInterval = 30 },
  }
  for field, value in pairs(overrides or {}) do
    definition[field] = value
  end
  return definition
end

---Makes a replica with the table `log`.
---@param net Fakenet
---@param name string
---@return TestReplica
local function withLog(net, name)
  local replica = Replica.new(net, name, { random = random })
  replica.sync:RegisterTable(logDefinition())
  return replica
end

---Counts the records of a table, tombstones too.
---@param replica TestReplica
---@param tableName string
---@return integer
local function stored(replica, tableName)
  local live, deleted = replica.sync:Count(tableName)
  return live + deleted
end

-- The definition: `maxAge` is optional and must be a positive number
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  for _, bad in ipairs({ 0, -1, "14", math.huge }) do
    T.raises(function()
      a.sync:RegisterTable(logDefinition({ maxAge = bad }))
    end, "maxAge = " .. tostring(bad) .. " is refused", "maxAge")
  end
  a.sync:RegisterTable(logDefinition())
  T.eq(a.sync.definitions.log.maxAge, KEEP, "the registry keeps maxAge")
  T.eq(a.sync.definitions.debug.maxAge, nil, "a table without maxAge has none")
end

-- Append: the record is stored under its own id, and two in one second are in id order
do
  local net = Fakenet.new({ random = random })
  local a = withLog(net, "Nota Scam")
  local events = {}
  a.sync.RegisterCallback(events, "OnRecordChanged", function(_event, tableName, key, payload, isRemote)
    events[#events + 1] = { tableName, key, payload, isRemote }
  end)
  local first = a.sync:Append("log", "one")
  local second = a.sync:Append("log", "two")
  local tbl = a.sync:GetTable("log")
  T.ok(a.ns.versionId.isWellFormed(first) and a.ns.versionId.isWellFormed(second), "Append returns the new id")
  T.ok(first < second, "two records of one second are in id order")
  T.eq(a.ns.versionId.parse(first), a.ns.versionId.parse(second), "both have the same second")
  T.eq({ tbl.records[first].v, tbl.records[second].v }, { first, second }, "the key of a record is its own id")
  T.eq({ a.sync:Get("log", first), a.sync:Get("log", second) }, { "one", "two" }, "the payloads are stored")
  T.eq(tbl.maxId, second, "the table has seen the last id")
  T.ok(a.sync.dirtySince.log, "the table is marked as having unsent changes")
  T.eq(events, { { "log", first, "one", false }, { "log", second, "two", false } }, "the callback fires per record")

  local before = a:Version("log")
  T.eq({ a.sync:Append("nothing", "text") }, { nil, "unknown table" }, "an unknown table is refused")
  T.eq({ a.sync:Append("character", { class = "MAGE", level = 1, origins = { "AAAA" } }) }, { nil, "bad key" },
    "a table that is keyed by character takes no appended record")
  a.sync:RegisterTable(logDefinition({ name = "mine", writers = "owner" }))
  T.eq({ a.sync:Append("mine", "text") }, { nil, "not the owner" }, "nor does a table with the owner rule")
  T.eq({ a.sync:Append("log", nil) }, { nil, "bad payload" }, "no payload is refused")
  T.eq({ a.sync:Append("log", "bad") }, { nil, "bad payload" }, "a payload that fails validate is refused")
  T.eq({ a.sync:Append("log", string.rep("x", 200)) }, { nil, "too large" }, "a record over the limit is refused")
  T.eq(a:Version("log"), before, "a refused Append changes nothing")

  -- The stored payload is a copy
  local payload = { text = "kept" }
  a.sync:RegisterTable(logDefinition({ name = "notes", validate = function(_key, value)
    return type(value) == "table"
  end }))
  local id = a.sync:Append("notes", payload)
  payload.text = "changed"
  T.eq(a.sync:Get("notes", id).text, "kept", "a later change of the caller's table does not reach the record")
end

-- A received record that is older than the age is not stored, and the clock rises
do
  local net = Fakenet.new({ random = random })
  local a = withLog(net, "Nota Scam")
  a:Login()
  net:Advance(100)
  local versionId, store = a.ns.versionId, a.ns.syncStore
  local tbl = a.sync:GetTable("log")
  local raw = net:Join("Other One")
  local now = math.floor(net:Now())
  local other = versionId.make(now - 5, "RRRR", 0) .. "!!!!!"
  local old, edge, young = versionId.make(now - 15 * DAY, "XXXX", 0), versionId.make(now - KEEP - 100, "XXXX", 1),
    versionId.make(now - KEEP + 100, "XXXX", 2)
  local lone = versionId.make(now - 20 * DAY, "YYYY", 0)
  raw:Send(codec.encode("P", "log", 1, other, other, true, { XXXX = versionId.ZERO, YYYY = versionId.ZERO },
    Replica.protocol.packRecords({
      { key = "lone", id = lone, payload = "of 20 days ago" },
      { key = "old", id = old, payload = "of 15 days ago" },
      { key = "edge", id = edge, payload = "just over the age" },
      { key = "gone", id = versionId.make(now - KEEP - 50, "XXXX", 0), tombstone = true },
      { key = "young", id = young, payload = "just under the age" },
    }), nil), "GUILD")
  net:Advance(1)
  T.eq(a.sync:Get("log", "old"), nil, "a received record of 15 days ago is not stored")
  T.eq(a.sync:Get("log", "edge"), nil, "nor one that is just over the age")
  T.eq(tbl.records.gone, nil, "nor a tombstone over the age")
  T.eq(a.sync:Get("log", "young"), "just under the age", "a record under the age is stored")
  T.eq(tbl.clock.XXXX, young, "the later record of the same origin was not blocked")
  T.eq(tbl.clock.YYYY, lone, "the clock rises for an origin of which nothing is stored")
  T.eq(stored(a, "log"), 1, "one record is stored")
  -- The same records in a table without maxAge are all stored
  raw:Send(codec.encode("P", "debug", 1, other, other, true, { XXXX = versionId.ZERO },
    Replica.protocol.packRecords({ { key = "old", id = old, payload = "of 15 days ago" } }), nil), "GUILD")
  net:Advance(1)
  T.eq(a.sync:Get("debug", "old"), "of 15 days ago", "a table without maxAge stores a record of any age")
  T.eq(store.tableVersion(tbl):sub(1, versionId.LENGTH), young, "the table version follows the clock")
end

-- Expire removes the old records; the table version is the same before and after
do
  local net = Fakenet.new({ random = random })
  local a = withLog(net, "Nota Scam")
  local versionId, store = a.ns.versionId, a.ns.syncStore
  local tbl = a.sync:GetTable("log")
  local now = math.floor(net:Now())
  store.apply(tbl, "old", versionId.make(now - 15 * DAY, "XXXX", 0), "of 15 days ago")
  store.apply(tbl, "oldgone", versionId.make(now - 15 * DAY, "XXXX", 1), nil, true)
  store.apply(tbl, "young", versionId.make(now - 13 * DAY, "XXXX", 0), "of 13 days ago")
  store.apply(a.sync:GetTable("debug"), "old", versionId.make(now - 15 * DAY, "XXXX", 0), "kept")
  local own = a.sync:Append("log", "of now")
  local before = a:Version("log")
  local removed = {}
  a.sync.RegisterCallback(removed, "OnRecordChanged", function(_event, tableName, key, payload, isRemote)
    removed[#removed + 1] = { tableName, key, payload == nil, isRemote }
  end)
  local count
  a.sync:Expire("log", nil, function(number)
    count = number
  end)
  T.eq(count, 2, "Expire reports the record and the tombstone that it removed")
  T.eq(tbl.records.old, nil, "a record of 15 days ago is gone")
  T.eq(tbl.records.oldgone, nil, "and a tombstone of 15 days ago")
  T.eq(a.sync:Get("log", "young"), "of 13 days ago", "a record of 13 days ago stays")
  T.eq(a.sync:Get("log", own), "of now", "and a new one")
  T.eq(a:Version("log"), before, "the table version is the same before and after")
  T.eq(removed, { { "log", "old", true, true } }, "the callback fires for the removed record, not for the tombstone")

  a.sync:Expire("debug", nil, function(number)
    count = number
  end)
  T.eq({ count, a.sync:Get("debug", "old") }, { 0, "kept" }, "a table without maxAge is left alone")
  a.sync:Expire("nothing", nil, function(number)
    count = number + 100
  end)
  T.eq(count, 100, "an unknown table removes nothing and still reports")
end

-- The session expires at the start of a stay in the guild and then once per hour
do
  local net = Fakenet.new({ random = random })
  local a = withLog(net, "Nota Scam")
  local versionId, store = a.ns.versionId, a.ns.syncStore
  local tbl = a.sync:GetTable("log")
  local now = math.floor(net:Now())
  store.apply(tbl, "old", versionId.make(now - 15 * DAY, "XXXX", 0), "of 15 days ago")
  store.apply(tbl, "soon", versionId.make(now - KEEP + 1800, "XXXX", 1), "half an hour under the age")
  local before = a:Version("log")
  a:Login()
  T.eq(tbl.records.old, nil, "the old record is removed when the stay in the guild starts")
  T.ok(tbl.records.soon, "one under the age stays")
  net:Advance(3500)
  T.ok(tbl.records.soon, "nothing is removed between two runs")
  net:Advance(200)
  T.eq(tbl.records.soon, nil, "the run after an hour removes what has grown old")
  T.eq(a:Version("log"), before, "the table version is unchanged")
  a:Logout()
  T.eq(a.session.expiryTimer, nil, "the timer stops with the session")
end

-- A fresh replica pulls from one that still holds lines of 15 days ago and stores only the last 14 days
do
  local net = Fakenet.new({ random = random })
  local a = withLog(net, "Nota Scam")
  local b = withLog(net, "Other One")
  net:SetOnline("Other One", false)
  a:Login()
  net:Advance(100)
  -- After the login of A, so that its own cleanup has not removed them yet
  local versionId, store = a.ns.versionId, a.ns.syncStore
  local tbl = a.sync:GetTable("log")
  local now = math.floor(net:Now())
  for index = 1, 5 do
    store.apply(tbl, "old" .. index, versionId.make(now - 15 * DAY, "XXXX", index), "line of 15 days ago")
    store.apply(tbl, "gone" .. index, versionId.make(now - 16 * DAY, "YYYY", index), "of an origin without a new line")
    store.apply(tbl, "young" .. index, versionId.make(now - 5 * DAY, "XXXX", index), "line of 5 days ago")
  end
  local own = a.sync:Append("log", "line of now")
  T.eq(stored(a, "log"), 16, "the responder holds 16 records, 10 of them over the age")
  b:Login()
  net:Advance(600)
  T.eq(b:Version("log"), a:Version("log"), "both replicas end with the same table version")
  T.eq(stored(b, "log"), 6, "the fresh replica stores only the records of the last 14 days")
  T.eq(b.sync:Get("log", "old1"), nil, "none of 15 days ago")
  T.eq(b.sync:Get("log", "young5"), "line of 5 days ago", "those of 5 days ago")
  T.eq(b.sync:Get("log", own), "line of now", "and the new one")
  T.eq(b.sync:GetTable("log").clock.YYYY, tbl.clock.YYYY, "the clock covers the origin of which nothing was stored")
  T.eq(b.session.pull, nil, "no pull is left running")
  local pulls = Replica.count(net, "Q")
  net:Advance(3600)
  T.eq(Replica.count(net, "Q"), pulls, "and none follows: equal versions, different numbers of old records")
  T.eq(stored(a, "log"), 6, "the responder has removed its old records with its hourly run")
  T.eq(b:Version("log"), a:Version("log"), "without a change of its table version")
end

T.finish()
