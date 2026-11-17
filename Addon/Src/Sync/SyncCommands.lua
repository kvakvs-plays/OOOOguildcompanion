local addonName, ns = ...

-- The table `debug` and the commands `/oooo sync put|get|del|status`, for testing the shared database by
-- hand (.agents/00-plan.md, step 3.4).
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_alts.lua).

---@class OOOOSyncCommands
local commands = {}
ns.syncCommands = commands

---Name of the test table: free keys, a short text as payload, every member may write
commands.DEBUG_TABLE = "debug"
local MAX_DEBUG_TEXT = 200

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

---Doubles every `|`, which starts an escape sequence in chat output. Version ids, origins, and stored
---text can hold it.
---@param text string
---@return string
function commands.escape(text)
  return (text:gsub("|", "||"))
end

---Builds the lines of `/oooo sync status`: the origin, for each table its records and table version, and
---the state of discovery with the peers.
---@return string[] lines Ready for chat: every `|` is doubled
function commands.statusLines()
  local sync = ns.sync
  local origin = sync:GetOrigin()
  if not origin then
    return { "The shared database is not ready." }
  end
  local lines = { commands.escape("origin: " .. origin) }
  for _, name in ipairs(sync.names) do
    local tbl = sync:GetTable(name)
    local live, deleted = sync:Count(name)
    lines[#lines + 1] = commands.escape(name .. ": " .. live .. " records, " .. deleted .. " deleted, version "
      .. (tbl and ns.syncStore.tableVersion(tbl) or "?"))
  end
  -- The session exists only in the game, after login
  local current = ns.syncSession and ns.syncSession.current
  if current then
    for _, line in ipairs(current:StatusLines()) do
      lines[#lines + 1] = commands.escape(line)
    end
  end
  return lines
end

ns.syncSlash:Register("status", "status - origin, the record count and version of each table, and the peers", function()
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
  local text = ns.sync:Get(commands.DEBUG_TABLE, key)
  ns.print(commands.escape(text and (key .. " = " .. tostring(text)) or ("no record: " .. key)))
end)

ns.syncSlash:Register("del", "del <key> - delete a record of the debug table", function(rest)
  local key = rest:match("^(%S+)$")
  if not key then
    ns.print("Usage: /oooo sync del <key>")
    return
  end
  local deleted, reason = ns.sync:Delete(commands.DEBUG_TABLE, key)
  if deleted == nil then
    ns.print(commands.escape("not deleted: " .. tostring(reason)))
  else
    ns.print(commands.escape(deleted and ("deleted: " .. key) or ("no record: " .. key)))
  end
end)
