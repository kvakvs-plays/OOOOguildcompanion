local addonName, ns = ...

-- When a table of the shared database may send (.agents/00-plan.md, section 7.4): the conditions of the
-- game (combat, raid, instance, resting) and the policy of each table, which is the table definition with
-- the overrides of the user.
--
-- `conditionMet`, `effective`, and `new` use no WoW API, so the host tests run them (Tests/sync_policy.lua).
-- `Start` and `Refresh` read the game. It needs LibStub and CallbackHandler-1.0.

---@class OOOOSyncConditions What the game is doing, as far as sending depends on it
---@field inCombat boolean
---@field inRaid boolean In a raid group
---@field inInstance boolean In a dungeon, a raid, or another instance
---@field resting boolean In a city or an inn

---@class OOOOSyncEffectivePolicy The policy of one table after the overrides
---@field when "nocombat"|"noraid"|"resting" Weakest state in which the table may send
---@field pushDelay number Seconds to wait after a local change
---@field minInterval number Shortest time in seconds between two pushes
---@field enabled boolean false: the table is neither sent nor requested

---@class OOOOSyncPolicyOverride What the user has set for one table; every field is optional
---@field when string|nil
---@field pushDelay number|nil
---@field minInterval number|nil
---@field enabled boolean|nil

---@class OOOOSyncPolicyParts What `policy.new` is built from
---@field sync OOOOSync The table registry
---@field overrides fun(): table<string, OOOOSyncPolicyOverride>|nil Table name -> override
---@field state fun(): OOOOSyncConditions

---@class OOOOSyncPolicyView Answers the session's questions about sending
---@field Get fun(self: OOOOSyncPolicyView, tableName: string): OOOOSyncEffectivePolicy|nil
---@field IsEnabled fun(self: OOOOSyncPolicyView, tableName: string): boolean
---@field MayTalk fun(self: OOOOSyncPolicyView): boolean
---@field MaySend fun(self: OOOOSyncPolicyView, tableName: string): boolean

---@class OOOOSyncPolicyModule
---@field state OOOOSyncConditions The conditions of the game, kept current after `Start`
---@field frame table|nil The event frame; nil until `Start`
---@field callbacks table CallbackHandler registry; fires "OnConditionsChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)
---@field UnregisterAllCallbacks fun(owner: any)
local policy = {}
ns.syncPolicy = policy

---The values of `when`, from the weakest condition to the strongest
policy.WHEN = { "nocombat", "noraid", "resting" }
---Greatest `pushDelay` and `minInterval` that an override can set: one day
policy.MAX_SECONDS = 86400

local IS_WHEN = { nocombat = true, noraid = true, resting = true }

---Until the game is read, nothing may send: the state counts as combat
policy.state = { inCombat = true, inRaid = false, inInstance = false, resting = false }

---`ns.syncPolicy.RegisterCallback(owner, "OnConditionsChanged", function(event) end)` fires when a field
---of `policy.state` has changed.
policy.callbacks = LibStub("CallbackHandler-1.0"):New(policy)

---Tells whether a table with the given `when` may send in the given state. Each value includes the ones
---before it: `noraid` also needs `nocombat`, and `resting` also needs `noraid`.
---@param when string
---@param state OOOOSyncConditions
---@return boolean
function policy.conditionMet(when, state)
  if state.inCombat then
    return false
  end
  if when == "nocombat" then
    return true
  end
  if state.inRaid or state.inInstance then
    return false
  end
  if when == "noraid" then
    return true
  end
  return when == "resting" and state.resting == true
end

---Tells whether a value is a number of seconds that an override can set.
---@param value any
---@return boolean
local function isSeconds(value)
  return type(value) == "number" and value >= 0 and value <= policy.MAX_SECONDS
end

