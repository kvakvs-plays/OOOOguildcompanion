-- Host test of the model of the tab "Members" (Addon/Src/Professions/ProfessionRoster.lua): the members
-- with their professions and skill levels, read from the tables `profession` and `character`.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Professions/ProfessionData.lua", "Addon/Src/Professions/ProfessionRoster.lua" }

---Stores a record of another member, as a pull brings it.
---@param replica TestReplica
---@param tableName string
---@param key string
---@param payload table
---@param counter integer Makes the id of the record distinct
local function foreign(replica, tableName, key, payload, counter)
  local now = math.floor(replica.net:Now())
  local changed = replica.sync:ApplyRemote(tableName, { { key = key,
    id = replica.ns.versionId.make(now - 100, "YYYY", counter), payload = payload } })
  T.eq(#changed, 1, "the record of " .. key .. " is stored")
end

---Returns the names of rows.
local function namesOf(rows)
  local names = {}
  for index, row in ipairs(rows) do
    names[index] = row.name
  end
  return names
end

do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  T.loadAll(FILES, a.ns)
  local data, roster = a.ns.professionData, a.ns.professionRoster
  local online = {}
  local parts = {
    sync = a.sync,
    isOnline = function(name)
      return online[name] == true
    end,
  }

  T.eq({ roster.rows(parts) }, { {}, {} }, "an empty table gives no member and no profession")

  a.sync:Put("profession", "Nota Scam:197", { l = 300, m = 300, r = data.packRecipes({ 3757, 18445, 18560 }) })
  a.sync:Put("profession", "Nota Scam:333", { l = 120, m = 150 })
  a.sync:Put("profession", "Nota Scam:185", { l = 120, m = 150, r = data.packRecipes({ 2538 }) })
  foreign(a, "profession", "Other One:197", { l = 250, m = 300 }, 1)
  foreign(a, "profession", "Zed Last:171", { l = 60, m = 75, r = data.packRecipes({ 2330 }) }, 2)
  foreign(a, "profession", "Abe First:197", { l = 290, m = 300 }, 3)
  foreign(a, "profession", "Abe First:171", { l = 290, m = 300 }, 4)
  foreign(a, "character", "Zed Last", { class = "MAGE", level = 60, origins = { "YYYY" } }, 5)
  online = { ["Other One"] = true, ["Zed Last"] = true }

  local rows, professionIds = roster.rows(parts)
  T.eq(namesOf(rows), { "Other One", "Zed Last", "Abe First", "Nota Scam" },
    "all members, online ones first, then by name")
  T.eq(professionIds, { 171, 185, 197, 333 }, "the professions that a member has, in ascending order")
  T.eq(rows[2], { name = "Zed Last", online = true, class = "MAGE",
    professions = { { id = 171, level = 60, max = 75, recipes = 1 } } },
    "a row has the class of the character record and the profession with its recipe count")
  T.eq(rows[1].class, nil, "a member without a character record has no class")
  T.eq(rows[4].professions, { { id = 197, level = 300, max = 300, recipes = 3 },
    { id = 185, level = 120, max = 150, recipes = 1 }, { id = 333, level = 120, max = 150, recipes = 0 } },
    "the professions of a member: the highest level first, then by id")
  T.eq(rows[3].professions[1].id, 171, "equal levels are in the order of the ids")

  local tailors, ids = roster.rows(parts, 197)
  T.eq(namesOf(tailors), { "Nota Scam", "Abe First", "Other One" },
    "with a profession: only its members, the highest level first")
  T.eq({ tailors[1].level, tailors[2].level, tailors[3].level }, { 300, 290, 250 }, "a row has the level")
  T.eq(#tailors[1].professions, 3, "and still all professions of the member")
  T.eq(ids, { 171, 185, 197, 333 }, "the list of professions does not follow the filter")

  foreign(a, "profession", "Some Body:171", { l = 290, m = 300 }, 6)
  online["Some Body"] = true
  T.eq(namesOf(roster.rows(parts, 171)), { "Some Body", "Abe First", "Zed Last" },
    "with equal levels the online member is first")
  T.eq(namesOf(roster.rows(parts, 356)), {}, "a profession that nobody has gives no member")

  a.sync:Delete("profession", "Nota Scam:333")
  local _, afterDelete = roster.rows(parts)
  T.eq(afterDelete, { 171, 185, 197 }, "a deleted record is not read")
end

T.finish()
