local addonName, ns = ...

-- Settlement of a betting event (plan 15.5): pure arithmetic on plain tables. No WoW API, no engine, so the host
-- tests cover all of it. Gold is whole coins; every fraction is rounded down, and the leftover is dealt out.

---One outcome of an event (15.3).
---@class GambleOutcome
---@field n string Name of the outcome
---@field p integer Chance in whole percent, 1 to 99
---@field x integer? Cap: the highest profit of a winning stake as a multiple of the stake

---A stake on one outcome, as the settlement sees it.
---@class GambleStake
---@field name string Character that placed it
---@field o integer Index of the outcome
---@field stake integer Gold staked
---@field claim number? Profit that the chance promises (winning stakes only)
---@field gold integer Winnings, or payment, in whole gold after the settlement

---The outcome of `settle`.
---@class GambleSettlement
---@field nets table<string, integer> Winnings minus payments per bettor; every valid bettor is present, 0 allowed
---@field won table<string, integer> Winnings per bettor
---@field paid table<string, integer> Payments per bettor
---@field bank integer Gold for the guild bank
---@field wins GambleStake[] The winning stakes, ordered by name and outcome
---@field losses GambleStake[] The losing stakes, ordered by name and outcome
---@field L integer Sum of the losing stakes
---@field C number Sum of the claims
---@field W integer Sum of the winnings

---One payment between two characters (15.5, "Dues").
---@class GambleDue
---@field f string Payer
---@field t string Receiver; the banker for a bank due
---@field g integer Gold, at least 1
---@field k true? Set when the gold is the bank's share

---@class GambleSettleModule
local gambleSettle = {}
ns.gambleSettle = gambleSettle

---Share of the losers' payments that goes to the guild bank, in percent.
gambleSettle.BANK_SHARE = 10

---Tolerance that keeps a float product of an exact integer case from falling below its integer before flooring.
local EPSILON = 1e-9

---Rounds down, treating a value within EPSILON below a whole number as that number.
---@param value number
---@return integer
local function floorExact(value)
  return math.floor(value + EPSILON)
end

---Tells a positive whole number.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value > 0 and value == math.floor(value)
end

---The profit that a winning stake claims: what the chance promises, `stake * (100 - p) / p`, and with a cap at
---most `stake * x`. The result is a fraction; rounding happens in `settle`.
---@param stake number
---@param outcome GambleOutcome
---@return number
function gambleSettle.claim(stake, outcome)
  local claim = stake * (100 - outcome.p) / outcome.p
  if outcome.x and stake * outcome.x < claim then
    claim = stake * outcome.x
  end
  return claim
end

---Orders stakes by name, then by outcome index: a total order, whatever the iteration order of the input.
---@param a GambleStake
---@param b GambleStake
---@return boolean
local function byNameThenOutcome(a, b)
  if a.name ~= b.name then
    return a.name < b.name
  end
  return a.o < b.o
end

---Orders stakes largest first, ties by name and then by outcome index.
---@param a GambleStake
---@param b GambleStake
---@return boolean
local function byStakeDesc(a, b)
  if a.stake ~= b.stake then
    return a.stake > b.stake
  end
  return byNameThenOutcome(a, b)
end

