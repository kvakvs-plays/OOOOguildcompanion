local addonName, ns = ...

-- The facts of a recipe, read from the own client (.agents/00-plan.md, section 5.4, "No table `recipe`"):
-- the shared database carries only recipe ids, and every replica asks its client for the name, the item, and
-- the reagents. The client answers also for recipes of professions that the character lacks.
--
-- The client is behind `recipes.client`, so the host tests replace it (Tests/sync_profnames.lua).

---@class OOOORecipeReagent
---@field itemId integer
---@field count integer How many the recipe needs

---@class OOOORecipeFacts What the client knows about one recipe
---@field id integer Recipe id: the id of the craft spell
---@field name string|nil Name of the recipe in the language of the client
---@field icon any Texture of the recipe, as the client gives it (a file id)
---@field itemId integer|nil The item that the recipe makes; nil for an enchant
---@field count integer How many items one craft makes at least
---@field reagents OOOORecipeReagent[]

---@class OOOORecipeClient The two questions to the client; a host test replaces them
---@field info fun(recipeId: integer): any `C_TradeSkillUI.GetRecipeInfo`
---@field schematic fun(recipeId: integer): any `C_TradeSkillUI.GetRecipeSchematic(recipeId, false)`

---@class OOOOProfessionRecipes
---@field client OOOORecipeClient
---@field cache table<integer, OOOORecipeFacts|false> Recipe id -> facts of this session; false: no recipe
---@field professionNames table<integer, string> Skill line id -> name, as the client gave it
local recipes = { cache = {}, professionNames = {} }
ns.professionRecipes = recipes

---Returns the name of a profession in the language of the client.
---@param professionId integer|nil Skill line id
---@return string name `#<id>` when the client gives no name; empty without an id
function recipes.ProfessionName(professionId)
  if not professionId then
    return ""
  end
  local known = recipes.professionNames[professionId]
  if known then
    return known
  end
  local name = C_TradeSkillUI.GetTradeSkillDisplayName(professionId)
  if issecretvalue(name) or type(name) ~= "string" or name == "" then
    return "#" .. professionId
  end
  recipes.professionNames[professionId] = name
  return name
end

---The client of the game. The id can come from a record of another member, so a call that raises on a
---strange id counts as no answer.
recipes.client = {
  info = function(recipeId)
    local succeeded, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeId)
    return succeeded and info or nil
  end,
  schematic = function(recipeId)
    local succeeded, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeId, false)
    return succeeded and schematic or nil
  end,
}

---A plain positive integer, or nil. A secret value must be told apart before this is called.
---@param value any
---@return integer|nil
local function positiveInteger(value)
  if type(value) == "number" and value >= 1 and value == math.floor(value) then
    return value
  end
  return nil
end

---Tells whether one of the values is secret.
---@param ... any
---@return boolean
local function anySecret(...)
  for index = 1, select("#", ...) do
    if issecretvalue((select(index, ...))) then
      return true
    end
  end
  return false
end

---Reads the reagents out of a recipe schematic.
---@param schematic table
---@return OOOORecipeReagent[]|nil reagents nil when a value was secret
local function readReagents(schematic)
  local reagents = {}
  local slots = schematic.reagentSlotSchematics
  if issecretvalue(slots) then
    return nil
  end
  if type(slots) ~= "table" then
    return reagents
  end
  for _, slot in ipairs(slots) do
    if issecretvalue(slot) then
      return nil
    end
    if type(slot) == "table" then
      local options, required = slot.reagents, slot.quantityRequired
      if anySecret(options, required) then
        return nil
      end
      local first = type(options) == "table" and options[1] or nil
      if issecretvalue(first) then
        return nil
      end
      local itemId = type(first) == "table" and first.itemID or nil
      if issecretvalue(itemId) then
        return nil
      end
      if positiveInteger(itemId) and positiveInteger(required) then
        reagents[#reagents + 1] = { itemId = itemId, count = required }
      end
    end
  end
  return reagents
end

---Returns what the client knows about a recipe. The answer is kept for the session.
---@param recipeId integer Recipe id, also one from a record of another member
---@return OOOORecipeFacts|nil facts nil when the client says that the id is no recipe, and when a value was
---secret (that answer is not kept). Do not change the table.
function recipes.Facts(recipeId)
  local cached = recipes.cache[recipeId]
  if cached ~= nil then
    return cached or nil
  end
  local info = recipes.client.info(recipeId)
  if issecretvalue(info) then
    return nil
  end
  if type(info) ~= "table" then
    recipes.cache[recipeId] = false
    return nil
  end
  if anySecret(info.recipeID, info.name, info.icon) then
    return nil
  end
  -- For an id that is no recipe the client gives a table with the recipe id 0 and an empty name
  if info.recipeID ~= recipeId then
    recipes.cache[recipeId] = false
    return nil
  end
  ---@type OOOORecipeFacts
  local facts = {
    id = recipeId,
    name = (type(info.name) == "string" and info.name ~= "") and info.name or nil,
    icon = info.icon,
    count = 1,
    reagents = {},
  }
  local schematic = recipes.client.schematic(recipeId)
  if issecretvalue(schematic) then
    return nil
  end
  if type(schematic) == "table" then
    if anySecret(schematic.outputItemID, schematic.quantityMin) then
      return nil
    end
    local reagents = readReagents(schematic)
    if not reagents then
      return nil
    end
    facts.itemId = positiveInteger(schematic.outputItemID)
    facts.count = positiveInteger(schematic.quantityMin) or 1
    facts.reagents = reagents
  end
  recipes.cache[recipeId] = facts
  return facts
end
