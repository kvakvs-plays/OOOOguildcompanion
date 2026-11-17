-- Host test of Addon/Src/Sync/SyncTables.lua: the registry of table definitions and the stored tables.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local FILES = { "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua",
  "Addon/Src/Sync/SyncTables.lua" }
local random = T.newRandom()
local START = 1795000000

---Makes a good definition; `changes` replaces fields, and the value "nil" removes one.
local function definition(changes)
  local result = {
    name = "equipment",
    schema = 1,
    keyKind = "character",
    validate = function() return true end,
    maxRecordBytes = 2000,
    writers = "owner",
  }
  for field, value in pairs(changes or {}) do
    if value == "nil" then
      result[field] = nil
    else
      result[field] = value
    end
  end
  return result
end

---Loads a fresh registry.
local function newSync()
  return T.loadAll(FILES).sync
end

---Makes an empty stored database.
local function newData()
  return { origin = "aB3$", tables = {} }
end

-- A good definition is stored with the policy defaults
do
  local sync = newSync()
  sync:RegisterTable(definition())
  local stored = sync.definitions.equipment
  T.eq(stored.policy, { when = "nocombat", pushDelay = 300, minInterval = 600 },
    "a table without a policy gets the defaults")
  T.eq(stored.memberRelay, false, "memberRelay is false when it is omitted")
  sync:RegisterTable(definition({ name = "guildbank", keyKind = "free", writers = "officer", memberRelay = true,
    policy = { when = "resting", minInterval = 0 } }))
  T.eq(sync.definitions.guildbank.policy, { when = "resting", pushDelay = 300, minInterval = 0 },
    "a policy replaces only the fields that it sets")
  T.eq(sync.definitions.guildbank.memberRelay, true, "memberRelay is kept")
  T.eq(sync.names, { "equipment", "guildbank" }, "the names are in the order of registration")
  T.raises(function() sync:RegisterTable(definition()) end, "a repeated name raises", "registered twice")
end

-- Each kind of bad definition raises
do
  local sync = newSync()
  local bad = {
    ["a definition that is not a table"] = { "name", "the definition must be a table" },
    ["a missing name"] = { { name = "nil" }, "bad name" },
    ["a name with an upper case letter"] = { { name = "Equipment" }, "bad name" },
    ["a name that starts with a digit"] = { { name = "1table" }, "bad name" },
    ["a name with a space"] = { { name = "my table" }, "bad name" },
    ["a name of 33 characters"] = { { name = string.rep("a", 33) }, "bad name" },
    ["an empty name"] = { { name = "" }, "bad name" },
    ["a missing schema"] = { { schema = "nil" }, "schema" },
    ["schema 0"] = { { schema = 0 }, "schema" },
    ["a schema with a fraction"] = { { schema = 1.5 }, "schema" },
    ["a schema that is a string"] = { { schema = "1" }, "schema" },
    ["an unknown keyKind"] = { { keyKind = "guild" }, "keyKind" },
    ["a missing keyKind"] = { { keyKind = "nil" }, "keyKind" },
    ["unknown writers"] = { { writers = "everyone" }, "writers" },
    ["missing writers"] = { { writers = "nil" }, "writers" },
    ["a missing validate"] = { { validate = "nil" }, "validate" },
    ["a validate that is not a function"] = { { validate = true }, "validate" },
    ["a missing maxRecordBytes"] = { { maxRecordBytes = "nil" }, "maxRecordBytes" },
    ["maxRecordBytes 0"] = { { maxRecordBytes = 0 }, "maxRecordBytes" },
    ["a memberRelay that is not a boolean"] = { { memberRelay = 1 }, "memberRelay" },
    ["a policy that is not a table"] = { { policy = "resting" }, "policy must be a table" },
    ["an unknown policy.when"] = { { policy = { when = "always" } }, "policy.when" },
    ["a negative pushDelay"] = { { policy = { pushDelay = -1 } }, "policy.pushDelay" },
    ["a minInterval that is a string"] = { { policy = { minInterval = "600" } }, "policy.minInterval" },
  }
  for name, case in pairs(bad) do
    local value = type(case[1]) == "table" and definition(case[1]) or case[1]
    T.raises(function() sync:RegisterTable(value) end, name .. " raises", case[2])
  end
  T.eq(sync.names, {}, "a bad definition registers nothing")
