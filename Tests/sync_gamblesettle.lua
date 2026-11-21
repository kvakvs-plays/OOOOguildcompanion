-- Host tests of the betting settlement (plan 15.5): pure arithmetic, no engine.
local T = dofile("Tests/harness.lua")
local ns = T.load("Addon/Src/Gamble/GambleSettle.lua")
local gs = ns.gambleSettle

local DUEL = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } }
local DUEL_BETS = { X = { [1] = 30 }, Y = { [1] = 20 }, Z = { [2] = 40 } }

---Sum of the values of a table
local function sum(t)
  local s = 0
  for _, v in pairs(t) do
    s = s + v
  end
  return s
end

-- The example of 15.5, both rows
do
  local s = gs.settle(DUEL, { true, false }, DUEL_BETS)
  T.eq(s.nets, { X = 20, Y = 13, Z = -36 }, "example, Nota wins: nets")
  T.eq(s.bank, 3, "example, Nota wins: bank")
  T.eq(s.won, { X = 20, Y = 13, Z = 0 }, "example, Nota wins: won")
  T.eq(s.paid, { X = 0, Y = 0, Z = 36 }, "example, Nota wins: paid")
  s = gs.settle(DUEL, { false, true }, DUEL_BETS)
  T.eq(s.nets, { X = -30, Y = -20, Z = 45 }, "example, Other wins: nets")
  T.eq(s.bank, 5, "example, Other wins: bank")
end

-- Claims
T.eq(gs.claim(30, { p = 60 }), 20, "claim 60%")
T.eq(gs.claim(30, { p = 10 }), 270, "claim 10%")
T.eq(gs.claim(30, { p = 10, x = 5 }), 150, "claim 10% capped at 5")
T.eq(gs.claim(5, { p = 2, x = 10 }), 50, "claim 2% capped at 10")
T.eq(gs.claim(5, { p = 2 }), 245, "claim 2% uncapped")
T.eq(gs.claim(5, { p = 19, x = 99 }), 5 * 81 / 19, "cap above the promise changes nothing")

-- No winners, no losers, nothing true, everything true: nothing is owed
do
  local s = gs.settle(DUEL, { false, false }, DUEL_BETS)
  T.eq(s.nets, { X = 0, Y = 0, Z = 0 }, "no winners: nets")
  T.eq(s.bank, 0, "no winners: bank")
  T.eq(gs.dues(s, "Boss"), {}, "no winners: no dues")
  s = gs.settle(DUEL, { true, true }, DUEL_BETS)
  T.eq(s.nets, { X = 0, Y = 0, Z = 0 }, "all true (no losers): nets")
  T.eq(s.bank, 0, "all true: bank")
  T.eq(gs.dues(s, "Boss"), {}, "all true: no dues")
  s = gs.settle(DUEL, { true, false }, { X = { [1] = 30 } })
  T.eq(s.nets, { X = 0 }, "no losers: nets")
  T.eq(s.bank, 0, "no losers: bank")
  s = gs.settle(DUEL, { true, false }, {})
  T.eq(s.nets, {}, "no bets: nets")
  T.eq(s.bank, 0, "no bets: bank")
end

-- A character with a winning and a losing stake gets one net
do
  -- X wins 20 on Nota (claim 20) and loses 10 on Other; Z loses 40 on Other
  local s = gs.settle(DUEL, { true, false }, { X = { [1] = 30, [2] = 10 }, Z = { [2] = 40 } })
  -- C = 20, L = 50, covered: W = 20, bank = 2, P = 22: X pays floor(10*22/50) = 4, Z floor(40*22/50) = 17, +1 to Z
  T.eq(s.won.X, 20, "mixed: X won")
  T.eq(s.paid.X, 4, "mixed: X paid")
  T.eq(s.nets.X, 16, "mixed: X net")
  T.eq(s.paid.Z, 18, "mixed: Z paid, leftover coin to the largest stake")
  T.eq(s.bank, 2, "mixed: bank")
  T.eq(s.nets.X + s.nets.Z + s.bank, 0, "mixed: balance")
end

