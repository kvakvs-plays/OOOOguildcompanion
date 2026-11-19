local addonName, ns = ...

-- The table `profession` of the shared database (.agents/00-plan.md, section 5.4): who in the guild can craft
-- what. One record per character and profession, under the key "First Last:<profession id>". The table holds
-- numbers only, never a name: members play clients of different languages.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_profdata.lua).

---@class OOOOProfessionPayload Payload of a record in the table `profession`
---@field l integer Skill level, 1 to 450
---@field m integer Highest level of the learned rank, 1 to 450
---@field s integer|nil Spell id of the specialization; not written yet (plan 5.4)
---@field r string|nil The known recipe ids in ascending order, each as 4 base-94 characters; absent when the
---character knows no recipe of the profession

---@class OOOOProfessionData
local data = {}
ns.professionData = data

local base94 = ns.base94

---Name of the table
data.TABLE = "profession"
---Characters of one recipe id in the packed list
data.ID_WIDTH = 4
---Largest id that fits into `ID_WIDTH` characters: 94^4 - 1
data.MAX_ID = 78074895
---Highest skill level that a record can carry; wider than the 300 of the release on purpose
data.MAX_LEVEL = 450
---Largest profession id (a skill line id) in a key
data.MAX_PROFESSION_ID = 99999

local ID_WIDTH = data.ID_WIDTH

---Tells whether a value is an integer within a range.
---@param value any
---@param low integer
---@param high integer
---@return boolean
local function isInteger(value, low, high)
  return type(value) == "number" and value >= low and value <= high and value == math.floor(value)
end

---Packs recipe ids into the text of the field `r`: sorted, each id once. One set of recipes gives one text,
---so `Put` can tell that a scan found nothing new. A value that is no id (not an integer from 1 to `MAX_ID`)
---is left out.
---@param ids any[] Recipe ids in any order
---@return string|nil text nil when no id is left: the field is then absent
function data.packRecipes(ids)
  local sorted = {}
  for _, id in ipairs(ids) do
    if isInteger(id, 1, data.MAX_ID) then
      sorted[#sorted + 1] = id
    end
  end
  table.sort(sorted)
  local parts = {}
  for index, id in ipairs(sorted) do
    if id ~= sorted[index - 1] then
      parts[#parts + 1] = base94.encode(id, ID_WIDTH)
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts)
end

---Tells whether a value is a packed recipe list: at least one id, every id of 4 base-94 characters and
---above 0, in strictly ascending order.
---@param text any
---@return boolean
function data.isRecipeList(text)
  if type(text) ~= "string" or #text == 0 or #text % ID_WIDTH ~= 0 or not base94.isValid(text) then
    return false
  end
  -- Texts of one width compare in the order of their numbers; the text of 0 is the smallest
  local previous = base94.encode(0, ID_WIDTH)
  for position = 1, #text, ID_WIDTH do
    local id = text:sub(position, position + ID_WIDTH - 1)
    if id <= previous then
      return false
    end
    previous = id
  end
  return true
end

---Reads the recipe ids out of the field `r`.
---@param text any The field; nil for a record without recipes
---@return integer[] ids In ascending order; empty when `text` is nil or no packed recipe list
function data.unpackRecipes(text)
  local ids = {}
  if not data.isRecipeList(text) then
    return ids
  end
  for position = 1, #text, ID_WIDTH do
    ids[#ids + 1] = base94.decode(text:sub(position, position + ID_WIDTH - 1))
  end
  return ids
end

---Counts the recipes of the field `r` without unpacking it.
---@param text any
---@return integer
function data.recipeCount(text)
  -- math.floor: the host Lua 5.4 gives a float for `/`
  return data.isRecipeList(text) and math.floor(#text / ID_WIDTH) or 0
end

---Joins a stored recipe list with newly found ids: a scan only adds (plan 5.4), because a scan can be partial.
---@param text any The stored field `r`; nil or a damaged text counts as empty
---@param ids any[] Recipe ids that a scan found
---@return string|nil merged The packed union; equal to `text` when the scan found nothing new
function data.mergeRecipes(text, ids)
  local all = data.unpackRecipes(text)
  for _, id in ipairs(ids) do
    all[#all + 1] = id
  end
  return data.packRecipes(all)
end

---Builds the key of a record: the character name, `:`, and the profession id.
---@param name string Character name as the roster shows it; it can have a space
---@param professionId integer Skill line id
---@return string
function data.key(name, professionId)
  return name .. ":" .. professionId
end

---Splits a key into the character name and the profession id.
---@param key any
---@return string|nil name nil when the key has another form
---@return integer|nil professionId
function data.parseKey(key)
  if type(key) ~= "string" then
    return nil
  end
  -- No leading zero, so that one profession of a character has one key
  local name, digits = key:match("^([^:]+):([1-9]%d*)$")
  local professionId = tonumber(digits)
  if not name or not professionId or professionId > data.MAX_PROFESSION_ID then
    return nil
  end
  return name, professionId
end

---Checks a record of the table `profession`: the form of the key, the types and ranges of the fields, the
---form of the recipe list, and no other fields.
---@param key string
---@param payload any
---@return boolean
function data.validate(key, payload)
  if not data.parseKey(key) or type(payload) ~= "table" then
    return false
  end
  if not isInteger(payload.l, 1, data.MAX_LEVEL) or not isInteger(payload.m, 1, data.MAX_LEVEL) then
    return false
  end
  if payload.s ~= nil and not isInteger(payload.s, 1, data.MAX_ID) then
    return false
  end
  if payload.r ~= nil and not data.isRecipeList(payload.r) then
    return false
  end
  for field in pairs(payload) do
    if field ~= "l" and field ~= "m" and field ~= "s" and field ~= "r" then
      return false
    end
  end
  return true
end

ns.sync:RegisterTable({
  name = data.TABLE,
  schema = 1,
  -- The key starts with the character name, so the owner rule and the roster cleanup apply
  keyKind = "character",
  validate = data.validate,
  -- About 470 recipes; the largest Classic profession has about 300
  maxRecordBytes = 2000,
  writers = "owner",
  -- Every skill point changes a record and sends it whole, so the changes of 15 minutes go out together
  policy = { when = "nocombat", pushDelay = 300, minInterval = 900 },
})
