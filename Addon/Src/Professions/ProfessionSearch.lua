local addonName, ns = ...

-- The model of the window "Guild professions", without frames (.agents/00-plan.md, section 5.4 and step
-- 12.6): the index `recipe id -> members who know it` over the table `profession`, the search by recipe name
-- and by material, and the detail of one recipe.
--
-- The shared table holds only ids. The names come from the own client, in its language: the recipe names
-- through `ns.professionRecipes`, the item names through `ns.professionNames`. Both are parts of a model, so
-- the host tests replace them (Tests/sync_profsearch.lua).

---@class OOOOProfessionSearchParts What a search model is built from
---@field sync OOOOSync
---@field facts fun(recipeId: integer): OOOORecipeFacts|nil `ns.professionRecipes.Facts`
---@field names { Name: (fun(self: any, itemId: integer): string|nil), Prepare: fun(self: any, itemIds: integer[]) }
---The name loader
---@field isOnline fun(name: string): boolean Whether the roster shows a member online

---@class OOOOProfessionRow One row of the result list
---@field id integer Recipe id
---@field name string Name of the recipe
---@field icon any Texture of the recipe
---@field itemId integer|nil The item that the recipe makes
---@field professionId integer Skill line id
---@field crafters string[] Names of the members who know the recipe, online first
---@field online integer How many of them are online

---@class OOOOProfessionCrafter One member who knows a recipe
---@field name string
---@field online boolean
---@field level integer Skill level
---@field max integer

---@class OOOOProfessionDetail What the detail part shows for one recipe
---@field id integer Recipe id
---@field name string Name of the recipe, or `#<id>` when the client does not know the id
---@field icon any
---@field itemId integer|nil
---@field count integer How many items one craft makes
---@field professionId integer|nil
---@field reagents { itemId: integer, count: integer, name: string|nil }[]
---@field crafters OOOOProfessionCrafter[] Online first, then by name

---@class OOOOProfessionSearchModule
local search = {}
ns.professionSearch = search

local data = ns.professionData
local TABLE = data.TABLE

---Most rows that a search gives
search.MAX_ROWS = 200
---Fewest characters of a search text
search.MIN_LENGTH = 2
---Recipes whose facts one frame reads when the item names are prepared
search.CHUNK = 50

---Lower case of a text. `string.lower` of the client handles UTF-8 (plan step 12.1); on the host it changes
---only ASCII. This is the one place to change when a client proves otherwise.
---@param text string
---@return string
local function lower(text)
  return string.lower(text)
end