-- A capped outcome: 5 gold on a 2% outcome with x = 10 claim 50
do
  local outcomes = { { n = "Sword", p = 2, x = 10 }, { n = "None", p = 98 } }
  local bets = { A = { [1] = 5 }, B = { [2] = 1000 } }
  local s = gs.settle(outcomes, { true, false }, bets)
  T.eq(s.won.A, 50, "capped: claim 50, not 245")
  T.eq(s.bank, 5, "capped: bank")
  T.eq(s.nets, { A = 50, B = -55 }, "capped: nets")
  -- Without the cap, the claim of 245 is also covered by 1000
  s = gs.settle({ { n = "Sword", p = 2 }, { n = "None", p = 98 } }, { true, false }, bets)
  T.eq(s.won.A, 245, "uncapped: claim 245")
  -- A cap above what the chance promises (p = 19 promises 4.26) changes nothing
  local capBets = { A = { [1] = 20 }, B = { [2] = 100 } }
  local plain = gs.settle({ { n = "A", p = 19 }, { n = "B", p = 81 } }, { true, false }, capBets)
  local capped = gs.settle({ { n = "A", p = 19, x = 50 }, { n = "B", p = 81 } }, { true, false }, capBets)
  T.eq(capped.nets, plain.nets, "cap above the promise: same nets")
  T.eq(capped.bank, plain.bank, "cap above the promise: same bank")
  -- Losers cannot cover: winners get a part (60% of 100 claim 66.6, L = 10)
  s = gs.settle({ { n = "A", p = 60 }, { n = "B", p = 40 } }, { true, false }, { A = { [1] = 150 }, B = { [2] = 10 } })
  T.eq(s.won.A, 9, "short losers: part of the claim (0.9 * 10)")
  T.eq(s.bank, 1, "short losers: bank")
  T.eq(s.nets.B, -10, "short losers: loser pays the stake at most")
end

-- Malformed stakes are skipped
do
  local bad = { X = { [1] = 30, [3] = 5, [2] = 0 }, Y = { [2] = 1.5 }, Z = { [2] = 10 } }
  local s = gs.settle(DUEL, { true, false }, bad)
  T.eq(s.nets.X, 9, "malformed: X wins 30 on Nota, limited by Z's 10 (0.9 * 10)")
  T.ok(s.nets.Y == nil, "malformed: a bettor with only invalid stakes is absent")
  T.eq(s.L, 10, "malformed: only Z's stake loses")
end

-- 500 random events
local random = T.newRandom()
local EVENTS = 500

