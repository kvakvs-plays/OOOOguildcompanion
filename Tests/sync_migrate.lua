-- Host test of Addon/Src/Database.lua: migration of the saved variables and the origin of the install.
local T = dofile("Tests/harness.lua")

local ns = T.load("Addon/Src/Sync/Base94.lua")
T.load("Addon/Src/Sync/VersionId.lua", ns)
T.load("Addon/Src/Database.lua", ns)
local database = ns.database
local random = T.newRandom()

---Copies a value with all tables inside it.
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

T.eq(database.SCHEMA_VERSION, 2, "the layout version is 2")

-- A version 1 database with emoji settings
do
  local db = {
    profile = { emoji = { disabled = { kekw = true } } },
    global = { schemaVersion = 1, probeResults = { strings = { build = "70300", lines = { "x" } } } },
  }
  local before = copy(db)
  T.eq(database.migrate(db, random), true, "a version 1 database is usable")
  T.eq(db.profile, before.profile, "the emoji settings are unchanged")
  T.eq(db.global.probeResults, before.global.probeResults, "other global data is unchanged")
  T.eq(db.global.schemaVersion, 2, "the layout version is raised to 2")
  T.eq(db.global.sync.tables, {}, "the sync structure exists and has no tables")
  local origin = db.global.sync.origin
  T.ok(type(origin) == "string" and #origin == 4 and ns.base94.isValid(origin), "the origin is 4 base-94 characters")

  -- A second run changes nothing
  local afterFirst = copy(db)
  T.eq(database.migrate(db, random), true, "a second run is usable")
  T.eq(db, afterFirst, "a second run changes nothing")
  T.eq(db.global.sync.origin, origin, "the origin stays the same")
end

-- A database without a version: the first run of the addon, or data from before the version field
do
  local db = { profile = {}, global = {} }
  T.eq(database.migrate(db, random), true, "a database without a version is usable")
  T.eq(db.global.schemaVersion, 2, "it gets the current layout version")
  T.ok(db.global.sync.origin, "it gets an origin")
end

-- Existing sync data is kept
do
  local tables = { debug = { schema = 1, clock = {}, maxId = "!!!!!!!!!!!", fp = 0, records = {} } }
  local db = { profile = {}, global = { schemaVersion = 2, sync = { origin = "aB3$", tables = tables } } }
  local before = copy(db)
  T.eq(database.migrate(db, random), true, "a version 2 database is usable")
  T.eq(db, before, "a version 2 database is unchanged")
  T.ok(db.global.sync.tables == tables, "the stored tables are the same object")
end

-- An origin that cannot be used is the only case in which one is made for an existing database
for name, bad in pairs({ ["a missing origin"] = false, ["a short origin"] = "abc", ["an origin with a space"] = "a cd",
  ["a number"] = 1234 }) do
  local db = { profile = {}, global = { schemaVersion = 2, sync = { origin = bad or nil, tables = {} } } }
  database.migrate(db, random)
  local origin = db.global.sync.origin
  T.ok(type(origin) == "string" and #origin == 4 and ns.base94.isValid(origin), name .. " is replaced by a new one")
end

-- Two installs get different origins
do
  local first, second = { global = {} }, { global = {} }
  database.migrate(first, random)
  database.migrate(second, random)
  T.ok(first.global.sync.origin ~= second.global.sync.origin, "two installs get different origins")
end

-- A database of a newer addon version is left alone
for name, version in pairs({ ["a greater version"] = 3, ["a version that is not a number"] = "2" }) do
  local db = { profile = { emoji = { disabled = {} } }, global = { schemaVersion = version, future = { 1, 2 } } }
  local before = copy(db)
  T.eq(database.migrate(db, random), false, name .. " is not usable")
  T.eq(db, before, name .. " is left alone")
end

T.finish()
