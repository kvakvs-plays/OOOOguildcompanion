-- Host test of the item names and the recipe facts (.agents/00-plan.md, section 5.4 and step 12.5;
-- Addon/Src/Professions/ProfessionNames.lua and ProfessionRecipes.lua) with a stub client and a fake clock.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")

T.loadLibraries()
local random = T.newRandom()
---A value that the stub `issecretvalue` takes for secret
local SECRET = {}
_G.issecretvalue = function(value)
  return value == SECRET
end

---Makes a name loader on a stub client.
---@return table loader
---@return table client Fields: `known` (item id -> name that the client has now), `data` (item id -> name
---that a load gives), `requests` (item ids in the order of their requests), `times`, `listening`
---@return Fakenet net The clock
local function newLoader()
  local net = Fakenet.new({ random = random })
  local ns = T.load("Addon/Src/Professions/ProfessionNames.lua")
  local client = { known = {}, data = {}, requests = {}, times = {}, listening = false, listenCalls = 0 }
  local loader = ns.professionNames.new({
    nameOf = function(itemId)
      return client.known[itemId]
    end,
    request = function(itemId)
      client.requests[#client.requests + 1] = itemId
      client.times[#client.times + 1] = net:Now()
    end,
    now = function()
      return net:Now()
    end,
    after = function(seconds, fn)
      return net:After(seconds, fn)
    end,
    listen = function(listening)
      client.listening = listening
      client.listenCalls = client.listenCalls + 1
    end,
  })
  ---Answers every request that is out, as the client does: the data arrives, then the event.
  function client.answerAll()
    for itemId in pairs(loader.open) do
      local name = client.data[itemId]
      client.known[itemId] = name
      loader:OnAnswer(itemId, name ~= nil)
    end
  end
  client.changes = 0
  loader.RegisterCallback(client, "OnNamesChanged", function()
    client.changes = client.changes + 1
  end)
  return loader, client, net
end

-- A direct answer, one request per id, the answer, a failed id
do
  local loader, client, net = newLoader()
  net:Advance(60)
  client.known[2589] = "Linen Cloth"
  T.eq(loader:Name(2589), "Linen Cloth", "a name that the client has is given at once")
  T.eq(loader:Name(2589), "Linen Cloth", "and again from the memory")
  net:Advance(5)
  T.eq(client.requests, {}, "a direct answer costs no request")
  T.eq({ loader:Progress() }, { 1, 1 }, "the progress counts the named id")

  client.data[2592] = "Wool Cloth"
  T.eq(loader:Name(2592), nil, "a name that the client lacks is not there at once")
  T.eq(client.requests, {}, "and is not requested at once")
  T.eq(loader:Name(2592), nil, "asking again")
  loader:Prepare({ 2592, 2592 })
  net:Advance(0.4)
  T.eq(client.requests, {}, "the request waits half a second")
  net:Advance(0.2)
  T.eq(client.requests, { 2592 }, "an id is requested once, however often it is asked")
  T.eq(client.listening, true, "the loader listens while a request is open")
  T.eq({ loader:Progress() }, { 1, 2 }, "the progress counts the open id")
  T.eq(client.changes, 0, "nothing has changed yet")
  client.answerAll()
  T.eq(loader:Name(2592), "Wool Cloth", "an answer gives the name")
  T.eq(client.listening, false, "the loader stops listening when no request is open")
  net:Advance(1)
  T.eq(client.changes, 1, "and one call of OnNamesChanged")
  net:Advance(30)
  T.eq(client.requests, { 2592 }, "a named id is not requested again")

  -- A failed load
  T.eq(loader:Name(9999), nil, "an id without data has no name")
  net:Advance(1)
  T.eq(#client.requests, 2, "it is requested")
  client.answerAll()
  net:Advance(1)
  T.eq(client.changes, 2, "its failure is a change too: the count of open names ends")
  T.eq(loader:Name(9999), nil, "a failed id stays without a name")
  loader:Prepare({ 9999 })
  net:Advance(30)
  T.eq(#client.requests, 2, "a failed id is not asked again")
  T.eq({ loader:Progress() }, { 3, 3 }, "the progress counts it as done")
  T.eq(loader:StatusLine(), "item names: 2 named, 1 failed, 0 waiting, 0 open", "the status line")

  -- An answer for an id that was not requested is ignored
  loader:OnAnswer(4242, true)
  net:Advance(1)
  T.eq(client.changes, 2, "an answer for another id changes nothing")

  -- A request without an answer ends as failed
  T.eq(loader:Name(7777), nil, "an id whose answer never comes")
  net:Advance(5)
  T.eq({ loader:Progress() }, { 3, 4 }, "is open at first")
  net:Advance(40)
  T.eq({ loader:Progress() }, { 4, 4 }, "and counts as failed after the timeout")
  T.eq(client.listening, false, "the loader no longer listens")
end

-- Nothing is requested in the first 10 seconds after the login
do
  local loader, client, net = newLoader()
  loader:Prepare({ 1, 2, 3 })
  net:Advance(9.9)
  T.eq(client.requests, {}, "nothing is requested before 10 seconds after the login")
  net:Advance(0.2)
  T.eq(client.requests, { 1, 2, 3 }, "the requests go out when the 10 seconds are over")
end

-- Many names: at most 40 requests in every 0.2 seconds, one OnNamesChanged for the answers of a moment
do
  local loader, client, net = newLoader()
  net:Advance(60)
  local ids = {}
  for index = 1, 500 do
    ids[index] = 10000 + index
    client.data[ids[index]] = "Item " .. index
  end
  -- Some are loaded by the client before their turn comes
  loader:Prepare(ids)
  T.eq(loader:Name(20000), nil, "a single name")
  for index = 461, 480 do
    client.known[ids[index]] = client.data[ids[index]]
  end
  net:Advance(0.45)
  T.eq(#client.requests, 0, "no request before half a second")
  net:Advance(0.1)
  T.eq(#client.requests, 40, "the first group has 40 requests")
  net:Advance(10)
  T.eq(#client.requests, 481, "all names that the client lacked were requested, and the single one")
  T.eq(client.requests[481], 20000, "a single name waits in the same queue, behind the others")
  for index = 1, #client.times do
    local inWindow = 0
    for other = index, #client.times do
      if client.times[other] - client.times[index] < 0.199 then
        inWindow = inWindow + 1
      end
    end
    T.ok(inWindow <= 40, "at most 40 requests in every 0.2 seconds")
  end
  T.ok(client.times[#client.times] - client.times[1] >= 2.3, "500 names are spread over more than 2 seconds")
  T.eq(client.changes, 1, "the names that the client had loaded meanwhile gave one change")
  T.eq({ loader:Progress() }, { 20, 501 }, "the progress before the answers")
  client.data[20000] = "Single"
  client.answerAll()
  net:Advance(0.1)
  T.eq(client.changes, 2, "many answers of one moment give one call of OnNamesChanged")
  T.eq({ loader:Progress() }, { 501, 501 }, "the progress after the answers")
  T.eq(loader:Name(10250), "Item 250", "the names are there")
  T.eq(client.listenCalls, 2, "the loader started and stopped listening once")

  -- Answers that trickle in: at most one call in half a second
  for index = 1, 10 do
    client.data[30000 + index] = "Late " .. index
    loader:Name(30000 + index)
  end
  net:Advance(1)
  local before = client.changes
  local start = net:Now()
  for index = 1, 10 do
    client.known[30000 + index] = client.data[30000 + index]
    loader:OnAnswer(30000 + index, true)
    net:Advance(0.1)
  end
  net:Advance(1)
  T.ok(client.changes - before <= math.floor((net:Now() - start) / 0.5) + 1, "OnNamesChanged at most twice a second")
  T.ok(client.changes - before >= 2, "and more than once for answers that are spread out")
end

-- Recipe facts
do
  local ns = T.load("Addon/Src/Professions/ProfessionRecipes.lua")
  local recipes = ns.professionRecipes
  local asked = 0
  local infos = {
    [18560] = { recipeID = 18560, name = "Mooncloth", icon = 132895, learned = false },
    [7421] = { recipeID = 7421, name = "Runed Copper Rod", icon = 135225 },
    [2330] = { recipeID = 0, name = "" },
    [500] = { recipeID = 500, name = SECRET },
    [501] = { recipeID = 501, name = "Secret reagent" },
    [502] = { recipeID = 502, name = "No schematic" },
  }
  local schematics = {
    [18560] = { outputItemID = 14342, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
      { quantityRequired = 2, reagents = { { itemID = 14256 } } },
      { quantityRequired = 1, reagents = { { itemID = 0 } } },
      { quantityRequired = 0, reagents = { { itemID = 7078 } } },
    } },
    [7421] = { quantityMin = 1, reagentSlotSchematics = {
      { quantityRequired = 1, reagents = { { itemID = 6217 }, { itemID = 1 } } },
      { quantityRequired = 4, reagents = { { itemID = 10940 } } },
    } },
    [501] = { outputItemID = 5, quantityMin = 3, reagentSlotSchematics = {
      { quantityRequired = SECRET, reagents = { { itemID = 6217 } } },
    } },
  }
  recipes.client = {
    info = function(recipeId)
      asked = asked + 1
      return infos[recipeId]
    end,
    schematic = function(recipeId)
      return schematics[recipeId]
    end,
  }
  T.eq(recipes.Facts(18560), { id = 18560, name = "Mooncloth", icon = 132895, itemId = 14342, count = 1,
    reagents = { { itemId = 14256, count = 2 } } }, "Facts of a recipe gives item, count, and reagents")
  T.eq(recipes.Facts(7421), { id = 7421, name = "Runed Copper Rod", icon = 135225, count = 1,
    reagents = { { itemId = 6217, count = 1 }, { itemId = 10940, count = 4 } } },
    "a recipe without an item has none, and the first item of a slot counts")
  asked = 0
  recipes.Facts(18560)
  T.eq(asked, 0, "the answer is kept for the session")
  T.eq(recipes.Facts(2330), nil, "Facts of an id that is no recipe gives nil")
  T.eq(recipes.Facts(999999), nil, "also when the client gives nothing")
  asked = 0
  recipes.Facts(2330)
  T.eq(asked, 0, "that answer is kept too")
  T.eq(recipes.Facts(500), nil, "a secret value of the recipe gives nil")
  T.eq(recipes.Facts(501), nil, "a secret value of a reagent gives nil")
  infos[500].name = "Readable"
  T.eq(recipes.Facts(500), { id = 500, name = "Readable", count = 1, reagents = {} },
    "an answer with a secret value was not kept")
  T.eq(recipes.Facts(502), { id = 502, name = "No schematic", count = 1, reagents = {} },
    "a recipe without a schematic has no reagents")
  infos[503] = SECRET
  T.eq(recipes.Facts(503), nil, "a secret answer gives nil")
end

T.finish()