---Joins the policy of a table definition with an override. A field of the override with a bad value is
---ignored: the saved variables can hold anything.
---@param defaults OOOOSyncPolicy The `policy` of a table definition: `when`, `pushDelay`, `minInterval`
---@param override any
---@return OOOOSyncEffectivePolicy
function policy.effective(defaults, override)
  local result = { when = defaults.when, pushDelay = defaults.pushDelay, minInterval = defaults.minInterval,
    enabled = true }
  if type(override) ~= "table" then
    return result
  end
  if IS_WHEN[override.when] then
    result.when = override.when
  end
  if isSeconds(override.pushDelay) then
    result.pushDelay = override.pushDelay
  end
  if isSeconds(override.minInterval) then
    result.minInterval = override.minInterval
  end
  if type(override.enabled) == "boolean" then
    result.enabled = override.enabled
  end
  return result
end

---Makes the object that the session asks before it sends.
---@param parts OOOOSyncPolicyParts
---@return OOOOSyncPolicyView
function policy.new(parts)
  local view = {}

  ---Returns the policy of a table after the overrides.
  ---@param tableName string
  ---@return OOOOSyncEffectivePolicy|nil effective nil for a table that is not registered
  function view:Get(tableName)
    local definition = parts.sync.definitions[tableName]
    if not definition then
      return nil
    end
    local overrides = parts.overrides()
    return policy.effective(definition.policy, type(overrides) == "table" and overrides[tableName] or nil)
  end

  ---Tells whether a table takes part in the exchange at all.
  ---@param tableName string
  ---@return boolean
  function view:IsEnabled(tableName)
    local effective = self:Get(tableName)
    return effective ~= nil and effective.enabled
  end

  ---Tells whether this replica may send the small messages that belong to no table: hello and summary.
  ---@return boolean
  function view:MayTalk()
    return policy.conditionMet("nocombat", parts.state())
  end

  ---Tells whether a table may send its records, or ask for records, now.
  ---@param tableName string
  ---@return boolean
  function view:MaySend(tableName)
    local effective = self:Get(tableName)
    return effective ~= nil and effective.enabled and policy.conditionMet(effective.when, parts.state())
  end

  return view
end

--------------------------------------------------------------------------------
-- The conditions of the game
--------------------------------------------------------------------------------

---Reads a flag of the game. A secret value cannot be tested, so it counts as the given value.
---@param value any
---@param whenSecret boolean
---@return boolean
local function flag(value, whenSecret)
  if issecretvalue(value) then
    return whenSecret
  end
  return value == true
end

---Sets fields of `policy.state` and fires "OnConditionsChanged" when one has changed.
---@param changes table<string, boolean>
local function update(changes)
  local changed = false
  for field, value in pairs(changes) do
    if policy.state[field] ~= value then
      policy.state[field] = value
      changed = true
    end
  end
  if changed then
    policy.callbacks:Fire("OnConditionsChanged")
  end
end

---Reads all conditions from the game. A value that is secret counts as the one that forbids sending.
function policy.Refresh()
  local inInstance = IsInInstance()
  update({
    inCombat = flag(InCombatLockdown(), true),
    inRaid = flag(IsInRaid(), true),
    inInstance = flag(inInstance, true),
    resting = flag(IsResting(), false),
  })
end

---Event name -> handler
---@type table<string, fun()>
local handlers = {
  -- `InCombatLockdown` can still give the old value inside these two events
  PLAYER_REGEN_DISABLED = function()
    update({ inCombat = true })
  end,
  PLAYER_REGEN_ENABLED = function()
    update({ inCombat = false })
  end,
  PLAYER_UPDATE_RESTING = policy.Refresh,
  GROUP_ROSTER_UPDATE = policy.Refresh,
  PLAYER_ENTERING_WORLD = policy.Refresh,
}

---Starts following the conditions of the game. Core.lua calls it on PLAYER_LOGIN.
function policy.Start()
  if policy.frame then
    return
  end
  local frame = CreateFrame("Frame")
  policy.frame = frame
  frame:SetScript("OnEvent", function(_frame, event)
    handlers[event]()
  end)
  for event in pairs(handlers) do
    frame:RegisterEvent(event)
  end
  policy.Refresh()
end