---Builds a random event: outcomes, results, and bets
local function randomEvent()
  local outcomes = {}
  for i = 1, random(2, 8) do
    local p = random(1, 99)
    outcomes[i] = { n = "O" .. i, p = p, x = (p < 20 and random(1, 3) == 1) and random(1, 99) or nil }
  end
  local results = {}
  for i = 1, #outcomes do
    results[i] = random(1, 2) == 1
  end
  local names = {}
  for i = 1, random(1, 12) do
    names[i] = "Player" .. i
  end
  local bets = {}
  for _, name in ipairs(names) do
    local byOutcome = {}
    for _ = 1, random(1, 3) do
      byOutcome[random(1, #outcomes)] = random(1, 100)
    end
    bets[name] = byOutcome
  end
  return outcomes, results, bets, names
end

---Copies the bets with the names inserted in another order and the outcomes in reverse
local function rebuildBets(bets, names, outcomeCount)
  local copy = {}
  for i = #names, 1, -1 do
    local byOutcome = {}
    for o = outcomeCount, 1, -1 do
      byOutcome[o] = bets[names[i]][o]
    end
    copy[names[i]] = byOutcome
  end
  return copy
end

for _ = 1, EVENTS do
  local outcomes, results, bets, names = randomEvent()
  local s = gs.settle(outcomes, results, bets)
  local banker = names[random(1, #names)]

  -- Nets and bank add up to 0, and every bettor is present
  T.eq(sum(s.nets) + s.bank, 0, "random: nets and bank add up to 0")
  for _, name in ipairs(names) do
    T.ok(s.nets[name] ~= nil, "random: every bettor has a net")
  end

  -- No loser pays more than the stake (per stake and per character); no winner gets more than the claim
  local stakeOf = {}
  for _, loss in ipairs(s.losses) do
    T.ok(loss.gold >= 0 and loss.gold <= loss.stake, "random: a losing stake pays at most itself")
    stakeOf[loss.name] = (stakeOf[loss.name] or 0) + loss.stake
  end
  for name, total in pairs(stakeOf) do
    T.ok(s.paid[name] <= total, "random: a character pays at most its losing stakes")
  end
  for _, win in ipairs(s.wins) do
    T.ok(win.gold >= 0 and win.gold <= win.claim + 1e-9, "random: a winner gets at most the claim")
  end

  -- The bank is floor(W / 9) and the losers pay P = W + bank, so P - 10 * bank = W - 9 * floor(W / 9), which
  -- lies in 0 .. 8 (when L or C is 0, everything is 0). Hence the bank is a tenth of P, less than 9/10 coin off.
  local payments = sum(s.paid)
  T.eq(payments, s.W + s.bank, "random: losers pay winnings plus bank")
  T.ok(payments - 10 * s.bank >= 0 and payments - 10 * s.bank < 9, "random: bank is a tenth of the payments")

  -- Equal input gives equal output, whatever the insertion order
  local again = gs.settle(outcomes, results, rebuildBets(bets, names, #outcomes))
  T.eq(again, s, "random: insertion order does not matter")

  -- The dues add up to the nets: bank dues count for the bank, not for the banker's net
  local dues = gs.dues(s, banker)
  local back, bank = {}, 0
  for name in pairs(s.nets) do
    back[name] = 0
  end
  for _, due in ipairs(dues) do
    T.ok(due.g >= 1, "random: a due is at least 1")
    back[due.f] = back[due.f] - due.g
    if due.k then
      bank = bank + due.g
      T.eq(due.t, banker, "random: a bank due goes to the banker")
    else
      back[due.t] = back[due.t] + due.g
      T.ok(not (due.f == banker and due.t == banker), "random: no due of the banker to the banker, except the bank")
    end
  end
  T.eq(back, s.nets, "random: dues add up to the nets")
  T.eq(bank, s.bank, "random: bank dues add up to the bank")
  T.ok(#dues <= #names + 1, "random: no more dues than bettors plus one")
  T.eq(gs.dues(s, banker), dues, "random: dues are repeatable")
end

-- Bank dues come from the largest losers
do
  local outcomes = { { n = "A", p = 50 }, { n = "B", p = 50 } }
  local bets = { W = { [1] = 100 }, L1 = { [2] = 30 }, L2 = { [2] = 50 }, L3 = { [2] = 20 } }
  local s = gs.settle(outcomes, { true, false }, bets)
  -- claim 100, L = 100, covered by 90 only: W = 90, bank = 10, P = 100: everyone pays the whole stake
  T.eq(s.won.W, 90, "dues: winner gets 90")
  T.eq(s.bank, 10, "dues: bank 10")
  local dues = gs.dues(s, "Boss")
  T.eq(dues, {
    { f = "L2", t = "Boss", g = 10, k = true },
    { f = "L2", t = "W", g = 40 },
    { f = "L1", t = "W", g = 30 },
    { f = "L3", t = "W", g = 20 },
  }, "dues: the bank share comes from the largest loser, then the winners are paid")
end

-- A banker who is the largest loser pays the bank due to the own name
do
  local outcomes = { { n = "A", p = 50 }, { n = "B", p = 50 } }
  local bets = { W = { [1] = 100 }, Boss = { [2] = 60 }, L2 = { [2] = 40 } }
  local s = gs.settle(outcomes, { true, false }, bets)
  local dues = gs.dues(s, "Boss")
  T.eq(dues[1], { f = "Boss", t = "Boss", g = 10, k = true }, "banker as largest loser: due to the own name")
  T.eq(dues[2], { f = "Boss", t = "W", g = 50 }, "banker as largest loser: rest goes to the winner")
  T.eq(#dues, 3, "banker as largest loser: three dues")
end

T.finish()
