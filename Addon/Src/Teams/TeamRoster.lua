local addonName, ns = ...

-- The model of the officers' roster tab, without frames (.agents/user-wishes.md, "Roster view"): one row per
-- member of the guild roster, with the class, the online state, and the team.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_teams.lua).

---@class OOOOTeamRosterMember What the guild roster tells of a member
---@field online boolean
---@field class string|nil Class token in upper case: "SHAMAN"

---@class OOOOTeamRosterParts What the rows are built from
---@field roster table<string, OOOOTeamRosterMember> Character name -> member, as `ns.guildState.roster`
---@field model OOOOTeamsModel
---@field sync OOOOSync

---@class OOOOTeamRosterRow One line of the list
---@field name string Character name
---@field online boolean
---@field class string|nil Class token of the roster, or of the table `character`
---@field teamId string|nil
---@field alias string|nil The alias that chat shows for the character
---@field detected boolean true when the team comes from an account id, not from an assignment
---@field hasAddon boolean true when the character has a record in the table `character`

---@class OOOOTeamRoster
local roster = {}
ns.teamRoster = roster

---Lists the members of the guild roster: those online first, each group by name.
---@param parts OOOOTeamRosterParts
---@return OOOOTeamRosterRow[]
function roster.rows(parts)
  local rows = {} ---@type OOOOTeamRosterRow[]
  for name, member in pairs(parts.roster) do
    local character = parts.sync:Get(ns.syncCharacter.TABLE, name)
    local id, detected = parts.model:TeamOf(name)
    rows[#rows + 1] = {
      name = name,
      online = member.online == true,
      class = member.class or (type(character) == "table" and character.class) or nil,
      teamId = id,
      alias = id and parts.model:Alias(id) or nil,
      detected = detected,
      hasAddon = character ~= nil,
    }
  end
  table.sort(rows, function(left, right)
    if left.online ~= right.online then
      return left.online
    end
    return left.name < right.name
  end)
  return rows
end
