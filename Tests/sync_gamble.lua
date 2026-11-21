-- Host test of the gambling model (.agents/00-plan.md, sections 15.3 and 15.4, step 14.3;
-- Addon/Src/Gamble/Gamble.lua): opening, locking, and cancelling events, placing and taking back bets, and the
-- reading of the events, of one event, and of the state of the own bet. There is no booking code yet: where a
-- test needs a book entry, the officer replica writes it by hand.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Gamble/GambleData.lua", "Addon/Src/Gamble/Gamble.lua" }
local OFFICER_RANK = 0
local TABLE, PLAYER_TABLE = "gamble", "gamble_player"
local HOUR = 3600

---@class GambleTestReplica: TestReplica
---@field model table The gambling model of this replica

---Makes a replica that has the gambling tables and a gambling model, and logs it in.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return GambleTestReplica
local function withGamble(net, name, rankIndex)
  local replica = Replica.new(net, name, { random = random, rankIndex = rankIndex }) --[[@as GambleTestReplica]]
  T.loadAll(FILES, replica.ns)
  replica.model = replica.ns.gamble.new({
    sync = replica.sync,
    now = function()
      return math.floor(net:Now())
    end,
    playerName = function()
      return name
    end,
    sanitize = replica.ns.mentions.sanitize,
  })
  replica:Login()
  return replica
end

---Returns the server time of a network as the model sees it.
---@param net Fakenet
---@return integer
local function now(net)
  return math.floor(net:Now())
end

---Returns a valid spec of an event that closes `ahead` seconds from now.
---@param net Fakenet
---@param ahead integer?
---@return table
local function spec(net, ahead)
  return { title = "Who wins the duel on Friday?", outcomes = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } },
    close = now(net) + (ahead or HOUR), maxStake = 100 }
end

---Lets the replicas exchange their changes.
---@param net Fakenet
local function exchange(net)
  net:Advance(60)
end

---Returns the ids of a group of `Events()`.
---@param group { id: string }[]
---@return string[]
local function ids(group)
  local result = {}
  for index, entry in ipairs(group) do
    result[index] = entry.id
  end
  return result
end

local net = Fakenet.new({ random = random })
local officer = withGamble(net, "Officer One", OFFICER_RANK)
local member = withGamble(net, "Nota Scam")
local other = withGamble(net, "Other One")
exchange(net)
local data = officer.ns.gambleData

-- The checkpoint: an officer opens an event, a member sees it and bets
local checkpoint
do
  local id, reason = officer.model:Open(spec(net))
  T.ok(id, "an officer opens an event")
  T.eq(reason, nil, "without a reason")
  checkpoint = id
  local stored = officer.sync:Get(TABLE, data.eventKey(id))
  T.eq(stored, { n = "Who wins the duel on Friday?", o = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } },
    c = now(net) + HOUR, m = 100, s = 1, by = "Officer One" }, "the event is written as given")
  T.eq(member.model:Event(id), nil, "the member does not hold it yet")
  exchange(net)
  T.eq(ids(member.model:Events().open), { id }, "the member sees the open event")
  T.eq(member.model:PlaceBet(id, { [1] = 30 }), true, "and bets")
  T.eq(member.sync:Get(PLAYER_TABLE, data.betKey("Nota Scam", id)), { g = { [1] = 30 } }, "the bet is written")
end

