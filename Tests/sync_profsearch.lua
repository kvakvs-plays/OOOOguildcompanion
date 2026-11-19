-- Host test of the search model of the window "Guild professions" (.agents/00-plan.md, section 5.4 and step
-- 12.6; Addon/Src/Professions/ProfessionSearch.lua) with stubs for the recipe facts and the item names.
-- `string.lower` of the host changes only ASCII, so the texts are ASCII.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Professions/ProfessionData.lua", "Addon/Src/Professions/ProfessionSearch.lua" }

---Recipe id -> facts, as `ns.professionRecipes.Facts` gives them
local FACTS = {
  [3757] = { id = 3757, name = "Woolen Bag", icon = 1, itemId = 4240, count = 1,
    reagents = { { itemId = 2997, count = 3 }, { itemId = 2321, count = 1 } } },
  [18445] = { id = 18445, name = "Mooncloth Bag", icon = 2, itemId = 14155, count = 1,
    reagents = { { itemId = 14048, count = 4 }, { itemId = 14342, count = 1 } } },
  [18560] = { id = 18560, name = "Mooncloth", icon = 3, itemId = 14342, count = 1,
    reagents = { { itemId = 14256, count = 2 } } },
  [2330] = { id = 2330, name = "Minor Healing Potion", icon = 4, itemId = 118, count = 1,
    reagents = { { itemId = 2447, count = 1 }, { itemId = 765, count = 1 } } },
  [7421] = { id = 7421, name = "Runed Copper Rod (50%)", icon = 5, count = 1,
    reagents = { { itemId = 6217, count = 1 } } },
  [9000] = { id = 9000, name = "Self-made Thing", icon = 6, itemId = 9001, count = 2, reagents = {} },
}
---Item id -> name
local ITEMS = {
  [2997] = "Bolt of Woolen Cloth", [2321] = "Fine Thread", [14048] = "Bolt of Runecloth", [14342] = "Mooncloth",
  [14256] = "Felcloth", [2447] = "Peacebloom", [765] = "Silverleaf", [6217] = "Copper Rod",
}

---Makes a replica with a search model on stubs.
---@param net Fakenet
---@param name string
---@return TestReplica replica
---@return table model
---@return table world Fields: `items` (the names that are loaded), `online` (set of names), `prepared`
local function withSearch(net, name)
  local replica = Replica.new(net, name, { random = random })
  T.loadAll(FILES, replica.ns)
  local world = { items = {}, online = {}, prepared = nil, factCalls = 0 }
  for itemId, itemName in pairs(ITEMS) do
    world.items[itemId] = itemName
  end
  local model = replica.ns.professionSearch.new({
    sync = replica.sync,
    facts = function(recipeId)
      world.factCalls = world.factCalls + 1
      return FACTS[recipeId]
    end,
    names = {
      Name = function(_self, itemId)
        return world.items[itemId]
      end,
      Prepare = function(_self, itemIds)
        world.prepared = itemIds
      end,
    },
    isOnline = function(member)
      return world.online[member] == true
    end,
  })
  return replica, model, world
end

