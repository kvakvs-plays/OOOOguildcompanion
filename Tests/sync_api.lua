-- Host test of the API in Addon/Src/Sync/SyncTables.lua: Put, Get, Delete, Iterate, Count, and the callback.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local ns = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua",
  "Addon/Src/Sync/SyncTables.lua" })
local sync, store, versionId = ns.sync, ns.syncStore, ns.versionId
local random = T.newRandom()

local now = 1795000000

sync:RegisterTable({
  name = "gear",
  schema = 1,
  keyKind = "character",
  -- A payload is a table with a level from 1 to 60
  validate = function(_key, payload)
    return type(payload) == "table" and type(payload.level) == "number" and payload.level >= 1 and payload.level <= 60
  end,
  maxRecordBytes = 2000,
  -- The owner rule has its own test, Tests/sync_owner.lua
  writers = "anyone",
})

-- Before Initialize nothing can be written or read
T.eq({ sync:Put("gear", "Nota Scam", { level = 10 }) }, { nil, "not ready" }, "Put before Initialize is refused")
T.eq({ sync:Delete("gear", "Nota Scam") }, { nil, "not ready" }, "Delete before Initialize is refused")
T.eq(sync:Get("gear", "Nota Scam"), nil, "Get before Initialize returns nil")
T.eq(sync:Iterate("gear")(), nil, "Iterate before Initialize gives nothing")

local data = { origin = "aB3$", tables = {} }
sync:Initialize(data, function() return now end, random)
local tbl = data.tables.gear

