-- Host test of the whole life of a gambling event (.agents/00-plan.md, sections 15.1 to 15.6, step 14.5): an
-- officer opens it, members bet, the bookers of the officers book the bets, the officer locks and resolves it,
-- the receivers confirm their dues. The replicas run the real model and the real booker on the fake network, also
-- under 30% message loss, and must end equal. One case has a member who is offline from before the opening
-- until after the resolution.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local FILES = { "Addon/Src/Gamble/GambleData.lua", "Addon/Src/Gamble/GambleSettle.lua", "Addon/Src/Gamble/Gamble.lua",
  "Addon/Src/Gamble/GambleBook.lua" }
local TABLE, PLAYER_TABLE = "gamble", "gamble_player"
local HOUR = 3600
local STEP = 600
local NOTA_WINS = { true, false }

---@class LifeReplica: TestReplica
---@field model table The gambling model
---@field booker table|nil The booker while the replica is logged in
---@field source fun(m: integer?, n: integer?): number

---Returns the server time of a network as the addon sees it.
---@param net Fakenet
---@return integer
local function now(net)
  return math.floor(net:Now())
end

---Starts the booker of a replica.
---@param replica LifeReplica
local function startBooker(replica)
  replica.booker = replica.ns.gambleBook.new({
    sync = replica.sync,
    now = function()
      return now(replica.net)
    end,
    after = function(seconds, fn)
      return replica.endpoint:After(seconds, fn)
    end,
    random = replica.source,
  })
end

---Logs a replica in and starts its booker.
---@param replica LifeReplica
local function login(replica)
  replica:Login()
  startBooker(replica)
end

---Makes a replica with a model and a booker. It is logged in unless `offline` is set.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param source fun(m: integer?, n: integer?): number
---@param offline boolean?
---@return LifeReplica
local function make(net, name, rankIndex, source, offline)
  local replica = Replica.new(net, name, { random = source, rankIndex = rankIndex }) --[[@as LifeReplica]]
  replica.source = source
  T.loadAll(FILES, replica.ns)
  replica.model = replica.ns.gamble.new({
    sync = replica.sync,
    now = function()
      return now(net)
    end,
    playerName = function()
      return name
    end,
    sanitize = replica.ns.mentions.sanitize,
    random = source,
    isOfficer = function(other)
      return net.guild:IsOfficer(other)
    end,
  })
  if offline then
    net:SetOnline(name, false)
  else
    login(replica)
  end
  return replica
end

---Advances the clock in steps until `done` is true.
---@param net Fakenet
---@param done fun(): boolean
---@param limit integer Longest wait in seconds
---@return integer|nil elapsed Seconds waited; nil when the limit passed
local function waitFor(net, done, limit)
  local elapsed = 0
  while not done() do
    if elapsed >= limit then
      return nil
    end
    net:Advance(STEP)
    elapsed = elapsed + STEP
  end
  return elapsed
end