-- Open: only an officer, with a good spec
do
  local count = 0
  for _ in officer.sync:Iterate(TABLE) do
    count = count + 1
  end
  T.eq({ member.model:Open(spec(net)) }, { nil, "not an officer" }, "a member cannot open an event")

  ---Checks that a change of a good spec is refused with a reason.
  ---@param name string
  ---@param reason string
  ---@param change fun(s: table)
  local function refused(name, reason, change)
    local s = spec(net)
    change(s)
    T.eq({ officer.model:Open(s) }, { nil, reason }, name .. " is refused")
  end
  refused("a spec without a title", "bad title", function(s) s.title = nil end)
  refused("an empty title", "bad title", function(s) s.title = "" end)
  refused("a title of 81 bytes", "bad title", function(s) s.title = string.rep("t", 81) end)
  refused("one outcome", "bad outcomes", function(s) s.outcomes = { { n = "A", p = 50 } } end)
  refused("nine outcomes", "bad outcomes", function(s)
    for index = 1, 9 do
      s.outcomes[index] = { n = "o" .. index, p = 10 }
    end
  end)
  refused("no outcomes", "bad outcomes", function(s) s.outcomes = nil end)
  refused("a chance of 0", "bad outcome", function(s) s.outcomes[1].p = 0 end)
  refused("a chance of 100", "bad outcome", function(s) s.outcomes[1].p = 100 end)
  refused("a fractional chance", "bad outcome", function(s) s.outcomes[1].p = 50.5 end)
  refused("an outcome without a name", "bad outcome", function(s) s.outcomes[2].n = "" end)
  refused("an outcome name of 41 bytes", "bad outcome", function(s) s.outcomes[2].n = string.rep("n", 41) end)
  refused("a cap on a chance of 20", "bad cap", function(s) s.outcomes[2] = { n = "B", p = 20, x = 5 } end)
  refused("a cap of 0", "bad cap", function(s) s.outcomes[2] = { n = "B", p = 2, x = 0 } end)
  refused("a cap of 100", "bad cap", function(s) s.outcomes[2] = { n = "B", p = 2, x = 100 } end)
  refused("a close now", "bad close", function(s) s.close = now(net) end)
  refused("a close in the past", "bad close", function(s) s.close = now(net) - 10 end)
  refused("a close over 30 days ahead", "bad close", function(s) s.close = now(net) + 30 * 86400 + 1 end)
  refused("a fractional close", "bad close", function(s) s.close = now(net) + 10.5 end)
  refused("a highest stake of 0", "bad stake", function(s) s.maxStake = 0 end)
  refused("a highest stake over the limit", "bad stake", function(s) s.maxStake = data.MAX_GOLD + 1 end)
  T.eq({ officer.model:Open("spec") }, { nil, "bad spec" }, "a spec that is no table is refused")
  local after = 0
  for _ in officer.sync:Iterate(TABLE) do
    after = after + 1
  end
  T.eq(after, count, "no refused spec wrote a record")

  local s = spec(net, 30 * 86400)
  s.outcomes[2] = { n = "Sword", p = 2, x = 10 }
  local id = officer.model:Open(s)
  T.ok(id, "a capped outcome and a close 30 days ahead are accepted")
  T.eq(officer.model:Event(id).o[2], { n = "Sword", p = 2, x = 10 }, "with the cap")
  T.ok(id > checkpoint, "a later event has a greater id")
  T.ok(officer.ns.versionId.isWellFormed(id), "the event id is a version id")
end