---Settles an event: who wins what, who pays what, and the bank's share (15.5, steps 1 to 7).
---Stakes on an outcome that does not exist, or that are not positive whole numbers, are skipped.
---@param outcomes GambleOutcome[] The outcomes of the event
---@param results boolean[] True per outcome that came true
---@param bets table<string, table<integer, integer>> Character name -> outcome index -> gold
---@return GambleSettlement
function gambleSettle.settle(outcomes, results, bets)
  local share = gambleSettle.BANK_SHARE
  local nets, won, paid = {}, {}, {}
  local wins, losses = {}, {}
  local L, C = 0, 0

  -- Steps 1 to 3: sort the stakes into winning and losing, in an order that does not depend on `pairs`
  local names = {}
  for name in pairs(bets) do
    if type(name) == "string" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local byOutcome = bets[name]
    if type(byOutcome) == "table" then
      for o, stake in pairs(byOutcome) do
        local outcome = type(o) == "number" and outcomes[o]
        if outcome and o == math.floor(o) and isPositiveInteger(stake) then
          nets[name], won[name], paid[name] = 0, 0, 0
          if results[o] == true then
            local claim = gambleSettle.claim(stake, outcome)
            wins[#wins + 1] = { name = name, o = o, stake = stake, claim = claim, gold = 0 }
          else
            losses[#losses + 1] = { name = name, o = o, stake = stake, gold = 0 }
            L = L + stake
          end
        end
      end
    end
  end
  table.sort(wins, byNameThenOutcome)
  table.sort(losses, byNameThenOutcome)
  -- Summed after the sort: float addition depends on the order
  for _, win in ipairs(wins) do
    C = C + win.claim
  end

  local settlement = {
    nets = nets, won = won, paid = paid, bank = 0, wins = wins, losses = losses, L = L, C = C, W = 0,
  }
  if L == 0 or C <= 0 then
    return settlement
  end

  -- Step 4: full claims when the losers cover them after the bank's share, the same part of each claim otherwise.
  -- The multiplication comes before the division, so exact integer cases stay exact.
  local covered = C * 100 <= L * (100 - share)
  local W = 0
  for _, win in ipairs(wins) do
    if covered then
      win.gold = floorExact(win.claim)
    else
      win.gold = floorExact(win.claim * (100 - share) * L / (100 * C))
    end
    W = W + win.gold
    won[win.name] = won[win.name] + win.gold
  end
  settlement.W = W

  -- Step 5: the bank gets a tenth of what the losers pay
  local bank = math.floor(W * share / (100 - share))
  local total = W + bank

  -- Step 6: each losing stake pays its part, rounded down; the leftover goes one coin at a time to the largest
  -- stakes. A stake never pays more than itself.
  local sum = 0
  for _, loss in ipairs(losses) do
    loss.gold = math.floor(loss.stake * total / L)
    sum = sum + loss.gold
  end
  local order = {}
  for i, loss in ipairs(losses) do
    order[i] = loss
  end
  table.sort(order, byStakeDesc)
  local progress = true
  while sum < total and progress do
    progress = false
    for _, loss in ipairs(order) do
      if sum < total and loss.gold < loss.stake then
        loss.gold = loss.gold + 1
        sum = sum + 1
        progress = true
      end
    end
  end
  -- The losers cannot pay more than they staked; with the shares above this does not happen, but the books
  -- must balance in any case, so the bank takes what was really paid beyond the winnings.
  bank = sum - W

  -- Step 7: the nets
  for _, loss in ipairs(losses) do
    paid[loss.name] = paid[loss.name] + loss.gold
  end
  for name in pairs(nets) do
    nets[name] = won[name] - paid[name]
  end
  settlement.bank = bank
  return settlement
end

---Orders character names by an amount, largest first, ties by name.
---@param amounts table<string, integer>
---@return string[]
local function namesByAmount(amounts)
  local names = {}
  for name in pairs(amounts) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    if amounts[a] ~= amounts[b] then
      return amounts[a] > amounts[b]
    end
    return a < b
  end)
  return names
end

---Turns the nets of a settlement into payments (15.5, "Dues"). Receivers: the bank first (received by the banker,
---flagged `k`), then the winners, largest first. Payers: the losers, largest payment first. The first payer pays
---the first receiver as much as both allow, and whoever is done leaves the list. A banker who has to pay the bank
---share is named on both sides.
---@param settlement GambleSettlement
---@param banker string Character that receives the bank share
---@return GambleDue[]
function gambleSettle.dues(settlement, banker)
  local gains, debts = {}, {}
  for name, net in pairs(settlement.nets) do
    if net > 0 then
      gains[name] = net
    elseif net < 0 then
      debts[name] = -net
    end
  end

  ---@type { name: string, left: integer, k: true? }[]
  local receivers = {}
  if settlement.bank > 0 then
    receivers[1] = { name = banker, left = settlement.bank, k = true }
  end
  for _, name in ipairs(namesByAmount(gains)) do
    receivers[#receivers + 1] = { name = name, left = gains[name] }
  end
  local payers = {}
  for _, name in ipairs(namesByAmount(debts)) do
    payers[#payers + 1] = { name = name, left = debts[name] }
  end

  local dues = {}
  local r, p = 1, 1
  while receivers[r] and payers[p] do
    local receiver, payer = receivers[r], payers[p]
    local gold = math.min(receiver.left, payer.left)
    -- A banker's own winnings and payments are one net, so a banker never pays the banker a non-bank amount
    dues[#dues + 1] = { f = payer.name, t = receiver.name, g = gold, k = receiver.k }
    receiver.left = receiver.left - gold
    payer.left = payer.left - gold
    if receiver.left == 0 then
      r = r + 1
    end
    if payer.left == 0 then
      p = p + 1
    end
  end
  return dues
end