---Deep equality of plain tables.
---@param a any
---@param b any
---@return boolean
local function same(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---Keeps the fields of the dues of a result that every replica shares.
---@param result table|nil
---@return table[]|nil
local function sharedDues(result)
  if not result then
    return nil
  end
  local list = {}
  for index, due in ipairs(result.dues) do
    list[index] = { n = due.n, from = due.from, to = due.to, gold = due.gold, bank = due.bank,
      confirmed = due.confirmed }
  end
  return list
end

---Returns the book entries of an event on one replica: name -> entry, and their number.
---@param replica LifeReplica
---@param id string
---@return table<string, table> entries
---@return integer count
local function bookEntries(replica, id)
  local data = replica.ns.gambleData
  local entries, count = {}, 0
  for key, payload in replica.sync:Iterate(TABLE) do
    local parts = data.parseKey(TABLE, key)
    if parts and parts.kind == "book" and parts.eventId == id then
      entries[parts.name or key] = payload
      count = count + 1
    end
  end
  return entries, count
end

---@class LifeOptions
---@field seed integer? With a seed the network loses 30% of the messages
---@field offlineY boolean? Yara is offline from before the opening until after the resolution
---@field label string

---Runs the whole life of an event and checks it. Returns the longest fake time that each phase took.
---@param options LifeOptions
---@return table<string, integer> phases
local function life(options)
  local label = options.label .. ": "
  local source = options.seed and T.newRandom(options.seed) or T.newRandom()
  local lossy = options.seed ~= nil
  local net = Fakenet.new({ random = source, loss = lossy and 0.3 or 0 })
  local patience = lossy and 12 * HOUR or 2 * 60
  local phases = {}

  local o1 = make(net, "Officer One", 0, source)
  local o2 = make(net, "Officer Two", 1, source)
  local x = make(net, "Xavi Ash", nil, source)
  local y = make(net, "Yara Bell", nil, source, options.offlineY)
  local z = make(net, "Zed Cole", nil, source)
  ---@type LifeReplica[]
  local all = { o1, o2, x, y, z }
  ---@type LifeReplica[]
  local online = {}
  for _, replica in ipairs(all) do
    if not (options.offlineY and replica == y) then
      online[#online + 1] = replica
    end
  end
  local data = o1.ns.gambleData
  net:Advance(lossy and HOUR or 60)

  -- Opening
  local close = now(net) + (lossy and 12 or 2) * HOUR
  local id, reason = o1.model:Open({ title = "Who wins the duel?", outcomes = { { n = "Nota", p = 60 },
    { n = "Other", p = 40 } }, close = close, maxStake = 100 })
  T.ok(id, label .. "O1 opens the event")
  T.eq(reason, nil, label .. "without a reason")
  ---@cast id string
  local function holdingEvent(replica)
    return replica.model:Event(id) ~= nil
  end
  local function everyoneHolds()
    for _, replica in ipairs(online) do
      if not holdingEvent(replica) then
        return false
      end
    end
    return true
  end
  T.ok(waitFor(net, everyoneHolds, patience), label .. "every online replica holds the event")

  -- Bets
  local bettors = { { x, { [1] = 30 } }, { y, { [1] = 20 } }, { z, { [2] = 40 } } }
  local bettingTime = now(net)
  local active = {}
  for _, bettor in ipairs(bettors) do
    if not (options.offlineY and bettor[1] == y) then
      active[#active + 1] = bettor
      T.eq(bettor[1].model:PlaceBet(id, bettor[2]), true, label .. bettor[1].name .. " bets")
    end
  end
  local function allAccepted()
    for _, bettor in ipairs(active) do
      if bettor[1].model:BetState(id) ~= "accepted" then
        return false
      end
    end
    return true
  end
  local accepted = waitFor(net, allAccepted, patience)
  T.ok(accepted, label .. "every bet is accepted")
  phases.bets = accepted or patience
  T.ok(now(net) < close - (lossy and 6 * HOUR or HOUR), label .. "well before the close")
  T.ok(now(net) - bettingTime < 12 * HOUR, label .. "within the time of the opening")
  -- Every replica holds the same book, one entry per bet
  local function bookAgrees()
    local reference = bookEntries(o1, id)
    for _, replica in ipairs(online) do
      if not same(bookEntries(replica, id), reference) then
        return false
      end
    end
    return true
  end
  T.ok(waitFor(net, bookAgrees, patience), label .. "the book is equal everywhere")
  local reference = bookEntries(o1, id)
  for _, replica in ipairs(online) do
    local entries, count = bookEntries(replica, id)
    T.eq(count, #active, label .. replica.name .. " holds one book entry per bet")
    T.eq(entries, reference, label .. replica.name .. " holds the same entries as O1")
  end
  for _, bettor in ipairs(active) do
    local entry = reference[bettor[1].name]
    T.eq(entry and entry.g, bettor[2], label .. bettor[1].name .. "'s entry carries the stakes")
    T.eq(entry and entry.b, bettor[1].sync:GetId(PLAYER_TABLE, data.betKey(bettor[1].name, id)),
      label .. bettor[1].name .. "'s entry carries the id of the bet")
  end

  -- Lock
  T.eq(o1.model:Lock(id), true, label .. "O1 locks the event")
  local function lockSeen()
    local event = x.model:Event(id)
    return event ~= nil and event.c <= now(net)
  end
  local lockTime = waitFor(net, lockSeen, patience)
  T.ok(lockTime, label .. "X hears of the lock")
  T.eq({ x.model:PlaceBet(id, { [1] = 50 }) }, { nil, "closed" }, label .. "a bet after the lock is refused")

  -- Resolution
  T.eq(o1.model:Resolve(id, NOTA_WINS, "Officer Two"), true, label .. "O1 resolves, O2 is the banker")
  local function resolved()
    local expected = sharedDues(o1.model:Result(id))
    for _, replica in ipairs(online) do
      local result = replica.model:Result(id)
      if not result or result.state ~= "ready" or not same(sharedDues(result), expected) then
        return false
      end
    end
    return true
  end
  local resolveTime = waitFor(net, resolved, patience)
  T.ok(resolveTime, label .. "every online replica holds the resolution")
  phases.resolution = resolveTime or patience
  local expected = sharedDues(o1.model:Result(id))
  ---@cast expected table[]
  for _, replica in ipairs(online) do
    local result = replica.model:Result(id)
    T.eq({ result.state, result.results, result.banker }, { "ready", NOTA_WINS, "Officer Two" },
      label .. replica.name .. ": the result is ready")
    T.eq(sharedDues(result), expected, label .. replica.name .. ": the dues equal O1's")
  end
  local plain = {}
  for index, due in ipairs(expected) do
    plain[index] = { due.from, due.to, due.gold, due.bank }
  end
  if options.offlineY then
    -- X bet 30 on Nota, Z 40 on Other, Y nothing: Z pays X, and the bank takes its share
    T.ok(#expected >= 2, label .. "two bettors give a bank due and a due to X")
    local owed, bank = 0, 0
    for _, due in ipairs(expected) do
      T.eq(due.from, "Zed Cole", label .. "only Z pays")
      T.ok(due.to == "Xavi Ash" or due.to == "Officer Two", label .. "to X and the banker")
      if due.bank then
        bank = bank + due.gold
      else
        owed = owed + due.gold
      end
    end
    T.eq({ expected[1].bank, owed > 0, bank > 0 }, { true, true, true }, label .. "the bank due comes first")
    T.eq(x.model:Result(id).net, owed, label .. "X's net is what Z owes him")
    T.eq(z.model:Result(id).net, -(owed + bank), label .. "Z pays it and the bank share")
  else
    T.eq(plain, { { "Zed Cole", "Officer Two", 3, true }, { "Zed Cole", "Xavi Ash", 20, false },
      { "Zed Cole", "Yara Bell", 13, false } }, label .. "the dues are those of the example: X +20, Y +13, bank 3")
    T.eq({ x.model:Result(id).net, y.model:Result(id).net, z.model:Result(id).net, o2.model:Result(id).bankHeld },
      { 20, 13, -36, 3 }, label .. "the nets: X +20, Y +13, Z pays 36; the banker holds 3")
  end

  -- Y logs in after the resolution
  if options.offlineY then
    T.eq({ y.model:Event(id) }, { nil }, label .. "Y holds nothing while offline")
    login(y)
    online[#online + 1] = y
    local function yHolds()
      local result = y.model:Result(id)
      return result ~= nil and result.state == "ready" and same(sharedDues(result), expected)
    end
    T.ok(waitFor(net, yHolds, patience), label .. "Y holds the resolved event after login")
    T.ok(holdingEvent(y), label .. "Y holds the event")
    T.eq({ y.model:BetState(id) }, { "none" }, label .. "Y's bet state is none")
    local result = y.model:Result(id)
    T.eq({ result.ownDues, result.net, result.booked, result.inSettlement }, { {}, 0, false, false },
      label .. "Y has no own dues")
    T.eq(sharedDues(result), expected, label .. "Y shows the dues of the others")
  end

  -- Confirmations
  for _, due in ipairs(expected) do
    local receiver = ({ ["Officer Two"] = o2, ["Xavi Ash"] = x, ["Yara Bell"] = y })[due.to]
    T.eq(receiver.model:Confirm(id, due.n), true, label .. due.to .. " confirms due " .. due.n)
  end
  local function settledEverywhere()
    for _, replica in ipairs(online) do
      local result = replica.model:Result(id)
      if not result or not result.settled then
        return false
      end
    end
    return true
  end
  local function versionsEqual()
    for _, tableName in ipairs({ TABLE, PLAYER_TABLE }) do
      for _, replica in ipairs(online) do
        if replica:Version(tableName) ~= o1:Version(tableName) then
          return false
        end
      end
    end
    return true
  end
  local settleTime = waitFor(net, function()
    return settledEverywhere() and versionsEqual()
  end, patience)
  T.ok(settleTime, label .. "every receipt arrives and the tables agree")
  phases.confirmation = settleTime or patience
  for _, replica in ipairs(online) do
    local result = replica.model:Result(id)
    local groups = replica.model:Events()
    local doneIds = {}
    for index, entry in ipairs(groups.done) do
      doneIds[index] = entry.id
    end
    T.eq(result.settled, true, label .. replica.name .. ": settled")
    for _, due in ipairs(result.dues) do
      T.eq(due.confirmed, true, label .. replica.name .. ": due " .. due.n .. " is confirmed")
    end
    T.eq({ doneIds, #groups.toPay }, { { id }, 0 }, label .. replica.name .. ": the event is done")
    for _, tableName in ipairs({ TABLE, PLAYER_TABLE }) do
      T.eq(replica:Version(tableName), o1:Version(tableName), label .. replica.name .. ": version of " .. tableName)
    end
  end
  return phases
end

-- The base case: no loss
life({ label = "no loss" })

-- The same life under 30% loss
local worst = { bets = 0, resolution = 0, confirmation = 0 }
for seed = 1, 4 do
  local phases = life({ seed = seed, label = "seed " .. seed })
  for phase, seconds in pairs(phases) do
    worst[phase] = math.max(worst[phase], seconds)
  end
end
T.ok(worst.bets <= 12 * HOUR and worst.resolution <= 12 * HOUR and worst.confirmation <= 12 * HOUR,
  "under loss every phase ends within 12 hours of fake time")

-- A member who is offline from before the opening until after the resolution
life({ label = "offline Y", offlineY = true })

T.finish()