---Turns the text of a search box into the text that is looked for: trimmed and in lower case.
---@param text any
---@return string|nil needle nil for a text of fewer than `MIN_LENGTH` characters, which is not searched
function search.needle(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  -- Characters, not bytes: the continuation bytes of UTF-8 are not counted
  local _, length = trimmed:gsub("[^\128-\191]", "")
  if length < search.MIN_LENGTH then
    return nil
  end
  return lower(trimmed)
end

---@class OOOOProfessionSearch
---@field sync OOOOSync
---@field facts fun(recipeId: integer): OOOORecipeFacts|nil
---@field names { Name: (fun(self: any, itemId: integer): string|nil), Prepare: fun(self: any, itemIds: integer[]) }
---@field isOnline fun(name: string): boolean
---@field crafters table<integer, table<string, boolean>>|nil Recipe id -> set of record keys; nil while closed
---@field keyRecipes table<string, integer[]> Record key -> the recipe ids that it has in the index
---@field recipeLower table<integer, string|false> Recipe id -> name in lower case; false: no known recipe
---@field itemLower table<integer, string> Item id -> name in lower case, once the name is there
---@field onChanged (fun())|nil Called when a record of the table changed while the model is open
local Model = {}
Model.__index = Model

---Makes a search model. It holds no index until `Open`.
---@param parts OOOOProfessionSearchParts
---@return OOOOProfessionSearch
function search.new(parts)
  return setmetatable({
    sync = parts.sync,
    facts = parts.facts,
    names = parts.names,
    isOnline = parts.isOnline,
    keyRecipes = {},
    recipeLower = {},
    itemLower = {},
  }, Model)
end

---Puts the recipes of one record into the index, in place of those that the key had before.
---@param key string
---@param payload any The payload of the record; nil when the record is gone
function Model:SetRecord(key, payload)
  local crafters = self.crafters
  if not crafters then
    return
  end
  for _, recipeId in ipairs(self.keyRecipes[key] or {}) do
    local keys = crafters[recipeId]
    if keys then
      keys[key] = nil
      if next(keys) == nil then
        crafters[recipeId] = nil
      end
    end
  end
  self.keyRecipes[key] = nil
  if type(payload) ~= "table" or not data.parseKey(key) then
    return
  end
  local ids = data.unpackRecipes(payload.r)
  if #ids == 0 then
    return
  end
  self.keyRecipes[key] = ids
  for _, recipeId in ipairs(ids) do
    crafters[recipeId] = crafters[recipeId] or {}
    crafters[recipeId][key] = true
  end
end

---Builds the index from the table `profession` and follows the table from then on.
function Model:Open()
  if self.crafters then
    return
  end
  self.crafters, self.keyRecipes = {}, {}
  for key, payload in self.sync:Iterate(TABLE) do
    self:SetRecord(key, payload)
  end
  self.sync.RegisterCallback(self, "OnRecordChanged", "OnRecordChanged")
end

---Drops the index and stops following the table.
function Model:Close()
  if not self.crafters then
    return
  end
  self.sync.UnregisterCallback(self, "OnRecordChanged")
  self.crafters, self.keyRecipes = nil, {}
end

---Follows the table: a new, changed, deleted, or cleaned-up record changes the index.
---@param _event string
---@param tableName string
---@param key string
---@param payload any nil when the record is gone
function Model:OnRecordChanged(_event, tableName, key, payload)
  if tableName ~= TABLE then
    return
  end
  self:SetRecord(key, payload)
  if self.onChanged then
    self.onChanged()
  end
end

---Counts the recipes of the index.
---@return integer
function Model:RecipeCount()
  local count = 0
  for _ in pairs(self.crafters or {}) do
    count = count + 1
  end
  return count
end

---Asks the name loader for the names of all reagents of all indexed recipes, so that the search by
---material finds them. The facts of the recipes are read across frames.
---@param after (fun(seconds: number, fn: fun()): any)? Calls `fn` once, later; without it all is done at once
---@param onDone (fun(items: integer))? Called with the number of different reagent items
function Model:PrepareNames(after, onDone)
  local recipeIds = {}
  for recipeId in pairs(self.crafters or {}) do
    recipeIds[#recipeIds + 1] = recipeId
  end
  local seen, itemIds, position = {}, {}, 1
  local function step()
    local last = after and math.min(#recipeIds, position + search.CHUNK - 1) or #recipeIds
    for index = position, last do
      local facts = self.facts(recipeIds[index])
      for _, reagent in ipairs(facts and facts.reagents or {}) do
        if not seen[reagent.itemId] then
          seen[reagent.itemId] = true
          itemIds[#itemIds + 1] = reagent.itemId
        end
      end
    end
    position = last + 1
    if position <= #recipeIds and after then
      after(0, step)
      return
    end
    self.names:Prepare(itemIds)
    if onDone then
      onDone(#itemIds)
    end
  end
  step()
end

---Returns the name of a recipe in lower case.
---@param recipeId integer
---@return string|nil name nil for an id that the client does not know: it is found by no text
function Model:LowerName(recipeId)
  local known = self.recipeLower[recipeId]
  if known ~= nil then
    return known or nil
  end
  local facts = self.facts(recipeId)
  if facts and facts.name then
    known = lower(facts.name)
    self.recipeLower[recipeId] = known
    return known
  end
  -- Without facts the answer can be a secret value of this moment, so only a recipe without a name is kept
  if facts then
    self.recipeLower[recipeId] = false
  end
  return nil
end

---Tells whether a recipe has a reagent whose name has the text.
---@param recipeId integer
---@param needle string In lower case
---@return boolean
function Model:HasMaterial(recipeId, needle)
  local facts = self.facts(recipeId)
  for _, reagent in ipairs(facts and facts.reagents or {}) do
    local name = self.itemLower[reagent.itemId]
    if not name then
      -- A name that arrives later is taken by the next search
      local loaded = self.names:Name(reagent.itemId)
      if loaded then
        name = lower(loaded)
        self.itemLower[reagent.itemId] = name
      end
    end
    if name and name:find(needle, 1, true) then
      return true
    end
  end
  return false
end

---Lists the members of a recipe from the keys of its records.
---@param recipeId integer
---@return OOOOProfessionCrafter[] crafters Online first, then by name
---@return integer|nil professionId The profession of the first record
function Model:Crafters(recipeId)
  local crafters, professionId = {}, nil
  for key in pairs(self.crafters and self.crafters[recipeId] or {}) do
    local name, id = data.parseKey(key)
    local payload = self.sync:Get(TABLE, key)
    if name and payload then
      crafters[#crafters + 1] = { name = name, online = self.isOnline(name) == true, level = payload.l,
        max = payload.m }
      if not professionId or id < professionId then
        professionId = id
      end
    end
  end
  table.sort(crafters, function(left, right)
    if left.online ~= right.online then
      return left.online
    end
    return left.name < right.name
  end)
  return crafters, professionId
end

---Searches the recipes that at least one member knows. A text is a plain substring, without regard to
---letter case; with both texts a recipe must match both. A text of fewer than 2 characters is not searched,
---and without any text the result is empty.
---@param recipeText any Part of a recipe name
---@param materialText any Part of the name of a reagent
---@return OOOOProfessionRow[] rows In the order of the names, at most `MAX_ROWS`
---@return integer total How many recipes match; more than the rows when the list was cut
function Model:Search(recipeText, materialText)
  local recipeNeedle, materialNeedle = search.needle(recipeText), search.needle(materialText)
  local rows = {}
  if not self.crafters or (not recipeNeedle and not materialNeedle) then
    return rows, 0
  end
  local matches = {}
  for recipeId in pairs(self.crafters) do
    local name = self:LowerName(recipeId)
    if name and (not recipeNeedle or name:find(recipeNeedle, 1, true))
      and (not materialNeedle or self:HasMaterial(recipeId, materialNeedle)) then
      matches[#matches + 1] = { id = recipeId, name = name }
    end
  end
  table.sort(matches, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.id < right.id
  end)
  for index = 1, math.min(#matches, search.MAX_ROWS) do
    local recipeId = matches[index].id
    local facts = self.facts(recipeId) --[[@as OOOORecipeFacts]]
    local crafters, professionId = self:Crafters(recipeId)
    local names, online = {}, 0
    for position, crafter in ipairs(crafters) do
      names[position] = crafter.name
      online = online + (crafter.online and 1 or 0)
    end
    rows[#rows + 1] = { id = recipeId, name = facts.name, icon = facts.icon, itemId = facts.itemId,
      professionId = professionId, crafters = names, online = online }
  end
  return rows, #matches
end

---Returns what the detail part shows for one recipe: the reagents with their names and counts, and all
---members who know it with their skill level.
---@param recipeId integer
---@return OOOOProfessionDetail
function Model:Detail(recipeId)
  local facts = self.facts(recipeId)
  local crafters, professionId = self:Crafters(recipeId)
  local reagents = {}
  for index, reagent in ipairs(facts and facts.reagents or {}) do
    reagents[index] = { itemId = reagent.itemId, count = reagent.count, name = self.names:Name(reagent.itemId) }
  end
  return {
    id = recipeId,
    name = facts and facts.name or ("#" .. recipeId),
    icon = facts and facts.icon,
    itemId = facts and facts.itemId,
    count = facts and facts.count or 1,
    professionId = professionId,
    reagents = reagents,
    crafters = crafters,
  }
end
