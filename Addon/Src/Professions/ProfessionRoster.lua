local addonName, ns = ...

-- The model of the tab "Members": the members who share their professions, each with the professions and
-- skill levels of the table `profession`. It has no frames; the tab is Professions/ProfessionRosterTab.lua.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_profroster.lua).

---@class OOOOProfessionRosterEntry One profession of a member
---@field id integer Skill line id
---@field level integer Skill level
---@field max integer Highest level of the learned rank
---@field recipes integer How many recipes the member has shared

---@class OOOOProfessionRosterRow One member
---@field name string Character name
---@field online boolean
---@field class string|nil Class token of the table `character`: "SHAMAN"; nil when the member has no record
---@field professions OOOOProfessionRosterEntry[] Highest level first
---@field level integer|nil With a filter: the level of the member in that profession

---@class OOOOProfessionRosterParts What the rows are built from
---@field sync OOOOSync
---@field isOnline fun(name: string): boolean Whether the roster shows a member online

---@class OOOOProfessionRoster
local roster = {}
ns.professionRoster = roster

local data = ns.professionData

---Name of the table with the class of a character (Sync/SyncCharacter.lua)
local CHARACTER_TABLE = "character"

---Lists the members who have a record in the table `profession`.
---@param parts OOOOProfessionRosterParts
---@param professionId integer|nil Only the members with this profession, the highest level first; nil lists
---all members, online ones first
---@return OOOOProfessionRosterRow[] rows
---@return integer[] professionIds The professions that at least one member has, in ascending order,
---whatever the filter is
function roster.rows(parts, professionId)
  local sync = parts.sync
  local byName, seen, professionIds = {}, {}, {}
  for key, payload in sync:Iterate(data.TABLE) do
    local name, id = data.parseKey(key)
    if name and id and type(payload) == "table" then
      local row = byName[name]
      if not row then
        local character = sync:Get(CHARACTER_TABLE, name)
        row = {
          name = name,
          online = parts.isOnline(name) == true,
          class = type(character) == "table" and type(character.class) == "string" and character.class or nil,
          professions = {},
        }
        byName[name] = row
      end
      row.professions[#row.professions + 1] = { id = id, level = payload.l, max = payload.m,
        recipes = data.recipeCount(payload.r) }
      if id == professionId then
        row.level = payload.l
      end
      if not seen[id] then
        seen[id] = true
        professionIds[#professionIds + 1] = id
      end
    end
  end
  table.sort(professionIds)

  local rows = {}
  for _, row in pairs(byName) do
    if not professionId or row.level then
      table.sort(row.professions, function(left, right)
        if left.level ~= right.level then
          return left.level > right.level
        end
        return left.id < right.id
      end)
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(left, right)
    if professionId and left.level ~= right.level then
      return left.level > right.level
    end
    if left.online ~= right.online then
      return left.online
    end
    return left.name < right.name
  end)
  return rows, professionIds
end