-- Bets: placing, changing, taking back, and the refusals
do
  local id = officer.model:Open(spec(net))
  exchange(net)
  local model = member.model
  local betKey = data.betKey("Nota Scam", id)

  ---Returns the stored bet of the member.
  ---@return table|nil
  local function bet()
    return member.sync:Get(PLAYER_TABLE, betKey)
  end

  T.eq(model:PlaceBet(id, { [1] = 30 }), true, "a bet before the close is written")
  T.eq(bet(), { g = { [1] = 30 } }, "with its stake")
  T.eq(model:PlaceBet(id, { [2] = 100 }), true, "a stake on another outcome, up to m")
  T.eq(bet(), { g = { [1] = 30, [2] = 100 } }, "is added to the bet")
  T.eq(model:PlaceBet(id, { [1] = 0 }), true, "a stake of 0")
  T.eq(bet(), { g = { [2] = 100 } }, "removes its outcome")
  T.eq(model:PlaceBet(id, { [2] = 100 }), true, "the same bet again is no error")

  T.eq({ model:PlaceBet(id, { [1] = 101 }) }, { nil, "stake too high" }, "a stake over m is refused")
  T.eq({ model:PlaceBet(id, { [1] = data.MAX_GOLD + 1 }) }, { nil, "bad stake" }, "a stake over the limit")
  T.eq({ model:PlaceBet(id, { [1] = 2.5 }) }, { nil, "bad stake" }, "a fractional stake")
  T.eq({ model:PlaceBet(id, { [1] = -5 }) }, { nil, "bad stake" }, "a negative stake")
  T.eq({ model:PlaceBet(id, { [1] = "5" }) }, { nil, "bad stake" }, "a stake that is a string")
  T.eq({ model:PlaceBet(id, { [1] = 0 / 0 }) }, { nil, "bad stake" }, "a stake that is NaN")
  T.eq({ model:PlaceBet(id, { [3] = 5 }) }, { nil, "bad outcome" }, "an outcome that the event lacks")
  T.eq({ model:PlaceBet(id, { [0] = 5 }) }, { nil, "bad outcome" }, "outcome 0")
  T.eq({ model:PlaceBet(id, { a = 5 }) }, { nil, "bad outcome" }, "an outcome that is a name")
  T.eq({ model:PlaceBet(id, { [1] = 5, [2] = 101 }) }, { nil, "stake too high" }, "one stake too high refuses all")
  T.eq({ model:PlaceBet(id, 5) }, { nil, "bad stakes" }, "stakes that are no table")
  T.eq({ model:PlaceBet("no such id", { [1] = 5 }) }, { nil, "unknown event" }, "an unknown event")
  T.eq({ model:PlaceBet(nil, { [1] = 5 }) }, { nil, "unknown event" }, "no event id")
  T.eq(bet(), { g = { [2] = 100 } }, "no refused bet changed the record")

  T.eq(model:PlaceBet(id, { [2] = 0 }), true, "no stake left")
  T.eq(bet(), nil, "takes the bet back")
  T.eq({ model:PlaceBet(id, { [1] = 0 }) }, { nil, "no bet" }, "no stake and no bet held")
  T.eq(model:PlaceBet(id, { [1] = 1 }), true, "a stake of 1")
  T.eq(model:TakeBack(id), true, "is taken back")
  T.eq(bet(), nil, "and the record is deleted")
  T.eq({ model:TakeBack(id) }, { nil, "no bet" }, "a second take back finds no bet")
  T.eq({ model:TakeBack("no such id") }, { nil, "unknown event" }, "a take back of an unknown event")

  -- After the close
  T.eq(model:PlaceBet(id, { [1] = 20 }), true, "a bet shortly before the close")
  net:Advance(HOUR)
  T.eq({ model:PlaceBet(id, { [1] = 30 }) }, { nil, "closed" }, "a bet after the close is refused")
  T.eq({ model:PlaceBet(id, { [1] = 0 }) }, { nil, "closed" }, "also a stake of 0")
  T.eq({ model:TakeBack(id) }, { nil, "closed" }, "and a take back")
  T.eq(bet(), { g = { [1] = 20 } }, "the bet stays as it was")

  -- On a cancelled event
  local cancelled = officer.model:Open(spec(net))
  exchange(net)
  T.eq(model:PlaceBet(cancelled, { [1] = 10 }), true, "a bet on an event that is cancelled later")
  T.eq(officer.model:Cancel(cancelled), true, "the officer cancels it")
  exchange(net)
  T.eq({ model:PlaceBet(cancelled, { [1] = 20 }) }, { nil, "cancelled" }, "a bet on a cancelled event is refused")
  T.eq({ model:TakeBack(cancelled) }, { nil, "cancelled" }, "and a take back")
  T.eq(member.sync:Get(PLAYER_TABLE, data.betKey("Nota Scam", cancelled)), { g = { [1] = 10 } }, "the bet stays")

  -- On a resolved event (written by hand: the resolution comes in a later step)
  local resolved = officer.model:Open(spec(net))
  local event = officer.model:Event(resolved)
  officer.sync:Put(TABLE, data.eventKey(resolved), { n = event.n, o = event.o, c = event.c, m = event.m, s = 2,
    by = event.by, r = { true, false }, q = "aB3$", d = 0, k = "Officer One" })
  exchange(net)
  T.eq({ model:PlaceBet(resolved, { [1] = 20 }) }, { nil, "resolved" }, "a bet on a resolved event is refused")

  -- An own name that is not known yet
  local unnamed = member.ns.gamble.new({ sync = member.sync, now = function() return now(net) end,
    playerName = function() return nil end, sanitize = member.ns.mentions.sanitize })
  T.eq({ unnamed:PlaceBet(resolved, { [1] = 1 }) }, { nil, "not ready" }, "a bet without the own name")
end

