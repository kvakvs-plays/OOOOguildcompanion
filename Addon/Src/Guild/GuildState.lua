local addonName, ns = ...

-- The one place that knows the guild: whether the character is in `OO OO`, and who the members are
-- (.agents/00-plan.md, step 4.1). Other modules ask this one and listen to its callbacks.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file with stubbed roster functions
-- (Tests/sync_guildstate.lua). It needs LibStub and CallbackHandler-1.0.

---@class OOOOGuildMember One member in the roster cache
---@field online boolean
---@field rankIndex integer Rank index of the roster API, from 0 (guild master)

---@alias OOOOGuildStateName
---| "unknown" # The client has not told the guild name yet
---| "in" # The character is in `OO OO`
---| "outside" # The character is in no guild or in another one

---@class OOOOGuildState
---@field state OOOOGuildStateName
---@field roster table<string, OOOOGuildMember> Character name (`First Last`) -> member
---@field rosterCount integer Number of members in `roster`
---@field rosterComplete boolean true when the last roster read gave an entry for every member, offline ones too
---@field frame table|nil The event frame; nil until `Start`
---@field handlers table<string, fun(...: any)> Event name -> handler
---@field callbacks table CallbackHandler registry; fires "OnGuildStateChanged" and "OnRosterChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)
---@field UnregisterAllCallbacks fun(owner: any)
local guildState = { state = "unknown", roster = {}, rosterCount = 0, rosterComplete = false }
ns.guildState = guildState

---Name of the guild that the addon is for, as `GetGuildInfo` gives it
guildState.GUILD_NAME = "OO OO"

---Rank indexes of the officers: in `OO OO` the ranks `O` (guild master) and `Ministry of War`. Only an officer
---writes a table with `writers = "officer"`, and only an officer is a source of a protected table
---(.agents/00-plan.md, section 14.2). A constant, not a setting.
---@type table<integer, boolean>
ns.OFFICER_RANKS = { [0] = true, [1] = true }

---Shortest time in seconds between two roster requests that `NoteOnline` makes; the server throttles them
local REFRESH_INTERVAL = 15

---Events for other modules, in the CallbackHandler form:
---`ns.guildState.RegisterCallback(owner, "OnGuildStateChanged", function(event, inGuild, state) end)` fires
---when the state changes; `inGuild` is true only for the state "in".
---`ns.guildState.RegisterCallback(owner, "OnRosterChanged", function(event) end)` fires when a member
---joined, left, went online or offline, or changed rank.
guildState.callbacks = LibStub("CallbackHandler-1.0"):New(guildState)

---true once the roster was requested for the current stay in the guild
local rosterRequested = false
---Clock time (`GetTime`) of the last roster request made by `NoteOnline`
local lastRefresh ---@type number|nil

---Cuts a realm suffix off a character name. Forever gives none (AGENTS.md); one is cut off in case that
---changes. A name has a space between the first and the last name and is never split there.
---@param sender any Name as a roster entry or a message sender gives it
---@return string|nil name nil when the name is secret, not a string, or empty
function guildState.normalizeName(sender)
  if issecretvalue(sender) or type(sender) ~= "string" then
    return nil
  end
  return sender:match("^[^-]+")
end

---Tells whether the character is known to be in the guild.
---@return boolean
function guildState:IsInGuild()
  return self.state == "in"
end

---Returns the roster entry of a member. The table is the cached one: do not change it.
---@param name string Character name without a realm suffix
---@return OOOOGuildMember|nil member nil when the name is not in the roster cache
function guildState:GetMember(name)
  return self.roster[name]
end

---Tells whether the roster cache shows a member online.
---@param name string
---@return boolean
function guildState:IsOnline(name)
  local member = self.roster[name]
  return member ~= nil and member.online
end

---Tells whether the roster cache shows a character with an officer rank (`ns.OFFICER_RANKS`). The rank
---belongs to the character, not to the player: an alt of an officer with a member rank is no officer.
---@param name string|nil Character name without a realm suffix
---@return boolean officer false for a name that the cache lacks
function guildState:IsOfficer(name)
  local member = name ~= nil and self.roster[name] or nil
  return member ~= nil and ns.OFFICER_RANKS[member.rankIndex] == true
end

---Tells whether the roster cache lists every member of the guild: the character is in the guild, the
---last read left no entry out, and the client was not hiding offline members. Only then does a name that is missing mean a member who left; the cleanup
---of the shared database asks this before it removes records (SyncCleanup.lua).
---@return boolean
function guildState:IsRosterComplete()
  return self.state == "in" and self.rosterComplete and self.rosterCount > 0
end

---Asks the server for the roster; the answer arrives as GUILD_ROSTER_UPDATE.
local function requestRoster()
  C_GuildInfo.GuildRoster()
