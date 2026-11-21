local addonName, ns = ...

-- The table `debug` and the commands `/oooo sync put|get|del|status|debug`, for testing the shared database
-- by hand (.agents/00-plan.md, step 3.4), and the developer mode that they belong to.
--
-- The developer mode is the setting `db.global.debugTable`, off by default and turned on with
-- `/oooo sync debug on`. Only with it does the table `debug` exist (a release has no table that every member
-- can fill with text), is the Sync page of the settings shown, and do the send settings of that page apply.
-- Other users run every table with the preset of its definition.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_alts.lua).

---@class OOOOSyncCommands
local commands = {}
ns.syncCommands = commands

---Name of the test table: free keys, a short text as payload, every member may write
commands.DEBUG_TABLE = "debug"
---Name of the test table of the officer rule: free keys, a short text, only an officer writes (plan 14.3)
commands.DEBUG_OFFICER_TABLE = "debugofficer"
local MAX_DEBUG_TEXT = 200

---Tells whether a payload is the short text of a developer table.
---@param _key string
---@param payload any
---@return boolean
local function isDebugText(_key, payload)
  return type(payload) == "string" and #payload >= 1 and #payload <= MAX_DEBUG_TEXT
end

---Registers a developer table with a text payload, when it is not registered yet.
---@param name string
---@param keyKind "character"|"free"
---@param writers string A value of `writers` in a table definition
local function registerDebugTable(name, keyKind, writers)
  if ns.sync.definitions[name] then
    return
  end
  ns.sync:RegisterTable({
    name = name,
    schema = 1,
    keyKind = keyKind,
    validate = isDebugText,
    maxRecordBytes = 300,
    writers = writers,
    policy = { when = "nocombat", pushDelay = 10, minInterval = 30 },
  })
end

---Registers the table `debug`, when it is not registered yet. `EnableDeveloperTables` calls it; the host
---tests call it alone, so that their hellos carry no other developer table.
function commands.EnableDebugTable()
  registerDebugTable(commands.DEBUG_TABLE, "free", "anyone")
end

---Registers the tables of the developer mode: `debug` and the protected `debugofficer`. Core.lua calls it
---after the saved variables have loaded, when the setting is on; `/oooo sync debug on` calls it at once. A
---table cannot be taken out of the registry again, so turning the setting off needs a reload.
function commands.EnableDeveloperTables()
  commands.EnableDebugTable()
  registerDebugTable(commands.DEBUG_OFFICER_TABLE, "free", "officer")
end

---Tells whether the developer mode is on.
---@return boolean
function commands.isDeveloper()
  local global = ns.db and ns.db.global
  return global ~= nil and global.debugTable == true
end

---Nothing changed: what `policyOverrides` gives outside the developer mode
local NO_OVERRIDES = {}

---Returns the changes to the send policy of the tables that apply now: those of the Sync page in the
---developer mode, none otherwise. A change that was made in the developer mode stays stored and has no
---effect while the mode is off, so no user is left with a setting that they cannot see.
---@return table<string, OOOOSyncPolicyOverride>
function commands.policyOverrides()
  if not commands.isDeveloper() then
    return NO_OVERRIDES
  end
  local settings = ns.db.profile and ns.db.profile.sync
  return type(settings) == "table" and type(settings.tables) == "table" and settings.tables or NO_OVERRIDES
end

---Tells whether a developer table is registered; prints how to turn it on when it is not.
---@param name string
---@return boolean
local function hasDebugTable(name)
  if ns.sync.definitions[name] then
    return true
  end
  if name == commands.DEBUG_TABLE then
    ns.print("The debug table is off. Turn it on with /oooo sync debug on.")
  else
    ns.print("The table " .. name .. " is off. Turn it on with /oooo sync debug on.")
  end
  return false
end

---The developer tables that `put`, `get`, and `del` name with their first word; without such a word they
---use the table `debug`, as before these tables existed
local NAMED_TABLES = { [commands.DEBUG_OFFICER_TABLE] = true }

---Splits the arguments of `put`, `get`, and `del` into the table and the rest.
---@param rest string
---@return string tableName
---@return string rest The arguments after the table name
local function splitTable(rest)
  local first, after = rest:match("^(%S+)%s*(.-)$")
  if first and NAMED_TABLES[first] then
    return first, after
  end
  return commands.DEBUG_TABLE, rest
end

---Reads the key and the text of `put`: the first word and the rest.
---@param _tableName string
---@param rest string
---@return string|nil key nil when the arguments do not fit
---@return string|nil text
local function putArguments(_tableName, rest)
  return rest:match("^(%S+)%s+(.+)$")
end