-- Lock and cancel: only an officer; a lock moves the close to now and never later
do
  local id = officer.model:Open(spec(net))
  exchange(net)
  local key = data.eventKey(id)
  local before = member.sync:Get(TABLE, key)
  T.eq({ member.model:Lock(id) }, { nil, "not an officer" }, "a member cannot lock")
  T.eq({ member.model:Cancel(id) }, { nil, "not an officer" }, "a member cannot cancel")
  T.eq(member.sync:Get(TABLE, key), before, "the event is unchanged")
  T.eq({ officer.model:Lock("no such id") }, { nil, "unknown event" }, "an unknown event cannot be locked")
  T.eq({ officer.model:Cancel("no such id") }, { nil, "unknown event" }, "nor cancelled")

  net:Advance(100)
  local lockedAt = now(net)
  T.eq(officer.model:Lock(id), true, "an officer locks an open event")
  local locked = officer.sync:Get(TABLE, key)
  T.eq(locked.c, lockedAt, "the lock moves the close to now")
  T.eq({ locked.n, locked.m, locked.s, locked.by, #locked.o }, { before.n, before.m, 1, before.by, 2 },
    "and keeps the other fields")
  net:Advance(100)
  T.eq({ officer.model:Lock(id) }, { nil, "closed" }, "a locked event cannot be locked again")
  T.eq(officer.sync:Get(TABLE, key).c, lockedAt, "the close does not move later")
  exchange(net)
  T.eq(member.sync:Get(TABLE, key).c, lockedAt, "the member gets the new close")

  local closed = officer.model:Open(spec(net, 60))
  local close = officer.model:Event(closed).c
  net:Advance(120)
  T.eq({ officer.model:Lock(closed) }, { nil, "closed" }, "an event after its close cannot be locked")
  T.eq(officer.model:Event(closed).c, close, "and its close stays")

  T.eq(officer.model:Cancel(id), true, "a locked event can be cancelled")
  local cancelled = officer.sync:Get(TABLE, key)
  T.eq({ cancelled.s, cancelled.c, cancelled.n }, { 3, lockedAt, before.n }, "the cancel keeps the other fields")
  T.eq({ officer.model:Cancel(id) }, { nil, "cancelled" }, "a cancelled event cannot be cancelled again")
  T.eq({ officer.model:Lock(id) }, { nil, "cancelled" }, "nor locked")
  T.eq(officer.model:Cancel(officer.model:Open(spec(net))), true, "an open event can be cancelled")
  T.eq(officer.model:Cancel(checkpoint), true, "an event after its close can be cancelled")

  local resolved = officer.model:Open(spec(net))
  local event = officer.model:Event(resolved)
  local resolution = { n = event.n, o = event.o, c = event.c, m = event.m, s = 2, by = event.by,
    r = { true, false }, q = "aB3$", d = 3, k = "Officer One" }
  officer.sync:Put(TABLE, data.eventKey(resolved), resolution)
  T.eq({ officer.model:Lock(resolved) }, { nil, "resolved" }, "a resolved event cannot be locked")
  T.eq(officer.model:Cancel(resolved), true, "a resolved event can be cancelled")
  resolution.s = 3
  T.eq(officer.sync:Get(TABLE, data.eventKey(resolved)), resolution, "and keeps its resolution")
end

-- The groups of Events() and their order
do
  local groupNet = Fakenet.new({ random = random })
  local boss = withGamble(groupNet, "Officer One", OFFICER_RANK)
  local reader = withGamble(groupNet, "Nota Scam")
  groupNet:Advance(100)
  local model = boss.model

  ---Opens an event and lets one second pass, so that the ids differ by time too.
  ---@param ahead integer?
  ---@return string
  local function open(ahead)
    local id = model:Open(spec(groupNet, ahead))
    groupNet:Advance(1)
    return id
  end
  local openOld, closing, lockedId, resolved, cancelled, openNew = open(), open(30), open(), open(), open(), open()
  model:Lock(lockedId)
  local event = model:Event(resolved)
  boss.sync:Put(TABLE, data.eventKey(resolved), { n = event.n, o = event.o, c = event.c, m = event.m, s = 2,
    by = event.by, r = { false, true }, q = "zz!!", d = 0, k = "Officer One" })
  model:Cancel(cancelled)
  -- Records of the book and the dues are no events
  boss.sync:Put(TABLE, data.bookKey(openNew, "Nota Scam"), { g = { [1] = 5 }, b = openNew, t = now(groupNet) })
  boss.sync:Put(TABLE, data.dueKey(resolved, 1), { q = "zz!!", f = "Nota Scam", t = "Officer One", g = 5 })

  local groups = model:Events()
  T.eq(ids(groups.open), { openNew, closing, openOld }, "open: open and before the close, newest first")
  T.eq(ids(groups.waiting), { lockedId }, "waiting: locked")
  T.eq(ids(groups.toPay), { resolved }, "toPay: resolved")
  T.eq(ids(groups.done), { cancelled }, "done: cancelled")
  T.eq(groups.open[1].event, model:Event(openNew), "an entry carries the event")

  groupNet:Advance(60)
  groups = model:Events()
  T.eq(ids(groups.open), { openNew, openOld }, "an event moves from open")
  T.eq(ids(groups.waiting), { lockedId, closing }, "to waiting at its close, newest first")
  groups = reader.model:Events()
  T.eq({ ids(groups.open), ids(groups.waiting), ids(groups.toPay), ids(groups.done) },
    { { openNew, openOld }, { lockedId, closing }, { resolved }, { cancelled } }, "a member sees the same groups")
  local empty = withGamble(Fakenet.new({ random = random }), "Lonely One", OFFICER_RANK).model:Events()
  T.eq(empty, { open = {}, waiting = {}, toPay = {}, done = {} }, "no events give four empty groups")
end

-- Texts with `|` are made harmless; the booked sums are hidden while bets are taken
do
  local s = spec(net)
  s.title = "Win |TInterface\\Icons\\INV_Misc_QuestionMark:0|t now|"
  s.outcomes[1].n = "A|nB"
  s.outcomes[2] = { n = "|cffff0000Red", p = 5, x = 3 }
  local id = officer.model:Open(s)
  -- An opener name with `|` (written by hand: the own name of the model has none)
  local event = officer.model:Event(id)
  officer.sync:Put(TABLE, data.eventKey(id), { n = event.n, o = event.o, c = event.c, m = event.m, s = 1,
    by = "Bad|Hname" })
  exchange(net)
  T.eq(member.model:PlaceBet(id, { [1] = 30, [2] = 7 }), true, "the member bets")

  local detail = member.model:Detail(id)
  local sanitize = member.ns.mentions.sanitize
  T.eq(detail.title, "Win ||TInterface\\Icons\\INV_Misc_QuestionMark:0||t now||",
    "a texture in the title is shown as text")
  T.eq(detail.outcomes[1].n, "A||nB", "a line break in an outcome name")
  T.eq(detail.outcomes[2].n, "|cffff0000Red|r", "an open colour is closed")
  T.eq(detail.by, sanitize("Bad|Hname"), "the opener")
  T.eq(detail.by, "Bad||Hname", "the opener's broken link is shown as text")
  T.eq({ detail.id, detail.close, detail.maxStake, detail.state }, { id, event.c, 100, "open" }, "the fields")
  T.eq({ detail.outcomes[1].p, detail.outcomes[1].x, detail.outcomes[2].p, detail.outcomes[2].x }, { 60, nil, 5, 3 },
    "the chances and the cap")

  -- Book entries, written by hand: two valid, three that the reader ignores
  local memberBetId = member.sync:GetId(PLAYER_TABLE, data.betKey("Nota Scam", id))
  local entries = {
    ["Nota Scam"] = { g = { [1] = 30, [2] = 7 }, b = memberBetId, t = now(net) },
    ["Other One"] = { g = { [1] = 50 }, b = memberBetId, t = now(net) },
    ["Late One"] = { g = { [1] = 40 }, b = memberBetId, t = event.c + 1 },
    ["Bad Outcome"] = { g = { [1] = 10, [3] = 10 }, b = memberBetId, t = now(net) },
    ["Too Much"] = { g = { [2] = 101 }, b = memberBetId, t = now(net) },
  }
  for name, entry in pairs(entries) do
    T.eq(officer.sync:Put(TABLE, data.bookKey(id, name), entry), true, "a book entry of " .. name .. " is written")
  end
  exchange(net)
  detail = member.model:Detail(id)
  T.eq({ detail.outcomes[1].booked, detail.outcomes[2].booked }, { nil, nil }, "the sums are hidden while open")
  T.eq({ detail.outcomes[1].own, detail.outcomes[2].own }, { 30, 7 }, "the own stakes are shown")
  T.eq(member.model:BookedBets(id), { ["Nota Scam"] = { [1] = 30, [2] = 7 }, ["Other One"] = { [1] = 50 } },
    "BookedBets gives the valid entries only")
  T.eq(member.model:BookedBets("no such id"), {}, "and nothing for an unknown event")

  T.eq(officer.model:Lock(id), true, "the officer locks the event")
  exchange(net)
  detail = member.model:Detail(id)
  T.eq(detail.state, "locked", "the event is locked")
  T.eq({ detail.outcomes[1].booked, detail.outcomes[2].booked }, { 80, 7 }, "the sums of the valid entries show")
  T.eq(detail.betState, "accepted", "with the state of the own bet")
  local otherDetail = other.model:Detail(id)
  T.eq({ otherDetail.outcomes[1].own, otherDetail.outcomes[2].own }, { nil, nil }, "a member without a bet has none")
  T.eq(otherDetail.betState, "outdated", "and a booked entry without a bet record is outdated")
  T.eq(member.model:Detail("no such id"), nil, "an unknown event has no detail")
end

-- Every value of BetState
do
  local model = member.model

  ---Opens an event that closes in 600 seconds and lets the member hold it.
  ---@return string
  local function open()
    local id = officer.model:Open(spec(net, 600))
    exchange(net)
    return id
  end

  ---Books the current bet of the member in an event, as an officer's addon would.
  ---@param id string
  ---@param t integer? Time of receipt; now when omitted
  local function book(id, t)
    local key = data.betKey("Nota Scam", id)
    local entry = { g = member.sync:Get(PLAYER_TABLE, key).g, b = member.sync:GetId(PLAYER_TABLE, key),
      t = t or now(net) }
    T.eq(officer.sync:Put(TABLE, data.bookKey(id, "Nota Scam"), entry), true, "the officer books the bet")
    exchange(net)
  end

  local none, accepted, changed, taken, late, lateEntry = open(), open(), open(), open(), open(), open()
  T.eq({ model:BetState(none) }, { "none" }, "no bet and no entry: none")
  T.eq(model:BetState("no such id"), nil, "an unknown event has no state")

  model:PlaceBet(accepted, { [1] = 10 })
  T.eq({ model:BetState(accepted) }, { "waiting" }, "a bet without an entry: waiting")
  book(accepted)
  T.eq({ model:BetState(accepted) }, { "accepted" }, "an entry with the id of the bet: accepted")

  model:PlaceBet(changed, { [1] = 10 })
  book(changed)
  model:PlaceBet(changed, { [1] = 20 })
  T.eq({ model:BetState(changed) }, { "waiting" }, "a changed bet waits for its new entry")

  model:PlaceBet(taken, { [2] = 15 })
  book(taken)
  model:TakeBack(taken)
  T.eq({ model:BetState(taken) }, { "waiting" }, "a taken-back bet whose entry is still there: waiting")

  model:PlaceBet(late, { [1] = 5 })
  model:PlaceBet(lateEntry, { [1] = 5 })

  net:Advance(600)
  T.eq({ model:BetState(none) }, { "none" }, "after the close, nothing is still none")
  T.eq({ model:BetState(accepted) }, { "accepted" }, "an accepted bet stays accepted after the close")
  T.eq({ model:BetState(changed) }, { "outdated", { stakes = { [1] = 10 } } },
    "a change that came too late leaves the booked stakes in force: outdated")
  T.eq({ model:BetState(taken) }, { "outdated", { stakes = { [2] = 15 } } },
    "a take back that came too late: outdated, also without a bet record")
  T.eq({ model:BetState(late) }, { "late" }, "a bet without an entry after the close: late")
  -- An entry received after the close does not count, also when it carries the id of the bet
  book(lateEntry, now(net) + 1)
  T.eq({ model:BetState(lateEntry) }, { "late" }, "a bet whose entry came after the close: late")
  T.eq(model:Detail(changed).betInfo, { stakes = { [1] = 10 } }, "Detail carries the state and its info")
  T.eq(model:Detail(changed).betState, "outdated", "and the state")
end

T.finish()