---Callback calls since the last `calls()`: the arguments after the event name, with a marker for nil
local fired = {}
sync.RegisterCallback("test", "OnRecordChanged", function(event, tableName, key, payload, isRemote)
  fired[#fired + 1] = { event, tableName, key, payload == nil and "<nil>" or payload, isRemote }
end)
local function calls()
  local result = fired
  fired = {}
  return result
end

-- Put then Get
do
  local payload = { level = 10, items = { 1, 2, 3 } }
  T.eq(sync:Put("gear", "Nota Scam", payload), true, "Put writes a new record")
  T.eq(sync:Get("gear", "Nota Scam"), { level = 10, items = { 1, 2, 3 } }, "Get returns the payload")
  T.eq(calls(), { { "OnRecordChanged", "gear", "Nota Scam", { level = 10, items = { 1, 2, 3 } }, false } },
    "the callback fires once with the table, the key, the payload, and isRemote = false")
  local firstId = tbl.records["Nota Scam"].v
  T.eq(versionId.originOf(firstId), "aB3$", "the id has the origin of this install")
  T.eq(tbl.maxId, firstId, "the table's maxId follows the write")
  T.eq(sync.dirtySince.gear, now, "the table is marked dirty with the time of the first change")

  -- A change of the caller's table after the Put does not reach the stored record
  payload.level = 11
  payload.items[1] = 99
  T.eq(sync:Get("gear", "Nota Scam"), { level = 10, items = { 1, 2, 3 } }, "the stored payload is a copy")

  -- An equal payload makes no new id and no callback
  T.eq(sync:Put("gear", "Nota Scam", { level = 10, items = { 1, 2, 3 } }), false, "an equal payload is not written")
  T.eq(tbl.records["Nota Scam"].v, firstId, "an equal payload makes no new id")
  T.eq(calls(), {}, "an equal payload fires no callback")

  -- A changed payload makes a greater id
  now = now + 100
  T.eq(sync:Put("gear", "Nota Scam", { level = 11, items = { 1, 2, 3 } }), true, "a changed payload is written")
  T.ok(tbl.records["Nota Scam"].v > firstId, "a changed payload gets a greater id")
  T.eq(sync:Put("gear", "Nota Scam", { level = 11, items = { 1, 2 } }), true, "a payload with fewer fields is a change")
  T.eq(sync:Put("gear", "Nota Scam", { level = 11, items = { 1, 2 }, extra = false }), true,
    "a payload with one more field is a change")
  T.eq(sync.dirtySince.gear, now - 100, "the dirty mark keeps the time of the first unsent change")
  T.eq(#calls(), 3, "each change fires the callback once")
end

-- A payload that fails validate is refused, and nothing changes
do
  local before = store.tableVersion(tbl)
  for name, bad in pairs({
    ["level 61"] = { level = 61 },
    ["a payload that is not a table"] = "text",
    ["a payload with a function"] = { level = 5, fn = print },
    ["a payload with NaN"] = { level = 5, value = 0 / 0 },
    ["a payload with infinity"] = { level = 5, value = math.huge },
    ["a payload with a boolean key"] = { level = 5, [true] = 1 },
  }) do
    T.eq({ sync:Put("gear", "Nota Scam", bad) }, { nil, "bad payload" }, name .. " is refused")
  end
  T.eq({ sync:Put("gear", "Nota Scam", nil) }, { nil, "bad payload" }, "a missing payload is refused")
  local deep = { level = 5 }
  local inner = deep
  for _ = 1, 9 do
    inner.next = {}
    inner = inner.next
  end
  T.eq({ sync:Put("gear", "Nota Scam", deep) }, { nil, "bad payload" }, "a payload nested 9 tables deep is refused")
  T.eq(store.tableVersion(tbl), before, "a refused payload changes nothing")
  T.eq(sync:Get("gear", "Nota Scam").level, 11, "the stored record is unchanged")
  T.eq(calls(), {}, "a refused payload fires no callback")
end

-- Keys
for name, bad in pairs({ ["an empty key"] = "", ["a key of 65 bytes"] = string.rep("k", 65), ["a number"] = 5 }) do
  T.eq({ sync:Put("gear", bad, { level = 1 }) }, { nil, "bad key" }, name .. " is refused by Put")
  T.eq({ sync:Delete("gear", bad) }, { nil, "bad key" }, name .. " is refused by Delete")
end
T.eq(sync:Put("gear", string.rep("k", 64), { level = 1 }), true, "a key of 64 bytes is accepted")
calls()

-- An unregistered table gives an error value and does not raise
T.eq({ sync:Put("nosuch", "Key", { level = 1 }) }, { nil, "unknown table" },
  "Put into an unregistered table is refused")
T.eq({ sync:Delete("nosuch", "Key") }, { nil, "unknown table" }, "Delete in an unregistered table is refused")
T.eq(sync:Get("nosuch", "Key"), nil, "Get from an unregistered table returns nil")
T.eq(sync:Iterate("nosuch")(), nil, "Iterate over an unregistered table gives nothing")
T.eq({ sync:Count("nosuch") }, { 0, 0 }, "Count of an unregistered table is 0")

-- Put, Delete, Get; Iterate skips the deleted key; a second Delete makes no new id
do
  sync:Put("gear", "Nota Tall", { level = 30 })
  sync:Put("gear", "Other One", { level = 5 })
  calls()
  T.eq(sync:Delete("gear", "Nota Tall"), true, "Delete removes a record")
  T.eq(sync:Get("gear", "Nota Tall"), nil, "Get returns nil after Delete")
  T.eq(tbl.records["Nota Tall"].x, true, "the deleted record is a tombstone")
  T.eq(calls(), { { "OnRecordChanged", "gear", "Nota Tall", "<nil>", false } },
    "the callback of a delete has no payload")
  local tombstoneId = tbl.records["Nota Tall"].v
  T.eq(sync:Delete("gear", "Nota Tall"), false, "a second Delete does nothing")
  T.eq(tbl.records["Nota Tall"].v, tombstoneId, "a second Delete makes no new id")
  T.eq(sync:Delete("gear", "Never Was"), false, "Delete of an absent key does nothing")
  T.eq(tbl.records["Never Was"], nil, "Delete of an absent key writes no tombstone")
  T.eq(calls(), {}, "a Delete that does nothing fires no callback")

  local listed = {}
  for key, payload in sync:Iterate("gear") do
    listed[key] = payload.level
  end
  T.eq(listed, { ["Nota Scam"] = 11, ["Other One"] = 5, [string.rep("k", 64)] = 1 },
    "Iterate lists the records that are not deleted")
  T.eq({ sync:Count("gear") }, { 3, 1 }, "Count gives the live records and the tombstones")

  -- A Put after a Delete brings the key back with a greater id
  T.eq(sync:Put("gear", "Nota Tall", { level = 31 }), true, "a Put after a Delete is written")
  T.ok(tbl.records["Nota Tall"].v > tombstoneId, "the record after a tombstone has a greater id")
  T.eq(sync:Get("gear", "Nota Tall"), { level = 31 }, "Get returns the new payload")
  calls()
end

-- A Put after a remote record with a later second still gets a greater id
do
  local remoteId = versionId.make(now + 200, "zzzz", 8000)
  store.apply(tbl, "Remote One", remoteId, { level = 60 })
  T.eq(sync:Put("gear", "Nota Scam", { level = 12 }), true, "a Put after a remote record is written")
  local localId = tbl.records["Nota Scam"].v
  T.ok(localId > remoteId, "the id is greater than the remote id of a later second")
  T.eq(versionId.parse(localId), now + 201, "its timestamp is the second after the remote id")
  -- Overwriting the remote record itself wins too
  T.eq(sync:Put("gear", "Remote One", { level = 1 }), true, "a Put over the remote record is written")
  T.eq(sync:Get("gear", "Remote One"), { level = 1 }, "the local write wins over the remote record")
end

-- Registered and unregistered callbacks
do
  calls()
  sync.UnregisterCallback("test", "OnRecordChanged")
  sync:Put("gear", "Nota Scam", { level = 13 })
  T.eq(calls(), {}, "an unregistered callback does not fire")
end

-- fp and maxId stayed current through the API
do
  local fp, maxId = tbl.fp, tbl.maxId
  store.rebuild(tbl)
  T.eq({ tbl.fp, tbl.maxId }, { fp, maxId }, "fp and maxId are current after the API calls")
end

T.finish()
