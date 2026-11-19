-- Host test of the profession scan (.agents/00-plan.md, section 5.4, steps 12.3 and 12.4;
-- Addon/Src/Professions/ProfessionScan.lua) with a stub in place of the client.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Professions/ProfessionData.lua", "Addon/Src/Professions/ProfessionScan.lua" }

---@class TestProfessionClient What the stub client shows; a test changes the fields
---@field professions table[] The list of professions: { id, level, max, name }
---@field listSecret boolean true: the list has a secret value
---@field window table|nil The open window: { id, ids, learned = set, foreign, secret, secretRecipe }
---@field lines table<integer, any> Recipe id -> skill line of a learned recipe, or { skill line, parent }
---@field asked integer Calls of `isLearned`

---Makes a replica with a scanner on a stub client.
---@param net Fakenet
---@param name string
---@return TestReplica replica
---@return table scanner
---@return TestProfessionClient client
local function withScanner(net, name)
  local replica = Replica.new(net, name, { random = random })
  T.loadAll(FILES, replica.ns)
  local client = { professions = {}, lines = {}, asked = 0 }
  local reader = {
    readProfessions = function()
      if client.listSecret then
        return nil, "a secret value"
      end
      local list = {}
      for index, entry in ipairs(client.professions) do
        list[index] = { id = entry.id, level = entry.level, max = entry.max, name = entry.name }
      end
      return list
    end,
    isOwnWindow = function()
      local window = client.window
      if window and window.secret then
        return nil
      end
      return window ~= nil and not window.foreign
    end,
    readRecipes = function()
      if not client.window then
        return nil, "the window names no profession"
      end
      return client.window.id, client.window.ids
    end,
    isLearned = function(recipeId)
      client.asked = client.asked + 1
      local window = client.window
      if window and window.secretRecipe == recipeId then
        return nil
      end
      return (window and window.learned[recipeId] or client.lines[recipeId] ~= nil) == true
    end,
    recipeProfession = function(recipeId)
      local line = client.lines[recipeId]
      if type(line) == "table" then
        return line[1], line[2]
      end
      return line
    end,
  }
  local scanner = replica.ns.professionScan.new({
    reader = reader,
    sync = replica.sync,
    playerName = function()
      return name
    end,
    now = function()
      return net:Now()
    end,
    after = function(seconds, fn)
      return replica.endpoint:After(seconds, fn)
    end,
    print = function(text)
      replica.notices[#replica.notices + 1] = text
    end,
  })
  return replica, scanner, client
end

---Returns a window of a profession: the recipe ids and which of them are learned.
---@param id integer Skill line id
---@param ids integer[] All recipes of the profession
---@param learned integer[] The learned ones
---@return table
local function window(id, ids, learned)
  local set = {}
  for _, recipeId in ipairs(learned) do
    set[recipeId] = true
  end
  return { id = id, ids = ids, learned = set }
end

---Returns the recipe ids of a stored record.
local function stored(replica, key)
  local payload = replica.sync:Get("profession", key)
  return payload and replica.ns.professionData.unpackRecipes(payload.r)
end

local ALCHEMY = { id = 171, level = 275, max = 300, name = "Alchemy" }
local TAILORING = { id = 197, level = 150, max = 225, name = "Tailoring" }
local SKINNING = { id = 393, level = 80, max = 150, name = "Skinning" }

-- The list of professions: the first read, the hint, an equal read
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  client.professions = { ALCHEMY, TAILORING, SKINNING }
  local version = a:Version("profession")
  scanner:ScheduleRead()
  net:Advance(1)
  T.eq(a:Version("profession"), version, "a scanner that is not active reads nothing")
  scanner:SetActive(true)
  net:Advance(1)
  T.eq(a.sync:Get("profession", "Nota Scam:171"), { l = 275, m = 300 }, "the first read writes the levels")
  T.eq(a.sync:Get("profession", "Nota Scam:197"), { l = 150, m = 225 }, "of every profession")
  T.eq(a.sync:Get("profession", "Nota Scam:393"), { l = 80, m = 150 }, "also of a gathering one")
  T.eq(a.notices, { "Open your Alchemy and Tailoring windows once, so that the guild can see what you craft." },
    "the hint names the professions with recipes that have no recipe list")
  version = a:Version("profession")
  scanner:ScheduleRead()
  net:Advance(10)
  T.eq(a:Version("profession"), version, "an equal read writes nothing")
  T.eq(#a.notices, 1, "the hint comes once per session")

  -- Events in a burst give one read in 5 seconds
  client.professions = { { id = 171, level = 276, max = 300, name = "Alchemy" }, TAILORING, SKINNING }
  for _ = 1, 10 do
    scanner:ScheduleRead()
  end
  T.eq(a.sync:Get("profession", "Nota Scam:171").l, 275, "a read that events ask for waits for its turn")
  net:Advance(6)
  T.eq(a.sync:Get("profession", "Nota Scam:171").l, 276, "and then writes the new level")

  -- A level that the client does not show yet gives no record
  client.professions = { { id = 171, level = 276, max = 300 }, TAILORING, SKINNING,
    { id = 356, level = 0, max = 0, name = "Fishing" } }
  scanner:ScheduleRead()
  net:Advance(6)
  T.eq(a.sync:Get("profession", "Nota Scam:356"), nil, "a profession with the level 0 gets no record")

  -- A secret value ends the read
  client.listSecret = true
  client.professions = { { id = 171, level = 300, max = 300 } }
  version = a:Version("profession")
  scanner:ScheduleRead()
  net:Advance(20)
  T.eq(a:Version("profession"), version, "a secret value in the list ends the read without a write")
  T.ok(scanner:StatusLines()[1]:find("3 stored", 1, true), "the status counts the stored professions")
end

-- The hint: one profession, and none when the lists are there
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  local data = a.ns.professionData
  a.sync:Put("profession", "Nota Scam:171", { l = 200, m = 225, r = data.packRecipes({ 2330 }) })
  client.professions = { ALCHEMY, SKINNING, { id = 185, level = 10, max = 75, name = "Cooking" } }
  scanner:SetActive(true)
  net:Advance(1)
  T.eq(a.notices, { "Open your Cooking window once, so that the guild can see what you craft." },
    "the hint leaves out a profession with a recipe list and one without recipes")
  T.eq(a.sync:Get("profession", "Nota Scam:171"), { l = 275, m = 300, r = data.packRecipes({ 2330 }) },
    "a read of the list keeps the stored recipes")

  local b, other, otherClient = withScanner(net, "Other One")
  b.sync:Put("profession", "Other One:171", { l = 200, m = 225, r = data.packRecipes({ 2330 }) })
  otherClient.professions = { ALCHEMY, SKINNING }
  other:SetActive(true)
  net:Advance(1)
  T.eq(b.notices, {}, "no hint when every profession with recipes has its list")
end

-- The window: a first scan, an equal scan, a partial scan, recipes that are not learned
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  client.professions = { ALCHEMY, TAILORING }
  scanner:SetActive(true)
  net:Advance(1)
  client.window = window(171, { 2330, 2331, 2332, 2333, 2334 }, { 2331, 2333, 2334 })
  scanner:ScheduleScan()
  T.eq(stored(a, "Nota Scam:171"), {}, "the scan waits a moment after the event")
  net:Advance(1)
  T.eq(stored(a, "Nota Scam:171"), { 2331, 2333, 2334 }, "a first scan writes the learned recipes and no other")
  T.eq(a.sync:Get("profession", "Nota Scam:171").l, 275, "with the level")
  T.eq(stored(a, "Nota Scam:197"), {}, "the other profession is untouched")
  T.ok(scanner.scanStatus:find("3 of 5 recipes are learned, 3 new", 1, true), "the status tells what the scan did: "
    .. scanner.scanStatus)

  local version = a:Version("profession")
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "an equal scan writes nothing")

  -- A partial scan: the client lists fewer recipes
  client.window = window(171, { 2331 }, { 2331 })
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "a partial scan removes nothing")
  client.window = window(171, { 2330, 2331 }, { 2330, 2331 })
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(stored(a, "Nota Scam:171"), { 2330, 2331, 2333, 2334 }, "a later scan adds what is new")

  -- Events in a burst give one scan in 2 seconds
  scanner:ScheduleScan()
  net:Advance(0.3)
  client.asked = 0
  for _ = 1, 20 do
    scanner:ScheduleScan()
  end
  net:Advance(1.5)
  T.eq(client.asked, 0, "the next scan waits until 2 seconds after the last one")
  net:Advance(1)
  T.eq(client.asked, 2, "then one scan runs for the whole burst")

  -- Foreign data, a foreign profession, secret values
  version = a:Version("profession")
  client.window = window(171, { 9001, 9002 }, { 9001, 9002 })
  client.window.foreign = true
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "a scan of a foreign window writes nothing")
  client.window = window(164, { 9001, 9002 }, { 9001, 9002 })
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "nor one of a profession that the character does not have")
  T.eq(a.sync:Get("profession", "Nota Scam:164"), nil, "no record of that profession appears")
  client.window = window(171, { 9001, 9002 }, { 9001, 9002 })
  client.window.secret = true
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "a secret value of the window ends the scan")
  client.window = window(171, { 9001, 9002, 9003 }, { 9001, 9002, 9003 })
  client.window.secretRecipe = 9003
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "a secret value of one recipe ends the scan without a write")
  client.window = nil
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(a:Version("profession"), version, "without a window nothing is written")

  -- The other window
  client.window = window(197, { 3001, 3002 }, { 3002 })
  scanner:ScheduleScan()
  net:Advance(5)
  T.eq(stored(a, "Nota Scam:197"), { 3002 }, "the window of the second profession fills its record")
  T.eq(stored(a, "Nota Scam:171"), { 2330, 2331, 2333, 2334 }, "and leaves the first")
  local lines = scanner:StatusLines()
  T.eq({ lines[1], lines[2], lines[3] }, { "professions of Nota Scam: 2 stored",
    "  Alchemy (171): level 275/300, 4 recipes", "  Tailoring (197): level 150/225, 1 recipes" },
    "the status lists the professions with their recipe counts")
