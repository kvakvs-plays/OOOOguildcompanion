local addonName, ns = ...

-- Layout version of the saved variables and the steps that bring an older layout to the current one.
--
-- This file uses no WoW API: `migrate` takes the database and the random source as parameters, so the host
-- tests call it with plain tables (Tests/sync_migrate.lua). It loads after VersionId.lua.

---@class OOOOSyncData The shared database of this account, `db.global.sync` (.agents/00-plan.md, section 4.1)
---@field origin string 4 base-94 characters that name this install in every version id; made once
---@field tables table<string, OOOOSyncTable> Table name -> stored table

---@class OOOODatabaseModule
local database = {}
ns.database = database

---Version of the saved variables layout. Raise it together with a new entry in `steps`.
database.SCHEMA_VERSION = 2

---Migration steps: `steps[n]` brings layout n - 1 to layout n. A step adds what is missing and leaves
---the rest of the user's data alone.
---@type table<integer, fun(db: OOOODatabase)>
local steps = {
  -- Version 1 is the first layout: emoji settings in the profile
  [1] = function(_db) end,
  -- Version 2 adds the shared database
  [2] = function(db)
    if type(db.global.sync) ~= "table" then
      db.global.sync = {}
    end
    if type(db.global.sync.tables) ~= "table" then
      db.global.sync.tables = {}
    end
  end,
}

---Tells whether a value can be the origin of this install.
---@param origin any
---@return boolean
local function isOrigin(origin)
  return type(origin) == "string" and #origin == 4 and ns.base94.isValid(origin)
end

---Brings saved variables of an older addon version to the current layout, and makes the origin of this
---install at the first run. An existing origin is never replaced: it is part of every id that this
---install has written.
---@param db OOOODatabase The AceDB object, or a plain table with `global` in a host test
---@param randomFn fun(m: integer, n: integer): integer Like math.random(m, n); used for a new origin only
---@return boolean usable false when the data is from a newer addon version; it is then left untouched
function database.migrate(db, randomFn)
  local global = db.global
  local version = global.schemaVersion or 0
  if type(version) ~= "number" or version > database.SCHEMA_VERSION then
    return false
  end
  for step = version + 1, database.SCHEMA_VERSION do
    steps[step](db)
    global.schemaVersion = step
  end
  if not isOrigin(global.sync.origin) then
    global.sync.origin = ns.versionId.newOrigin(randomFn)
  end
  return true
end