end

---Reads the guild name from the client and fires "OnGuildStateChanged" when the state has changed.
---The name is nil for some seconds after login: that is "unknown", and the next guild event asks again.
function guildState:Update()
  local state ---@type OOOOGuildStateName
  if not IsInGuild() then
    state = "outside"
  else
    local guildName = GetGuildInfo("player")
    if guildName == nil or issecretvalue(guildName) then
      state = "unknown"
    else
      state = guildName == self.GUILD_NAME and "in" or "outside"
    end
  end
  if state == self.state then
    return
  end
  self.state = state
  if state == "in" then
    if not rosterRequested then
      rosterRequested = true
      requestRoster()
    end
  else
    rosterRequested = false
    if state == "outside" and self.rosterCount > 0 then
      self.roster, self.rosterCount, self.rosterComplete = {}, 0, false
      self.callbacks:Fire("OnRosterChanged")
    end
  end
  self.callbacks:Fire("OnGuildStateChanged", state == "in", state)
end

---Reads the roster from the client into the cache and fires "OnRosterChanged" when a member joined, left,
---went online or offline, or changed rank. An entry that is secret or malformed is left out.
function guildState:ReadRoster()
  if self.state ~= "in" then
    return
  end
  local total = GetNumGuildMembers()
  if issecretvalue(total) or type(total) ~= "number" then
    return
  end
  local old, roster, count, changed = self.roster, {}, 0, false
  for index = 1, total do
    -- The 9th value tells whether the member is online
    local rawName, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(index)
    local name = guildState.normalizeName(rawName)
    if name and not issecretvalue(rankIndex) and type(rankIndex) == "number" and not issecretvalue(online)
      and not roster[name] then
      local isOnline = online == true
      local member = old[name]
      if not member or member.online ~= isOnline or member.rankIndex ~= rankIndex then
        member = { online = isOnline, rankIndex = rankIndex }
        changed = true
      end
      roster[name] = member
      count = count + 1
    end
  end
  local wasComplete = self.rosterComplete
  -- Another addon can hide offline members with SetGuildRosterShowOffline(false). Whether the member count
  -- then leaves them out was not seen in the client (plan step 8.2), so such a read never counts as complete:
  -- the cleanup would take a hidden member for one who left.
  local showsOffline = GetGuildRosterShowOffline()
  local listsOffline = not issecretvalue(showsOffline) and showsOffline == true
  -- An entry that was left out (secret, malformed, or a repeated name) makes the cache incomplete
  self.roster, self.rosterCount, self.rosterComplete = roster, count, count == total and listsOffline
  if self.rosterComplete ~= wasComplete then
    changed = true
  end
  -- The loop sees a member who joined or changed; one who left is only missing
  if changed or self:HasLeaver(old) then
    self.callbacks:Fire("OnRosterChanged")
  end
end

---Tells whether a name of an older roster is missing in the current one.
---@param old table<string, OOOOGuildMember>
---@return boolean
function guildState:HasLeaver(old)
  for name in pairs(old) do
    if not self.roster[name] then
      return true
    end
  end
  return false
end

---Records that a member is online, on the evidence of a message from that member, when the roster cache
---still shows the member offline: the cache changes only with a roster update, which can come late.
---It also asks the server for a fresh roster, at most once in `REFRESH_INTERVAL` seconds.
---@param name string Character name without a realm suffix
function guildState:NoteOnline(name)
  local member = self.roster[name]
  if not member or member.online then
    return
  end
  self.roster[name] = { online = true, rankIndex = member.rankIndex }
  self.callbacks:Fire("OnRosterChanged")
  local now = GetTime()
  if not lastRefresh or now - lastRefresh >= REFRESH_INTERVAL then
    lastRefresh = now
    requestRoster()
  end
end

---Event name -> handler. The arguments are those of the event.
---@type table<string, fun(...: any)>
local handlers = {
  PLAYER_GUILD_UPDATE = function(unit)
    if unit == nil or (not issecretvalue(unit) and unit == "player") then
      guildState:Update()
    end
  end,
  GUILD_ROSTER_UPDATE = function()
    guildState:Update()
    guildState:ReadRoster()
  end,
}
guildState.handlers = handlers

---Starts listening to the guild events and reads the state once. Core.lua calls it on PLAYER_LOGIN, after
---the other modules have registered their callbacks.
function guildState:Start()
  if self.frame then
    return
  end
  local frame = CreateFrame("Frame")
  self.frame = frame
  frame:SetScript("OnEvent", function(_frame, event, ...)
    handlers[event](...)
  end)
  for event in pairs(handlers) do
    frame:RegisterEvent(event)
  end
  self:Update()
end