end

-- A scan of many recipes runs across frames
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  client.professions = { ALCHEMY, TAILORING }
  scanner:SetActive(true)
  net:Advance(1)
  local ids = {}
  for index = 1, 350 do
    ids[index] = 5000 + index
  end
  client.window = window(171, ids, ids)
  client.asked = 0
  scanner:ScanWindow()
  T.eq(client.asked, 100, "one frame asks about 100 recipes")
  T.eq(stored(a, "Nota Scam:171"), {}, "nothing is written before the last frame")
  scanner:ScheduleScan()
  net:Advance(0.1)
  T.eq(#stored(a, "Nota Scam:171"), 350, "after the last frame all recipes are stored")
  client.window = window(171, { 5001, 6000 }, { 5001, 6000 })
  net:Advance(5)
  T.eq(#stored(a, "Nota Scam:171"), 351, "an event during the scan gives one more scan afterwards")

  -- The window changes between the frames
  local more = {}
  for index = 1, 250 do
    more[index] = 7000 + index
  end
  local version = a:Version("profession")
  client.window = window(171, more, more)
  scanner:ScanWindow()
  client.window = window(197, more, more)
  net:Advance(0.1)
  T.eq(a:Version("profession"), version, "a window that changes during the scan gives no write")
  net:Advance(5)
end

-- A learned recipe
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  client.professions = { ALCHEMY, TAILORING }
  scanner:SetActive(true)
  net:Advance(1)
  client.window = window(171, { 2330, 2331 }, { 2330 })
  scanner:ScheduleScan()
  net:Advance(5)
  client.window = nil
  client.lines[2335] = 171
  client.professions = { { id = 171, level = 280, max = 300, name = "Alchemy" }, TAILORING }
  T.eq(scanner:OnNewRecipe(2335), true, "the event of a learned recipe adds it")
  T.eq(stored(a, "Nota Scam:171"), { 2330, 2335 }, "the new-recipe event adds one id")
  T.eq(a.sync:Get("profession", "Nota Scam:171").l, 280, "with the level of that moment")
  T.eq(scanner:OnNewRecipe(2335), false, "the same recipe again changes nothing")
  -- The client names a child skill line and its parent
  client.lines[3005] = { 2940, 197 }
  T.eq(scanner:OnNewRecipe(3005), true, "a recipe is added by the parent skill line too")
  T.eq(stored(a, "Nota Scam:197"), { 3005 }, "into the record of that profession")
  -- A recipe whose profession the client does not tell
  local version = a:Version("profession")
  client.lines[4000] = false
  T.eq(scanner:OnNewRecipe(4000), false, "a recipe without a known profession is not added")
  client.lines[4001] = 164
  T.eq(scanner:OnNewRecipe(4001), false, "nor one of a profession that the character does not have")
  T.eq(scanner:OnNewRecipe("2336"), false, "nor a value that is no id")
  T.eq(a:Version("profession"), version, "and nothing is written")
  -- The client shows the recipe as learned a moment after the event
  T.eq(scanner:OnNewRecipe(2336), false, "a recipe that is not shown as learned yet is not added at once")
  client.lines[2336] = 171
  net:Advance(3)
  T.eq(stored(a, "Nota Scam:171"), { 2330, 2335, 2336 }, "it is added by the second try")
end

-- Unlearning
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  local data = a.ns.professionData
  local recipes = data.packRecipes({ 2330, 2331 })
  a.sync:Put("profession", "Nota Scam:171", { l = 275, m = 300, r = recipes })
  a.sync:Put("profession", "Nota Scam:197", { l = 150, m = 225, r = recipes })
  -- A record of another member that only the pull brought
  a.ns.syncStore.apply(a.sync:GetTable("profession"), "Other One:171",
    a.ns.versionId.make(math.floor(net:Now()) - 10, "YYYY", 0), { l = 1, m = 75 })

  -- An empty list right after login deletes nothing, however often it is read
  client.professions = {}
  scanner:SetActive(true)
  net:Advance(120)
  T.eq(a.sync:Get("profession", "Nota Scam:171"), { l = 275, m = 300, r = recipes },
    "an empty list right after login deletes nothing")
  T.eq(a.sync:Get("profession", "Nota Scam:197"), { l = 150, m = 225, r = recipes }, "for no profession")

  -- The list fills: both professions are there
  client.professions = { ALCHEMY, TAILORING }
  scanner:ScheduleRead()
  net:Advance(20)
  T.eq(a.sync:Count("profession"), 3, "all records are there")

  -- Tailoring is unlearned: one read deletes nothing, the second one deletes
  client.professions = { ALCHEMY }
  local before = net:Now()
  scanner:ScheduleRead()
  net:Advance(5.5)
  T.ok(a.sync:Get("profession", "Nota Scam:197"), "one read without the profession deletes nothing")
  net:Advance(10)
  T.eq(a.sync:Get("profession", "Nota Scam:197"), nil, "the second read deletes the record")
  T.ok(net:Now() - before < 20, "the second read comes by itself")
  local record = a.sync:GetTable("profession").records["Nota Scam:197"]
  T.eq(record and record.x, true, "the delete is a tombstone")
  T.ok(a.sync:Get("profession", "Nota Scam:171"), "the other profession stays")
  T.ok(a.sync:Get("profession", "Other One:171"), "and the record of another member")

  -- A profession that comes back between the two reads is not deleted
  client.professions = {}
  scanner:ScheduleRead()
  net:Advance(5.5)
  client.professions = { ALCHEMY }
  net:Advance(20)
  T.ok(a.sync:Get("profession", "Nota Scam:171"), "a profession that is back at the second read stays")
  client.professions = {}
  scanner:ScheduleRead()
  net:Advance(30)
  T.eq(a.sync:Get("profession", "Nota Scam:171"), nil, "an empty list after a filled one deletes, by two reads")

  -- Learned again: the record starts without recipes
  client.professions = { { id = 197, level = 1, max = 75, name = "Tailoring" } }
  scanner:ScheduleRead()
  net:Advance(10)
  T.eq(a.sync:Get("profession", "Nota Scam:197"), { l = 1, m = 75 },
    "a profession that is learned again starts with an empty list")
end

-- The first read that shows a profession is not counted for a delete
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  a.sync:Put("profession", "Nota Scam:171", { l = 275, m = 300 })
  a.sync:Put("profession", "Nota Scam:197", { l = 150, m = 225 })
  client.professions = { ALCHEMY }
  scanner:SetActive(true)
  net:Advance(8)
  T.ok(a.sync:Get("profession", "Nota Scam:197"), "after two reads from the start the record is still there")
  net:Advance(20)
  T.eq(a.sync:Get("profession", "Nota Scam:197"), nil, "it goes after two reads that follow the first filled one")
  scanner:SetActive(false)
  client.professions = { ALCHEMY, TAILORING }
  net:Advance(60)
  T.eq(a.sync:Get("profession", "Nota Scam:197"), nil, "a scanner that was stopped writes nothing")
end

-- Two replicas: the scanned record reaches the other one
do
  local net = Fakenet.new({ random = random })
  local a, scanner, client = withScanner(net, "Nota Scam")
  local b = withScanner(net, "Other One")
  a:Login()
  b:Login()
  net:Advance(100)
  client.professions = { ALCHEMY }
  scanner:SetActive(true)
  client.window = window(171, { 2330, 2331, 2332 }, { 2330, 2332 })
  scanner:ScheduleScan()
  net:Advance(2000)
  T.eq(stored(b, "Nota Scam:171"), { 2330, 2332 }, "the other replica gets the scanned recipes")
  T.eq(b:Version("profession"), a:Version("profession"), "with an equal version of the table")
end

T.finish()
