local addonName, ns = ...

-- The model of the teams feature, without frames (.agents/user-wishes.md, "Teams"; the tables are in
-- TeamData.lua). It reads the table `team` through an index that is built again after a change, and it holds
-- the operations of the officers and the alias request of a member.
--
-- A character is in a team in one of two ways:
-- - assigned: an officer wrote the record `c:<name>`;
-- - detected: the character has no such record, but the table `character` lists it under an account id that
--   a team holds (`o:<account id>`). A detected character shows the alias of the team; only an assigned one may
--   ask for another alias. The table `character` is written by the members themselves, so a detection is a
--   hint and never a proof.
--
-- An account id moves with its characters: `Move` takes the character and every character of the old team that
-- shares an account id with it, so that no account id ends in two teams.
--
-- Open, left so on purpose (2026-11-23): a team id is a fresh version id, so two officers who make a team for
-- the same character at the same moment leave one team without a character. It does no harm; a stable team id
-- would prevent it, and a cleanup of empty teams can remove what is left.
--
-- This file uses no WoW API at file scope, so the host tests load it (Tests/sync_teams.lua).

---@class OOOOTeamsParts What a model is built from
---@field sync OOOOSync
---@field playerName fun(): string|nil Name of the logged-in character

---@class OOOOTeamIndex The table `team` and the detections, read once
---@field teams table<string, OOOOTeam> Team id -> payload
---@field ofName table<string, string> Assigned character -> id of a team that exists
---@field ofOrigin table<string, string> Account id -> id of a team that exists
---@field detected table<string, string> Character without an assignment -> id of the team of its account id
---@field members table<string, string[]> Team id -> assigned characters, sorted
---@field detectedMembers table<string, string[]> Team id -> detected characters, sorted
---@field origins table<string, string[]> Team id -> account ids, sorted

---@class OOOOTeamDetail What a window shows of one team
---@field id string
---@field alias string The alias that chat shows
---@field officerAlias string
---@field playerAlias string|nil
---@field denied boolean true when the player's alias is denied
---@field members string[] Assigned characters, sorted
---@field detected string[] Detected characters, sorted
---@field origins string[] Account ids, sorted

---@class OOOOTeamsModule
---@field current OOOOTeamsModel|nil The model of the game, made by `Start`
local teams = {}
ns.teams = teams

local data = ns.teamData
local TABLE, REQUEST_TABLE = data.TABLE, data.REQUEST_TABLE

---@class OOOOTeamsModel
---@field sync OOOOSync
---@field playerName fun(): string|nil
---@field index OOOOTeamIndex|nil nil after a change, until the next read
local Model = {}
Model.__index = Model

---Makes a model and registers it for "OnRecordChanged" of the engine.
---@param parts OOOOTeamsParts
---@return OOOOTeamsModel
function teams.new(parts)
  local self = setmetatable({ sync = parts.sync, playerName = parts.playerName }, Model)
  self.sync.RegisterCallback(self, "OnRecordChanged", function(_event, tableName)
    if tableName == TABLE or tableName == ns.syncCharacter.TABLE then
      self.index = nil
    end
  end)
  return self
end

---Builds the model of the game as `teams.current`, replacing an earlier one. Called after login, never at file
---scope.
---@return OOOOTeamsModel
function teams.Start()
  if teams.current then
    teams.current:Stop()
  end
  teams.current = teams.new({ sync = ns.sync, playerName = ns.syncCharacter.playerName })
  return teams.current
end

---Unregisters the model.
function Model:Stop()
  self.sync.UnregisterCallback(self, "OnRecordChanged")
  self.index = nil
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

---Returns the account ids of a character, from the table `character`.
---@param name string
---@return string[] origins Sorted; empty for a character without the addon
function Model:OriginsOf(name)
  local tbl = self.sync:GetTable(ns.syncCharacter.TABLE)
  return tbl and ns.syncCharacter.origins(tbl, name) or {}
end

