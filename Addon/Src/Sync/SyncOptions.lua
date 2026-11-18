local addonName, ns = ...

-- The "Sync" page of the settings window (.agents/00-plan.md, section 7.4): for each table of the shared
-- database whether it is on, when it may send, its two delays, and a status line.
--
-- `statusText`, `ago`, `setOverride`, and `getValue` use no WoW API, so the host tests run them
-- (Tests/sync_policy.lua). `buildTab` gives an AceConfig group and runs in the game.

---@class OOOOSyncTableStatus What the status line of one table shows
---@field enabled boolean false when the user has turned the table off
---@field records integer Records that are not deleted
---@field now number Server time
---@field syncedAt number|nil Server time of the last completed pull
---@field source string|nil Character name of the peer from which a pull runs
---@field batch integer|nil Number of the batch that the running pull waits for
---@field servingTo string|nil Character name of the peer to which this replica sends the table
---@field servingBatch integer|nil Number of the batch that was sent last
---@field servingTotal integer|nil Number of batches of that transfer

---@class OOOOSyncOptions
local options = {}
ns.syncOptions = options

---What the user sees for each value of `when`
options.WHEN_LABELS = {
  nocombat = "Not in combat",
  noraid = "Not in combat, raid, or instance",
  resting = "Only in a city or an inn",
}
---The fields of a policy that the page can change
local FIELDS = { enabled = true, when = true, pushDelay = true, minInterval = true }

---Says how long ago a time was, in the largest fitting unit.
---@param seconds number
---@return string
function options.ago(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return seconds .. " s ago"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. " min ago"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. " h ago"
  end
  return math.floor(seconds / 86400) .. " d ago"
end

---Builds the status line of one table from plain values.
---@param status OOOOSyncTableStatus
---@return string
function options.statusText(status)
  if not status.enabled then
    return "Turned off: " .. status.records .. " records, neither sent nor requested"
  end
  local text = status.records .. " records"
  if status.source then
    text = text .. ", pulling from " .. status.source .. " (batch " .. (status.batch or 1) .. ")"
  elseif status.syncedAt then
    text = text .. ", last pull " .. options.ago(status.now - status.syncedAt)
  else
    text = text .. ", no pull yet"
  end
  if status.servingTo then
    text = text .. ", sending to " .. status.servingTo .. " (batch " .. (status.servingBatch or 0) .. " of "
      .. (status.servingTotal or 0) .. ")"
  end
  return text
end

---Stores what the user has set for one field of a table's policy. Only `overrides` is written: a value
---equal to the table definition removes the override, and a table without overrides is removed.
---@param overrides table<string, OOOOSyncPolicyOverride> `db.profile.sync.tables`
---@param defaults OOOOSyncPolicy The `policy` of the table definition
---@param tableName string
---@param field "enabled"|"when"|"pushDelay"|"minInterval"
---@param value any
function options.setOverride(overrides, defaults, tableName, field, value)
  if not FIELDS[field] then
    return
  end
  local default = defaults[field]
  if field == "enabled" then
    default = true
  end
  local override = overrides[tableName]
  if value == default then
    if type(override) == "table" then
      override[field] = nil
      if next(override) == nil then
        overrides[tableName] = nil
      end
    end
    return
  end
  if type(override) ~= "table" then
    override = {}
    overrides[tableName] = override
  end
  override[field] = value
end

---Returns the value that a control of the page shows: the policy of the table after the overrides.
---@param overrides table<string, OOOOSyncPolicyOverride>|nil
---@param defaults OOOOSyncPolicy
---@param tableName string
---@param field "enabled"|"when"|"pushDelay"|"minInterval"
---@return any
function options.getValue(overrides, defaults, tableName, field)
  return ns.syncPolicy.effective(defaults, type(overrides) == "table" and overrides[tableName] or nil)[field]
end

---Collects the values of a table's status line from the database and the session.
---@param tableName string
---@return OOOOSyncTableStatus
local function readStatus(tableName)
  local sync = ns.sync
  local tbl = sync:GetTable(tableName)
  local current = ns.syncSession.current
  local status = {
    enabled = options.getValue(ns.db.profile.sync.tables, sync.definitions[tableName].policy, tableName, "enabled"),
    records = (sync:Count(tableName)),
    now = GetServerTime(),
    syncedAt = tbl and tbl.syncedAt,
  }
  local active, serving = current and current.pull, current and current.serving
  if active and active.table == tableName then
    status.source, status.batch = active.peer, active.nextBatch
  end
  if serving and serving.table == tableName then
    status.servingTo, status.servingBatch, status.servingTotal = serving.peer, serving.sent, #serving.batches
  end
  return status
end

---The Sync tab: one group per table of the shared database.
---@return table group AceConfig group
function options.buildTab()
  ---AceConfig `get`; `info.arg` is `{ table name, field }`.
  local function get(info)
    local tableName, field = info.arg[1], info.arg[2]
    return options.getValue(ns.db.profile.sync.tables, ns.sync.definitions[tableName].policy, tableName, field)
  end
  ---AceConfig `set`; `info.arg` is `{ table name, field }`.
  local function set(info, value)
    local tableName, field = info.arg[1], info.arg[2]
    options.setOverride(ns.db.profile.sync.tables, ns.sync.definitions[tableName].policy, tableName, field, value)
    -- What waited for the old setting goes on with the new one
    local current = ns.syncSession.current
    if current then
      current:OnConditionsChanged()
    end
  end

  local args = {
    hint = {
      type = "description",
      order = 0,
      name = "The guild data is exchanged with other members in the background. "
        .. "These settings change when your game sends; receiving is always on.\n ",
    },
  }
  for index, tableName in ipairs(ns.sync.names) do
    args[tableName] = {
      type = "group",
      order = index,
      name = tableName,
      inline = true,
      get = get,
      set = set,
      args = {
        status = {
          type = "description",
          order = 0,
          name = function()
            return options.statusText(readStatus(tableName))
          end,
        },
        enabled = {
          type = "toggle",
          order = 1,
          name = "Enabled",
          desc = "Off: this table is neither sent nor requested.",
          arg = { tableName, "enabled" },
        },
        when = {
          type = "select",
          order = 2,
          name = "Send",
          desc = "The weakest state in which this table may send.",
          values = options.WHEN_LABELS,
          sorting = ns.syncPolicy.WHEN,
          arg = { tableName, "when" },
        },
        pushDelay = {
          type = "range",
          order = 3,
          name = "Wait after a change (s)",
          desc = "Seconds to wait after a change of yours, so that several changes go out together.",
          min = 0,
          max = ns.syncPolicy.MAX_SECONDS,
          softMax = 3600,
          step = 1,
          bigStep = 10,
          arg = { tableName, "pushDelay" },
        },
        minInterval = {
          type = "range",
          order = 4,
          name = "Shortest time between sends (s)",
          desc = "Seconds that must pass between two sends of your changes in this table.",
          min = 0,
          max = ns.syncPolicy.MAX_SECONDS,
          softMax = 7200,
          step = 1,
          bigStep = 30,
          arg = { tableName, "minInterval" },
        },
      },
    }
  end

  return {
    type = "group",
    order = 2,
    name = "Sync",
    args = args,
  }
end