---Reads the key of `get` and `del`: one word.
---@param _tableName string
---@param rest string
---@return string|nil key nil when the arguments do not fit
local function keyArgument(_tableName, rest)
  return rest:match("^(%S+)$")
end

---Doubles every `|`, which starts an escape sequence in chat output. Version ids, origins, and stored
---text can hold it.
---@param text string
---@return string
function commands.escape(text)
  return (text:gsub("|", "||"))
end

---Builds the lines of `/oooo sync status`: the origin, for each table its records, its size, and its table
---version, and the state of discovery with the peers.
---@return string[] lines Ready for chat: every `|` is doubled
function commands.statusLines()
  local sync = ns.sync
  local origin = sync:GetOrigin()
  if not origin then
    return { "The shared database is not ready." }
  end
  -- The session exists only in the game, after login
  local current = ns.syncSession and ns.syncSession.current
  local lines = { commands.escape("origin: " .. origin) }
  for _, name in ipairs(sync.names) do
    local tbl = sync:GetTable(name)
    local live, deleted = sync:Count(name)
    lines[#lines + 1] = commands.escape(name .. ": " .. live .. " records, " .. deleted .. " deleted, "
      .. sync:Size(name) .. " bytes, version "
      .. (tbl and ns.syncStore.tableVersion(tbl) or "?")
      .. (current and (", may send: " .. current:SendState(name)) or ""))
  end
  if current then
    -- The rank decides what this character may write and send in a protected table (plan section 14)
    lines[#lines + 1] = "rank: " .. (sync:IsOfficer() and "officer" or "member")
    for _, line in ipairs(current:StatusLines()) do
      lines[#lines + 1] = commands.escape(line)
    end
  end
  return lines
end

ns.syncSlash:Register("status", "status - origin, the records, size, and version of each table, the peers", function()
  for _, line in ipairs(commands.statusLines()) do
    ns.print(line)
  end
end)

ns.syncSlash:Register("put", "put [debugofficer] <key> <text> - write a record into a developer table "
  .. "(default: debug)", function(rest)
  local tableName, arguments = splitTable(rest)
  local key, text = putArguments(tableName, arguments)
  if not key or not text then
    ns.print("Usage: /oooo sync put [debugofficer] <key> <text>")
    return
  end
  if not hasDebugTable(tableName) then
    return
  end
  local written, reason = ns.sync:Put(tableName, key, text)
  if written == nil then
    ns.print(commands.escape("not written: " .. tostring(reason)))
  else
    ns.print(commands.escape(written and ("written: " .. key) or ("unchanged: " .. key)))
  end
end)

ns.syncSlash:Register("get", "get [debugofficer] <key> - read a record of a developer table", function(rest)
  local tableName, arguments = splitTable(rest)
  local key = keyArgument(tableName, arguments)
  if not key then
    ns.print("Usage: /oooo sync get [debugofficer] <key>")
    return
  end
  if not hasDebugTable(tableName) then
    return
  end
  local text = ns.sync:Get(tableName, key)
  ns.print(commands.escape(text and (key .. " = " .. tostring(text)) or ("no record: " .. key)))
end)

ns.syncSlash:Register("del", "del [debugofficer] <key> - delete a record of a developer table", function(rest)
  local tableName, arguments = splitTable(rest)
  local key = keyArgument(tableName, arguments)
  if not key then
    ns.print("Usage: /oooo sync del [debugofficer] <key>")
    return
  end
  if not hasDebugTable(tableName) then
    return
  end
  local deleted, reason = ns.sync:Delete(tableName, key)
  if deleted == nil then
    ns.print(commands.escape("not deleted: " .. tostring(reason)))
  else
    ns.print(commands.escape(deleted and ("deleted: " .. key) or ("no record: " .. key)))
  end
end)

ns.syncSlash:Register("debug", "debug on|off - developer mode: the debug table and the Sync settings", function(rest)
  local word = rest:match("^(%S+)$")
  local global = ns.db and ns.db.global
  if (word ~= "on" and word ~= "off") or not global then
    ns.print(global and "Usage: /oooo sync debug on|off" or "The shared database is not ready.")
    return
  end
  global.debugTable = word == "on"
  if word == "on" then
    commands.EnableDeveloperTables()
    ns.print("Developer mode is on: the debug tables, and the Sync page of the settings with its send settings. "
      .. "The debug tables appear on that page after /reload.")
  else
    ns.print("Developer mode is off: the Sync page is hidden and every table sends by its preset. "
      .. "The debug table goes with the next /reload; its stored records stay in the saved data.")
  end
  -- The send settings that apply have changed: what waited for the old ones goes on
  local current = ns.syncSession and ns.syncSession.current
  if current then
    current:OnConditionsChanged()
  end
end)