end

-- Initialize creates the stored table of each definition
do
  local sync = newSync()
  sync:RegisterTable(definition())
  T.eq({ sync:GetTable("equipment") }, { nil, nil, "not ready" }, "a table cannot be used before Initialize")
  T.eq(sync:GetOrigin(), nil, "there is no origin before Initialize")
  local data = newData()
  sync:Initialize(data, function() return START end, random)
  T.eq(data.tables.equipment, { schema = 1, clock = {}, maxId = "!!!!!!!!!!!", fp = 0, records = {} },
    "a registered table appears in the stored database")
  local tbl, stored = sync:GetTable("equipment")
  T.ok(tbl == data.tables.equipment, "GetTable returns the stored table")
  T.eq(stored.name, "equipment", "GetTable returns the definition")
  T.eq({ sync:GetTable("nosuch") }, { nil, nil, "unknown table" }, "GetTable names an unknown table")
  T.eq(sync:GetOrigin(), "aB3$", "GetOrigin returns the stored origin")

  -- A table that is registered after Initialize gets its storage at once
  sync:RegisterTable(definition({ name = "late" }))
  T.ok(data.tables.late, "a table registered after Initialize is stored at once")
end

-- Stored data is kept, a schema change empties the table, and an unknown stored table survives
do
  local ns = T.loadAll(FILES)
  local sync, store, versionId = ns.sync, ns.syncStore, ns.versionId
  local kept, changed, unknown = store.newTable(1), store.newTable(1), store.newTable(7)
  local id = versionId.make(START, "zzzz", 5)
  store.apply(kept, "Nota Scam", id, { level = 60 })
  store.apply(changed, "Nota Scam", id, { level = 60 })
  store.apply(unknown, "Key", id, "from a newer version")
  kept.syncedAt = START
  -- A stored file with stale derived values, as after an edit by hand
  kept.fp, kept.maxId = 12345, versionId.ZERO
  local data = { origin = "aB3$", tables = { kept = kept, changed = changed, future = unknown } }
  local unknownBefore = store.tableVersion(unknown)

  sync:RegisterTable(definition({ name = "kept" }))
  sync:RegisterTable(definition({ name = "changed", schema = 2 }))
  sync:Initialize(data, function() return START end, random)

  T.ok(data.tables.kept == kept, "a table with the same schema keeps its stored object")
  T.eq(kept.records["Nota Scam"], { v = id, d = { level = 60 } }, "a table with the same schema keeps its records")
  T.eq(kept.syncedAt, START, "a table with the same schema keeps its other fields")
  T.eq(kept.maxId, id, "maxId is computed again from the clock")
  T.eq(kept.fp, ns.base94.hash(id), "fp is computed again from the clock")

  T.eq(data.tables.changed, { schema = 2, clock = {}, maxId = versionId.ZERO, fp = 0, records = {} },
    "a schema change empties the records and the clock")

  T.ok(data.tables.future == unknown, "an unknown stored table survives")
  T.eq(store.tableVersion(unknown), unknownBefore, "an unknown stored table is unchanged")
  T.eq(unknown.records.Key.d, "from a newer version", "an unknown stored table keeps its records")
end

-- A stored table with a broken structure is replaced
do
  local sync = newSync()
  sync:RegisterTable(definition({ name = "noclock" }))
  sync:RegisterTable(definition({ name = "notatable" }))
  local data = { origin = "aB3$", tables = { noclock = { schema = 1, records = {} }, notatable = "text" } }
  sync:Initialize(data, function() return START end, random)
  T.eq(data.tables.noclock.clock, {}, "a stored table without a clock is replaced by an empty one")
  T.eq(type(data.tables.notatable), "table", "a stored value that is not a table is replaced")
end

T.finish()
