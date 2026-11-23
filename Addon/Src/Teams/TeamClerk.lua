local addonName, ns = ...

-- The clerk of the teams feature (.agents/user-wishes.md, "Permissions"): a member cannot write the table
-- `team`, so the addon of an online officer does two things for the members.
--
-- - It copies the alias request of an assigned character (table `team_alias`) into the record of its team.
--   The request can arrive first hand, from another officer, or with a pull; it does not matter, because
--   nothing depends on the time of receipt. The team keeps the id of the request, so every officer sees
--   whether a request is already applied, and the newest request of a team wins.
-- - It adds an account id that an assigned character has got since it was assigned (a second install) to the
--   team, unless another team holds it.
--
-- Each check runs after a random delay, so that of several online officers usually one writes and the others
-- find the work done. Two officers who write the same thing do no harm.
--
-- This file uses no WoW API at file scope, so the host tests load it (Tests/sync_teams.lua).

---@class OOOOTeamClerkTimer A timer that can be stopped before it fires
---@field Cancel fun(self: OOOOTeamClerkTimer)

---@class OOOOTeamClerkParts What a clerk is built from
---@field sync OOOOSync
---@field model OOOOTeamsModel
---@field after fun(seconds: number, fn: fun()): OOOOTeamClerkTimer Calls `fn` once, `seconds` from now
---@field random fun(): number A number in [0, 1)

---@class OOOOTeamClerkModule
---@field current OOOOTeamClerk|nil The clerk of the game, made by `Start`
local clerk = {}
ns.teamClerk = clerk

local data = ns.teamData
local TABLE, REQUEST_TABLE = data.TABLE, data.REQUEST_TABLE

---Longest delay in seconds between a change and its check; the delay is random
clerk.DELAY_MAX = 10
---Seconds after the start before all stored requests are checked once: a request that arrived while no
---officer was online, or whose check an officer's logout cut off
clerk.SCAN_DELAY = 45

---@class OOOOTeamClerk
---@field sync OOOOSync
---@field model OOOOTeamsModel
---@field after fun(seconds: number, fn: fun()): OOOOTeamClerkTimer
---@field random fun(): number
---@field pending table<string, OOOOTeamClerkTimer> Character name -> the check that waits
---@field scanTimer OOOOTeamClerkTimer|nil
local Clerk = {}
Clerk.__index = Clerk

---Makes a clerk and registers it for "OnRecordChanged" of the engine. It acts only while the logged-in
---character is an officer, which it asks at every check.
---@param parts OOOOTeamClerkParts
---@return OOOOTeamClerk
function clerk.new(parts)
  local self = setmetatable({
    sync = parts.sync,
    model = parts.model,
    after = parts.after,
    random = parts.random,
    pending = {},
  }, Clerk)
  self.sync.RegisterCallback(self, "OnRecordChanged", function(_event, tableName, key, payload)
    self:OnRecordChanged(tableName, key, payload)
  end)
  self.scanTimer = self.after(clerk.SCAN_DELAY + self.random() * clerk.DELAY_MAX, function()
    self.scanTimer = nil
    self:Scan()
  end)
  return self
end

---Builds the clerk of the game as `clerk.current`, replacing an earlier one. Called after login, after
---`ns.teams.Start`, never at file scope.
---@return OOOOTeamClerk
function clerk.Start()
  if clerk.current then
    clerk.current:Stop()
  end
  clerk.current = clerk.new({
    sync = ns.sync,
    model = ns.teams.current,
    after = C_Timer.NewTimer,
    random = math.random,
  })
  return clerk.current
end

---Unregisters the clerk and drops its pending checks.
function Clerk:Stop()
  self.sync.UnregisterCallback(self, "OnRecordChanged")
  for _, timer in pairs(self.pending) do
    timer:Cancel()
  end
  self.pending = {}
  if self.scanTimer then
    self.scanTimer:Cancel()
    self.scanTimer = nil
  end
end

---Handles a change of a record: a request, the assignment of a character (its request may have come first),
---or the record of a character (it may list a new account id).
---@param tableName string
---@param key string
---@param payload any nil for a deleted record
function Clerk:OnRecordChanged(tableName, key, payload)
  if payload == nil then
    return
  end
  if tableName == REQUEST_TABLE or tableName == ns.syncCharacter.TABLE then
    self:Schedule(key)
  elseif tableName == TABLE then
    local parts = data.parseKey(key)
    if parts and parts.kind == "character" then
      self:Schedule(parts.name)
    end
  end
end

---Schedules the check of a character after a random delay, unless one waits already. Nothing is scheduled
---while the logged-in character is no officer.
---@param name string Character name
function Clerk:Schedule(name)
  if self.pending[name] or not self.sync:IsOfficer() then
    return
  end
  self.pending[name] = self.after(self.random() * clerk.DELAY_MAX, function()
    self.pending[name] = nil
    self:Check(name)
  end)
end

---Does what is open for a character: applies its alias request, and adds its new account ids to its team.
---@param name string Character name
function Clerk:Check(name)
  if not self.sync:IsOfficer() then
    return
  end
  self.model:ApplyRequest(name)
  local index = self.model:Index()
  local id = index.ofName[name]
  if not id then
    return
  end
  for _, origin in ipairs(self.model:OriginsOf(name)) do
    -- An account id of another team stays there: an officer settles that in the roster window
    if not index.ofOrigin[origin] then
      self.model:Link(data.accountKey(origin), id)
    end
  end
end

---Checks every character with a stored request.
function Clerk:Scan()
  if not self.sync:IsOfficer() then
    return
  end
  local names = {}
  for name in self.sync:Iterate(REQUEST_TABLE) do
    names[#names + 1] = name
  end
  -- The checks write to the table `team`, never to the one that was iterated
  for _, name in ipairs(names) do
    self:Check(name)
  end
end