---Adds a value to the list of a team in a map of lists.
---@param map table<string, string[]>
---@param id string
---@param value string
local function addTo(map, id, value)
  local list = map[id]
  if not list then
    list = {}
    map[id] = list
  end
  list[#list + 1] = value
end

---Returns the index of the table `team`, building it when a record has changed since the last read. A link to
---a team that does not exist (a team whose record was lost) counts as no link.
---@return OOOOTeamIndex
function Model:Index()
  if self.index then
    return self.index
  end
  ---@type OOOOTeamIndex
  local index = { teams = {}, ofName = {}, ofOrigin = {}, detected = {}, members = {}, detectedMembers = {},
    origins = {} }
  local names, origins = {}, {}
  for key, payload in self.sync:Iterate(TABLE) do
    local parts = data.parseKey(key)
    if parts and type(payload) == "table" then
      if parts.kind == "team" then
        index.teams[parts.id] = payload
      elseif parts.kind == "character" then
        names[parts.name] = payload.t
      else
        origins[parts.origin] = payload.t
      end
    end
  end
  for id in pairs(index.teams) do
    index.members[id], index.detectedMembers[id], index.origins[id] = {}, {}, {}
  end
  for name, id in pairs(names) do
    if index.teams[id] then
      index.ofName[name] = id
      addTo(index.members, id, name)
    end
  end
  for origin, id in pairs(origins) do
    if index.teams[id] then
      index.ofOrigin[origin] = id
      addTo(index.origins, id, origin)
    end
  end
  local characters = self.sync:GetTable(ns.syncCharacter.TABLE)
  if characters and next(index.ofOrigin) ~= nil then
    for name, record in pairs(characters.records) do
      if not record.x and not index.ofName[name] then
        -- The list is sorted, so every replica picks the same team for a character with two account ids
        for _, origin in ipairs(ns.syncCharacter.origins(characters, name)) do
          local id = index.ofOrigin[origin]
          if id then
            index.detected[name] = id
            addTo(index.detectedMembers, id, name)
            break
          end
        end
      end
    end
  end
  for id in pairs(index.teams) do
    table.sort(index.members[id])
    table.sort(index.detectedMembers[id])
    table.sort(index.origins[id])
  end
  self.index = index
  return index
end

---Returns the team of a character.
---@param name string Character name
---@return string|nil id nil for a character without a team
---@return boolean detected true when the character is not assigned and the team comes from its account id
function Model:TeamOf(name)
  local index = self:Index()
  local id = index.ofName[name]
  if id then
    return id, false
  end
  id = index.detected[name]
  return id, id ~= nil
end

---Returns the alias that chat shows for a team: the alias of the player, or the alias of the officer when the
---player has none or is denied one.
---@param id string Team id
---@return string|nil alias nil for a team that does not exist
function Model:Alias(id)
  local team = self:Index().teams[id]
  if not team then
    return nil
  end
  if team.f ~= true and team.p ~= nil then
    return team.p
  end
  return team.a
end

---Returns the alias that chat shows for a character.
---@param name string Character name
---@return string|nil alias nil for a character without a team
function Model:AliasOf(name)
  local id = self:TeamOf(name)
  return id and self:Alias(id) or nil
end

---Returns what a window shows of a team. The lists are those of the index: do not change them.
---@param id string Team id
---@return OOOOTeamDetail|nil detail nil for a team that does not exist
function Model:Detail(id)
  local index = self:Index()
  local team = index.teams[id]
  if not team then
    return nil
  end
  return {
    id = id,
    alias = self:Alias(id),
    officerAlias = team.a,
    playerAlias = team.p,
    denied = team.f == true,
    members = index.members[id],
    detected = index.detectedMembers[id],
    origins = index.origins[id],
  }
end

--------------------------------------------------------------------------------
-- Writing: officers
--------------------------------------------------------------------------------

---Copies the payload of a team, so that a change does not touch the stored record.
---@param team OOOOTeam
---@return OOOOTeam
local function copyTeam(team)
  return { a = team.a, p = team.p, pv = team.pv, f = team.f }
end

---Writes the link of a character or of an account id to a team.
---@param key string
---@param id string Team id
---@return boolean ok
---@return string|nil reason
function Model:Link(key, id)
  local written, reason = self.sync:Put(TABLE, key, { t = id })
  return written ~= nil, reason
end

---Tells why the logged-in character may not change the teams.
---@return string|nil reason nil for an officer; "not an officer"
function Model:Refusal()
  return (not self.sync:IsOfficer()) and "not an officer" or nil
end

---Tells why a character without a team cannot join a team: an account id of the character belongs to
---another team, whose characters are the same person by the table `character`.
---@param index OOOOTeamIndex
---@param name string
---@param id string|nil The team to join; nil for a new team
---@return string|nil reason "account in another team"
---@return string|nil otherId The team that holds the account id
function Model:AccountConflict(index, name, id)
  for _, origin in ipairs(self:OriginsOf(name)) do
    local other = index.ofOrigin[origin]
    if other and other ~= id then
      return "account in another team", other
    end
  end
  return nil
end

---Assigns a character without a team to a team, with its account ids.
---@param id string Team id
---@param name string Character name
---@return boolean ok true also when the character is in the team already
---@return string|nil reason "not an officer", "no team", "bad name", "in a team", or "account in another team"
---@return string|nil otherId With "account in another team": that team
function Model:Add(id, name)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local index = self:Index()
  if not index.teams[id] then
    return false, "no team"
  elseif not data.isName(name) then
    return false, "bad name"
  elseif index.ofName[name] == id then
    return true
  elseif index.ofName[name] then
    return false, "in a team"
  end
  local conflict, otherId = self:AccountConflict(index, name, id)
  if conflict then
    return false, conflict, otherId
  end
  local origins = self:OriginsOf(name)
  local ok, reason = self:Link(data.characterKey(name), id)
  if not ok then
    return false, reason
  end
  for _, origin in ipairs(origins) do
    self:Link(data.accountKey(origin), id)
  end
  return true
end

---Makes a team with an alias and assigns characters without a team to it.
---@param aliasText string Alias of the officer, as typed
---@param names string[] At least one character
---@return string|nil id The id of the new team; nil when nothing was written
---@return string|nil reason "not an officer", "empty", "too long", "bad character", "bad name", "in a team",
---"account in another team", or a refusal of the engine
function Model:Create(aliasText, names)
  local refusal = self:Refusal()
  if refusal then
    return nil, refusal
  end
  local alias, aliasReason = data.cleanAlias(aliasText)
  if not alias then
    return nil, aliasReason
  end
  local index = self:Index()
  if #names == 0 then
    return nil, "bad name"
  end
  for _, name in ipairs(names) do
    if not data.isName(name) then
      return nil, "bad name"
    elseif index.ofName[name] then
      return nil, "in a team"
    end
    local conflict = self:AccountConflict(index, name, nil)
    if conflict then
      return nil, conflict
    end
  end
  local id = self.sync:NewId(TABLE)
  if not id then
    return nil, "not ready"
  end
  local written, reason = self.sync:Put(TABLE, data.teamKey(id), { a = alias })
  if written == nil then
    return nil, reason
  end
  for _, name in ipairs(names) do
    self:Add(id, name)
  end
  return id
end

---Deletes the record of a team and the links of its account ids, once it has no assigned character.
---@param id string Team id
function Model:DeleteIfEmpty(id)
  local index = self:Index()
  if not index.teams[id] or #index.members[id] > 0 then
    return
  end
  local origins = index.origins[id]
  for _, origin in ipairs(origins) do
    self.sync:Delete(TABLE, data.accountKey(origin))
  end
  self.sync:Delete(TABLE, data.teamKey(id))
end

---Lists the characters of a team that are the same account as a character: those that share an account id
---with it, directly or through other characters of the team.
---@param index OOOOTeamIndex
---@param id string Team id
---@param name string A character of the team
---@return string[] group The character itself first
---@return table<string, boolean> origins The account ids of the group
function Model:AccountGroup(index, id, name)
  local originsOf = {}
  for _, member in ipairs(index.members[id] or {}) do
    originsOf[member] = self:OriginsOf(member)
  end
  local group, inGroup, origins = { name }, { [name] = true }, {}
  local position = 1
  while position <= #group do
    for _, origin in ipairs(originsOf[group[position]] or {}) do
      origins[origin] = true
    end
    for member, list in pairs(originsOf) do
      if not inGroup[member] then
        for _, origin in ipairs(list) do
          if origins[origin] then
            inGroup[member] = true
            group[#group + 1] = member
            break
          end
        end
      end
    end
    position = position + 1
  end
  return group, origins
end

---Moves a character into another team. The characters of its old team that share an account id with it move
---too, with those account ids, so that no account id is in two teams. An old team that is left without a
---character is deleted. A character without a team is added.
---@param name string Character name
---@param id string Id of the team to move into
---@return boolean ok
---@return string|nil reason "not an officer", "no team", "account in another team", or a refusal of `Add`
---@return string[]|nil moved The characters that moved, `name` first
function Model:Move(name, id)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local index = self:Index()
  local old = index.ofName[name]
  if not index.teams[id] then
    return false, "no team"
  elseif old == id then
    return true, nil, {}
  elseif not old then
    local ok, reason = self:Add(id, name)
    return ok, reason, ok and { name } or nil
  end
  local group, origins = self:AccountGroup(index, old, name)
  for origin in pairs(origins) do
    local holder = index.ofOrigin[origin]
    if holder and holder ~= old and holder ~= id then
      return false, "account in another team"
    end
  end
  for _, member in ipairs(group) do
    local ok, reason = self:Link(data.characterKey(member), id)
    if not ok then
      return false, reason
    end
  end
  for origin in pairs(origins) do
    self:Link(data.accountKey(origin), id)
  end
  self:DeleteIfEmpty(old)
  return true, nil, group
end

---Merges a team into another one: its characters and account ids move, and its record is deleted. The alias
---of the other team stays.
---@param fromId string The team that ends
---@param intoId string The team that takes its characters
---@return boolean ok
---@return string|nil reason "not an officer", "no team", or "same team"
function Model:Merge(fromId, intoId)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local index = self:Index()
  if not index.teams[fromId] or not index.teams[intoId] then
    return false, "no team"
  elseif fromId == intoId then
    return false, "same team"
  end
  -- The lists belong to the index, which the first write replaces
  local members, origins = index.members[fromId], index.origins[fromId]
  for _, member in ipairs(members) do
    local ok, reason = self:Link(data.characterKey(member), intoId)
    if not ok then
      return false, reason
    end
  end
  for _, origin in ipairs(origins) do
    self:Link(data.accountKey(origin), intoId)
  end
  self.sync:Delete(TABLE, data.teamKey(fromId))
  return true
end

---Takes a character out of its team. An account id of the character that no other character of the team has
---leaves the team too. A team that is left without a character is deleted.
---@param name string Character name
---@return boolean ok
---@return string|nil reason "not an officer" or "no team"
function Model:Remove(name)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local index = self:Index()
  local id = index.ofName[name]
  if not id then
    return false, "no team"
  end
  local kept = {}
  for _, member in ipairs(index.members[id]) do
    if member ~= name then
      for _, origin in ipairs(self:OriginsOf(member)) do
        kept[origin] = true
      end
    end
  end
  local own = self:OriginsOf(name)
  self.sync:Delete(TABLE, data.characterKey(name))
  for _, origin in ipairs(own) do
    if not kept[origin] and index.ofOrigin[origin] == id then
      self.sync:Delete(TABLE, data.accountKey(origin))
    end
  end
  self:DeleteIfEmpty(id)
  return true
end

---Deletes a team with the links of its characters and account ids.
---@param id string Team id
---@return boolean ok
---@return string|nil reason "not an officer" or "no team"
function Model:Disband(id)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local index = self:Index()
  if not index.teams[id] then
    return false, "no team"
  end
  local members, origins = index.members[id], index.origins[id]
  for _, member in ipairs(members) do
    self.sync:Delete(TABLE, data.characterKey(member))
  end
  for _, origin in ipairs(origins) do
    self.sync:Delete(TABLE, data.accountKey(origin))
  end
  self.sync:Delete(TABLE, data.teamKey(id))
  return true
end

---Writes a changed copy of the record of a team.
---@param id string Team id
---@param change fun(team: OOOOTeam)
---@return boolean ok
---@return string|nil reason "not an officer", "no team", or a refusal of the engine
function Model:Change(id, change)
  local refusal = self:Refusal()
  if refusal then
    return false, refusal
  end
  local team = self:Index().teams[id]
  if not team then
    return false, "no team"
  end
  local changed = copyTeam(team)
  change(changed)
  local written, reason = self.sync:Put(TABLE, data.teamKey(id), changed)
  return written ~= nil, reason
end

---Sets the alias that an officer gives a team.
---@param id string Team id
---@param aliasText string As typed
---@return boolean ok
---@return string|nil reason "empty", "too long", "bad character", or a refusal of `Change`
function Model:SetOfficerAlias(id, aliasText)
  local alias, reason = data.cleanAlias(aliasText)
  if not alias then
    return false, reason
  end
  return self:Change(id, function(team)
    team.a = alias
  end)
end

---Denies or allows the alias of the player. While it is denied, chat shows the alias of the officer.
---@param id string Team id
---@param denied boolean
---@return boolean ok
---@return string|nil reason A refusal of `Change`
function Model:SetDenied(id, denied)
  return self:Change(id, function(team)
    team.f = denied and true or nil
  end)
end

---Copies the alias request of a character into the record of its team, when the request is newer than the
---one that the team holds. The clerk of an officer calls it (TeamClerk.lua).
---@param name string An assigned character with a request
---@return boolean written false when there was nothing to do
function Model:ApplyRequest(name)
  if self:Refusal() then
    return false
  end
  local request = self.sync:Get(REQUEST_TABLE, name)
  local requestId = self.sync:GetId(REQUEST_TABLE, name)
  local id = self:Index().ofName[name]
  local team = id and self.index.teams[id]
  if type(request) ~= "table" or not data.isAlias(request.a) or not requestId or not team then
    return false
  end
  -- Ids compare by time with `<`, so the newest request of the characters of a team wins
  if team.pv ~= nil and team.pv >= requestId then
    return false
  end
  return (self:Change(id, function(changed)
    changed.p, changed.pv = request.a, requestId
  end))
end

--------------------------------------------------------------------------------
-- Writing: members
--------------------------------------------------------------------------------

---Asks for an alias of the team of the logged-in character. The request is a record of the character in the
---table `team_alias`; an officer's addon copies it into the team.
---@param aliasText string As typed
---@return boolean ok
---@return string|nil reason "not ready" (the name of the character is unknown), "no team" (no officer has
---assigned the character), "empty", "too long", "bad character", or a refusal of the engine
function Model:SubmitAlias(aliasText)
  local name = self.playerName()
  if not name then
    return false, "not ready"
  end
  if not self:Index().ofName[name] then
    return false, "no team"
  end
  local alias, reason = data.cleanAlias(aliasText)
  if not alias then
    return false, reason
  end
  local written, putReason = self.sync:Put(REQUEST_TABLE, name, { a = alias })
  return written ~= nil, putReason
end

---Returns the alias that the logged-in character last asked for.
---@return string|nil
function Model:OwnRequest()
  local name = self.playerName()
  local request = name and self.sync:Get(REQUEST_TABLE, name)
  return type(request) == "table" and request.a or nil
end