---Stores a record of another member, as a pull brings it.
---@param replica TestReplica
---@param key string
---@param level integer
---@param ids integer[] Recipe ids
---@param counter integer Makes the id of the record distinct
local function foreign(replica, key, level, ids, counter)
  local versionId = replica.ns.versionId
  local now = math.floor(replica.net:Now())
  local changed = replica.sync:ApplyRemote("profession", { { key = key,
    id = versionId.make(now - 100, "YYYY", counter), payload = { l = level, m = 300,
      r = replica.ns.professionData.packRecipes(ids) } } })
  T.eq(#changed, 1, "the record of " .. key .. " is stored")
end

---Returns the recipe ids of rows.
local function idsOf(rows)
  local ids = {}
  for index, row in ipairs(rows) do
    ids[index] = row.id
  end
  return ids
end

-- The needle
do
  local net = Fakenet.new({ random = random })
  local a = withSearch(net, "Nota Scam")
  local needle = a.ns.professionSearch.needle
  T.eq(needle("  Moon Cloth "), "moon cloth", "the text is trimmed and in lower case")
  T.eq(needle("b"), nil, "one character is not searched")
  T.eq(needle(" b "), nil, "spaces around it do not count")
  T.eq(needle(""), nil, "nor an empty text")
  T.eq(needle(nil), nil, "nor no text")
  T.eq(needle("ba"), "ba", "two characters are")
  T.eq(needle("\208\175"), nil, "one letter of two bytes is one character")
  T.eq(needle("\208\175\208\175") ~= nil, true, "two such letters are searched")
end

-- Search by recipe name, by material, by both
do
  local net = Fakenet.new({ random = random })
  local a, model, world = withSearch(net, "Nota Scam")
  local data = a.ns.professionData
  a.sync:Put("profession", "Nota Scam:197", { l = 300, m = 300, r = data.packRecipes({ 3757, 18445, 18560 }) })
  a.sync:Put("profession", "Nota Scam:333", { l = 120, m = 150, r = data.packRecipes({ 7421, 77777 }) })
  a.sync:Put("profession", "Nota Scam:393", { l = 80, m = 150 })
  foreign(a, "Other One:197", 250, { 3757, 18445 }, 1)
  foreign(a, "Zed Last:171", 60, { 2330 }, 2)
  foreign(a, "Abe First:197", 290, { 18445 }, 3)
  world.online = { ["Other One"] = true, ["Zed Last"] = true }

  T.eq({ model:Search("bag", "") }, { {}, 0 }, "a model that is not open finds nothing")
  model:Open()
  T.eq(model:RecipeCount(), 6, "the index has every recipe that a member knows, once")
  T.eq({ model:Search("", "") }, { {}, 0 }, "with both boxes empty the list is empty")
  T.eq({ model:Search("b", "") }, { {}, 0 }, "fewer than 2 characters give nothing")

  local rows, total = model:Search("bag", "")
  T.eq({ idsOf(rows), total }, { { 18445, 3757 }, 2 }, "a search by recipe name, in the order of the names")
  T.eq(rows[1], { id = 18445, name = "Mooncloth Bag", icon = 2, itemId = 14155, professionId = 197,
    crafters = { "Other One", "Abe First", "Nota Scam" }, online = 1 },
    "a row has the recipe, its profession, and the members, online first")
  T.eq(idsOf(model:Search("BAG", nil)), { 18445, 3757 }, "the letter case does not matter")
  T.eq(idsOf(model:Search("  mooncloth ", "")), { 18560, 18445 }, "spaces around the text do not count")
  T.eq(idsOf(model:Search("", "mooncloth")), { 18445 }, "a search by material finds the recipe that uses it")
  T.eq(idsOf(model:Search("", "bolt of")), { 18445, 3757 }, "a material in two recipes")
  T.eq(idsOf(model:Search("woolen", "bolt")), { 3757 }, "both boxes must match")
  T.eq(idsOf(model:Search("potion", "bolt")), {}, "a recipe that matches only one box is left out")
  T.eq(idsOf(model:Search("a", "felcloth")), { 18560 }, "a box with one character is not searched")
  T.eq(idsOf(model:Search("potion", "")), { 2330 }, "a recipe of another member alone")

  -- Pattern characters are plain text
  T.eq(idsOf(model:Search("(50%)", "")), { 7421 }, "a text with pattern characters is taken literally")
  T.eq(idsOf(model:Search("self-made", "")), {}, "a recipe that nobody knows is not found")
  T.eq(idsOf(model:Search("%a+", "")), {}, "a pattern is no pattern")
  T.eq(idsOf(model:Search("", ".-")), {}, "also not in the material box")

  -- An id that the client does not know
  T.eq(idsOf(model:Search("77777", "")), {}, "a recipe id that the client does not know is found by no text")
  T.eq(idsOf(model:Search("#7", "")), {}, "also not by its shown form")
  T.eq(model:Detail(77777), { id = 77777, name = "#77777", count = 1, professionId = 333, reagents = {},
    crafters = { { name = "Nota Scam", online = false, level = 120, max = 150 } } },
    "its detail has the id as name and no reagents")

  -- Detail
  T.eq(model:Detail(18445), { id = 18445, name = "Mooncloth Bag", icon = 2, itemId = 14155, count = 1,
    professionId = 197,
    reagents = { { itemId = 14048, count = 4, name = "Bolt of Runecloth" },
      { itemId = 14342, count = 1, name = "Mooncloth" } },
    crafters = { { name = "Other One", online = true, level = 250, max = 300 },
      { name = "Abe First", online = false, level = 290, max = 300 },
      { name = "Nota Scam", online = false, level = 300, max = 300 } } },
    "the detail has the reagents with their names and the members with their levels, online first")

  -- The names of all reagents are prepared
  local items
  model:PrepareNames(nil, function(count)
    items = count
  end)
  table.sort(world.prepared)
  T.eq(world.prepared, { 765, 2321, 2447, 2997, 6217, 14048, 14256, 14342 },
    "the names of all reagents of all listed recipes are prepared, each once")
  T.eq(items, 8, "and counted")
  world.prepared = nil
  local steps = 0
  a.ns.professionSearch.CHUNK = 2
  model:PrepareNames(function(_seconds, fn)
    steps = steps + 1
    net:After(0, fn)
  end)
  T.eq(world.prepared, nil, "across frames nothing is prepared before the last frame")
  net:Advance(1)
  T.eq({ steps, #world.prepared }, { 2, 8 }, "6 recipes in chunks of 2 take two more frames")

  -- The index follows the table
  local changes = 0
  model.onChanged = function()
    changes = changes + 1
  end
  foreign(a, "New Member:171", 10, { 2330, 9000 }, 4)
  T.eq(changes, 1, "a change of the table is told to the window")
  T.eq(idsOf(model:Search("self-made", "")), { 9000 }, "a new remote record enters the index")
  T.eq(model:Search("potion", "")[1].crafters, { "Zed Last", "New Member" }, "and joins a recipe that was known")
  a.sync:Put("profession", "Nota Scam:197", { l = 300, m = 300, r = data.packRecipes({ 3757, 18560 }) })
  T.eq(model:Search("mooncloth bag", "")[1].crafters, { "Other One", "Abe First" },
    "a record that lists a recipe no longer leaves it")
  a.sync:Delete("profession", "Nota Scam:197")
  T.eq(idsOf(model:Search("mooncloth", "")), { 18445 },
    "a tombstone leaves the index: an unlearned profession takes its recipes with it")
  T.eq(model:Search("woolen", "")[1].crafters, { "Other One" }, "the other members of its recipes stay")
  a.sync:Put("profession", "Nota Scam:197", { l = 1, m = 75 })
  T.eq(idsOf(model:Search("mooncloth", "")), { 18445 }, "a profession that is learned again has no recipes")
  -- The roster cleanup removes the records of a member who left
  a.sync:Sweep("profession", function(key)
    return key:find("^Other One:") ~= nil
  end)
  T.eq(idsOf(model:Search("woolen", "")), {}, "a record that the cleanup removed leaves the index")
  T.eq(model:Search("mooncloth bag", "")[1].crafters, { "Abe First" }, "with its member")
  local count = changes
  a.sync:Put("character", "Nota Scam", { class = "MAGE", level = 10, origins = { a.sync:GetOrigin() } })
  T.eq(changes, count, "a change of another table is not told")

  model:Close()
  T.eq({ model:Search("mooncloth", "") }, { {}, 0 }, "a closed model finds nothing")
  foreign(a, "Late One:171", 10, { 2330 }, 5)
  T.eq(changes, count, "and follows the table no longer")
  model:Open()
  T.eq(model:Search("potion", "")[1].crafters, { "Zed Last", "Late One", "New Member" },
    "opened again it has what arrived meanwhile")
end

-- A name that arrives later makes its recipe findable
do
  local net = Fakenet.new({ random = random })
  local a, model, world = withSearch(net, "Nota Scam")
  local data = a.ns.professionData
  a.sync:Put("profession", "Nota Scam:197", { l = 300, m = 300, r = data.packRecipes({ 18560 }) })
  world.items[14256] = nil
  model:Open()
  T.eq(idsOf(model:Search("", "felcloth")), {}, "a material without a loaded name is found by no text")
  T.eq(model:Detail(18560).reagents, { { itemId = 14256, count = 2 } }, "and has no name in the detail")
  world.items[14256] = "Felcloth"
  T.eq(idsOf(model:Search("", "felcloth")), { 18560 }, "a name that arrives later makes its recipe findable")
end

-- The cut at 200
do
  local net = Fakenet.new({ random = random })
  local a, model, world = withSearch(net, "Nota Scam")
  local data = a.ns.professionData
  local ids = {}
  for index = 1, 250 do
    ids[index] = 30000 + index
    FACTS[ids[index]] = { id = ids[index], name = string.format("Test Recipe %03d", 251 - index), count = 1,
      reagents = {} }
  end
  a.sync:Put("profession", "Nota Scam:197", { l = 300, m = 300, r = data.packRecipes(ids) })
  model:Open()
  local rows, total = model:Search("test recipe", "")
  T.eq({ #rows, total }, { 200, 250 }, "the list is cut at 200 and tells how many match")
  T.eq({ rows[1].name, rows[200].name }, { "Test Recipe 001", "Test Recipe 200" }, "the cut keeps the first names")
  rows, total = model:Search("recipe 00", "")
  T.eq({ #rows, total }, { 9, 9 }, "a narrower text gives a list that is not cut")
  world.factCalls = 0
  model:Search("recipe 01", "")
  T.ok(world.factCalls <= 20, "a later search does not ask the facts of every recipe again: " .. world.factCalls)
end

T.finish()
