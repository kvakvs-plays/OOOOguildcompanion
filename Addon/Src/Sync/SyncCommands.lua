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
local MAX_DEBUG_TEXT = 200

---Registers the table `debug`, when it is not registered yet. Core.lua calls it after the saved variables
---have loaded, when the setting is on; `/oooo sync debug on` calls it at once. A table cannot be taken out
---of the registry again, so turning the setting off needs a reload.
function commands.EnableDebugTable()
  if ns.sync.definitions[commands.DEBUG_TABLE] then
    return
  end
  ns.sync:RegisterTable({
    name = commands.DEBUG_TABLE,
    schema = 1,
    keyKind = "free",
    validate = function(_key, payload)
      return type(payload) == "string" and #payload >= 1 and #payload <= MAX_DEBUG_TEXT
    end,
    maxRecordBytes = 300,
    writers = "anyone",
    policy = { when = "nocombat", pushDelay = 10, minInterval = 30 },
  })
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

---Tells whether the table `debug` is registered; prints how to turn it on when it is not.
---@return boolean
local function hasDebugTable()
  if ns.sync.definitions[commands.DEBUG_TABLE] then
    return true
  end
  ns.print("The debug table is off. Turn it on with /oooo sync debug on.")
  return false
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

ns.syncSlash:Register("put", "put <key> <text> - write a record into the debug table", function(rest)
  local key, text = rest:match("^(%S+)%s+(.+)$")
  if not key then
    ns.print("Usage: /oooo sync put <key> <text>")
    return
  end
  if not hasDebugTable() then
    return
  end
  local written, reason = ns.sync:Put(commands.DEBUG_TABLE, key, text)
  if written == nil then
    ns.print(commands.escape("not written: " .. tostring(reason)))
  else
    ns.print(commands.escape(written and ("written: " .. key) or ("unchanged: " .. key)))
  end
end)

ns.syncSlash:Register("get", "get <key> - read a record of the debug table", function(rest)
  local key = rest:match("^(%S+)$")
  if not key then
    ns.print("Usage: /oooo sync get <key>")
    return
  end
  if not hasDebugTable() then
    return
  end
  local text = ns.sync:Get(commands.DEBUG_TABLE, key)
  ns.print(commands.escape(text and (key .. " = " .. tostring(text)) or ("no record: " .. key)))
end)

ns.syncSlash:Register("del", "del <key> - delete a record of the debug table", function(rest)
  local key = rest:match("^(%S+)$")
  if not key then
    ns.print("Usage: /oooo sync del <key>")
    return
  end
  if not hasDebugTable() then
    return
  end
  local deleted, reason = ns.sync:Delete(commands.DEBUG_TABLE, key)
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
    commands.EnableDebugTable()
    ns.print("Developer mode is on: the debug table, and the Sync page of the settings with its send settings. "
      .. "The debug table appears on that page after /reload.")
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
