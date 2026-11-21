-- Host test of the gambling model (.agents/00-plan.md, sections 15.3 to 15.6, steps 14.3 and 14.5;
-- Addon/Src/Gamble/Gamble.lua): opening, locking, and cancelling events, placing and taking back bets, the
-- reading of the events, of one event, and of the state of the own bet; the resolution, the dues, and the
-- receipts. The booking code is not loaded: where a test needs a book entry, the officer replica writes it by
-- hand.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Gamble/GambleData.lua", "Addon/Src/Gamble/GambleSettle.lua", "Addon/Src/Gamble/Gamble.lua" }
local OFFICER_RANK = 0
local TABLE, PLAYER_TABLE = "gamble", "gamble_player"
local HOUR = 3600

---@class GambleTestReplica: TestReplica
---@field model table The gambling model of this replica

---Makes a replica that has the gambling tables and a gambling model, and logs it in.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param source (fun(m: integer?, n: integer?): number)? Random source of the replica; default the one of the file
---@return GambleTestReplica
local function withGamble(net, name, rankIndex, source)
  source = source or random
  local replica = Replica.new(net, name, { random = source, rankIndex = rankIndex }) --[[@as GambleTestReplica]]
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
    random = source,
    isOfficer = function(other)
      return net.guild:IsOfficer(other)
    end,
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
---Seconds after the close before an event can be resolved
local RESOLVE_WAIT = officer.ns.gamble.RESOLVE_WAIT

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
    by = event.by, r = { false, true }, q = "zz!!", d = 1, k = "Officer One" })
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

--------------------------------------------------------------------------------
-- Step 14.5: resolution, dues, receipts
--------------------------------------------------------------------------------

---Results of the example of 15.5: Nota wins
local NOTA_WINS = { true, false }
---Results of the example of 15.5: Other wins
local OTHER_WINS = { false, true }
---Results without a loser: nothing is owed
local BOTH_WIN = { true, true }
---The bettors of the example of 15.5 and their stakes
local BETTORS = {
  { name = "Xavi Ash", stakes = { [1] = 30 } },
  { name = "Yara Bell", stakes = { [1] = 20 } },
  { name = "Zed Cole", stakes = { [2] = 40 } },
}

---Returns the dues of the example of 15.5 as `Result` lists them without the confirmation and the own fields.
---@param results boolean[]
---@param banker string
---@return table[]
local function exampleDues(results, banker)
  if results == NOTA_WINS then
    return { { n = 1, from = "Zed Cole", to = banker, gold = 3, bank = true },
      { n = 2, from = "Zed Cole", to = "Xavi Ash", gold = 20, bank = false },
      { n = 3, from = "Zed Cole", to = "Yara Bell", gold = 13, bank = false } }
  elseif results == OTHER_WINS then
    return { { n = 1, from = "Xavi Ash", to = banker, gold = 5, bank = true },
      { n = 2, from = "Xavi Ash", to = "Zed Cole", gold = 25, bank = false },
      { n = 3, from = "Yara Bell", to = "Zed Cole", gold = 20, bank = false } }
  end
  return {}
end

---The nets of the bettors of the example of 15.5
local EXAMPLE_NETS = {
  [NOTA_WINS] = { ["Xavi Ash"] = 20, ["Yara Bell"] = 13, ["Zed Cole"] = -36 },
  [OTHER_WINS] = { ["Xavi Ash"] = -30, ["Yara Bell"] = -20, ["Zed Cole"] = 45 },
}

---Keeps the fields of the dues of a `Result` that every replica shares.
---@param dues table[]
---@param withConfirmation boolean?
---@return table[]
local function shared(dues, withConfirmation)
  local list = {}
  for index, due in ipairs(dues) do
    list[index] = { n = due.n, from = due.from, to = due.to, gold = due.gold, bank = due.bank,
      confirmed = withConfirmation and due.confirmed or nil }
  end
  return list
end

---Returns the stored dues `1..count` of an event on one replica, with their ids.
---@param replica GambleTestReplica
---@param id string
---@param count integer
---@return table[]
local function storedDues(replica, id, count)
  local list = {}
  for n = 1, count do
    local key = data.dueKey(id, n)
    list[n] = { payload = replica.sync:Get(TABLE, key), id = replica.sync:GetId(TABLE, key) }
  end
  return list
end

---@class GambleExample The example of 15.5 on one network: an officer (or two) and the three bettors
---@field net Fakenet
---@field boss GambleTestReplica The officer who opens the event and books the bets
---@field second GambleTestReplica|nil The second officer
---@field all GambleTestReplica[] Every replica
---@field byName table<string, GambleTestReplica>
---@field id string The event
---@field settle fun() Lets the replicas exchange their changes; long enough to repair message loss
---@field label string Prefix of the test names

---Builds the example of 15.5 up to the booked bets: the officer opens the event, the bettors bet, and the
---officer books the bets by hand. The event is still open.
---@param options { seed: integer?, secondOfficer: boolean? }? With a seed the network loses 30% of the messages
---@return GambleExample
local function example(options)
  options = options or {}
  local source = options.seed and T.newRandom(options.seed) or random
  local world = Fakenet.new({ random = source, loss = options.seed and 0.3 or 0 })
  local ex = { net = world, all = {}, byName = {}, label = options.seed and ("seed " .. options.seed .. ": ") or "" }
  -- Under loss a receipt reached the only officer after more than 3 hours with some seeds (4 and 9 of 1 to 16)
  local wait = options.seed and 6 * HOUR or 60
  ex.settle = function()
    world:Advance(wait)
  end

  ---Adds a replica to the example.
  ---@param name string
  ---@param rankIndex integer?
  ---@return GambleTestReplica
  local function add(name, rankIndex)
    local replica = withGamble(world, name, rankIndex, source)
    ex.all[#ex.all + 1] = replica
    ex.byName[name] = replica
    return replica
  end
  ex.boss = add("Officer One", OFFICER_RANK)
  if options.secondOfficer then
    ex.second = add("Officer Two", 1)
  end
  for _, bettor in ipairs(BETTORS) do
    add(bettor.name)
  end
  ex.settle()
  -- The close is far ahead, so that the bets of a lossy run are in time; the runs lock the event
  ex.id = ex.boss.model:Open(spec(world, 30 * HOUR))
  T.ok(ex.id, ex.label .. "the officer opens the event of the example")
  ex.settle()
  for _, bettor in ipairs(BETTORS) do
    local replica = ex.byName[bettor.name]
    T.eq(replica.model:PlaceBet(ex.id, bettor.stakes), true, ex.label .. bettor.name .. " bets")
    local key = data.betKey(bettor.name, ex.id)
    local entry = { g = replica.sync:Get(PLAYER_TABLE, key).g, b = replica.sync:GetId(PLAYER_TABLE, key),
      t = now(world) }
    T.eq(ex.boss.sync:Put(TABLE, data.bookKey(ex.id, bettor.name), entry), true,
      ex.label .. "the officer books the bet of " .. bettor.name)
  end
  ex.settle()
  return ex
end

---Checks that every replica of an example shows the same whole result, the one that `results` and `banker` give.
---@param ex GambleExample
---@param results boolean[]
---@param banker string
---@param what string Test name
local function sameEverywhere(ex, results, banker, what)
  local expected = exampleDues(results, banker)
  local reference = storedDues(ex.boss, ex.id, #expected)
  for _, replica in ipairs(ex.all) do
    local result = replica.model:Result(ex.id)
    local name = ex.label .. what .. " on " .. replica.name
    T.eq({ result.state, result.results, result.banker, result.count, result.held },
      { "ready", results, banker, #expected, #expected }, name .. ": the result is ready")
    T.eq(shared(result.dues), expected, name .. ": the dues")
    T.eq(storedDues(replica, ex.id, #expected), reference, name .. ": the stored dues equal the officer's")
    T.eq(result.mismatch, false, name .. ": the book gives the same dues")
  end
end

---Runs the example of 15.5 from the lock to the last confirmation and checks every replica on the way.
---@param ex GambleExample
---@param results boolean[]
local function runExample(ex, results)
  local boss, id, label = ex.boss, ex.id, ex.label
  if label == "" then
    T.eq(boss.model:ResolvePreview(id), { bets = 3, sum = 90, behind = false,
      wait = boss.model:Event(id).c + RESOLVE_WAIT - now(ex.net) },
      "the preview counts the booked bets and their gold, and the seconds until the event can be resolved")
  end
  T.eq(boss.model:Lock(id), true, label .. "the officer locks the event")
  ex.net:Advance(RESOLVE_WAIT)
  T.eq(boss.model:Resolve(id, results), true, label .. "and resolves it after the wait for the bookings")
  local event = boss.model:Event(id)
  T.eq({ event.s, event.r, event.d, event.k, #event.q, boss.ns.base94.isValid(event.q) },
    { 2, results, 3, "Officer One", 4, true }, label .. "the event carries the resolution and a token")
  ex.settle()
  sameEverywhere(ex, results, "Officer One", "the example")

  local nets = EXAMPLE_NETS[results]
  for _, replica in ipairs(ex.all) do
    local result = replica.model:Result(id)
    local name = label .. replica.name
    local own = nets[replica.name]
    T.eq(result.net, own or 0, name .. ": the own net")
    T.eq(result.bankHeld, own and 0 or exampleDues(results, "Officer One")[1].gold, name .. ": the bank share held")
    T.eq({ result.booked, result.inSettlement }, { own ~= nil, own ~= nil }, name .. ": in the settlement")
    local ownNumbers = {}
    for index, due in ipairs(result.ownDues) do
      ownNumbers[index] = due.n
      T.ok(due.from == replica.name or due.to == replica.name, name .. ": an own due names the own character")
      T.eq(due.mine, due.from == replica.name and "pay" or "receive", name .. ": and says which side")
      T.eq(due.confirmable, due.to == replica.name, name .. ": only a received due can be confirmed")
    end
    T.ok(#ownNumbers >= 1, name .. ": has own dues")
    T.eq({ result.settled, ids(replica.model:Events().toPay) }, { false, { id } }, name .. ": the event is to pay")
  end

  -- Every receiver confirms; a payer cannot
  local dues = boss.model:Result(id).dues
  for _, due in ipairs(dues) do
    T.eq({ ex.byName[due.from].model:Confirm(id, due.n) }, { nil, "not the receiver" },
      label .. "the payer of due " .. due.n .. " cannot confirm it")
  end
  for _, due in ipairs(dues) do
    T.eq(ex.byName[due.to].model:Confirm(id, due.n), true, label .. "the receiver confirms due " .. due.n)
  end
  ex.settle()
  for _, replica in ipairs(ex.all) do
    local result = replica.model:Result(id)
    local name = label .. replica.name
    T.eq(result.settled, true, name .. ": every due is confirmed")
    for _, due in ipairs(result.dues) do
      T.eq(due.confirmed, true, name .. ": due " .. due.n .. " is confirmed")
    end
    local groups = replica.model:Events()
    T.eq({ ids(groups.toPay), ids(groups.done) }, { {}, { id } }, name .. ": the event is done")
  end
end

-- The checkpoint of 14.5: the example of 15.5 from the opening to the last confirmation, with both results
runExample(example(), NOTA_WINS)
runExample(example(), OTHER_WINS)

-- The same life under 30% message loss ends equal on every replica
for seed = 1, 4 do
  runExample(example({ seed = seed }), seed % 2 == 1 and NOTA_WINS or OTHER_WINS)
end

-- The refusals of Resolve and the banker
do
  local ex = example({ secondOfficer = true })
  local boss, id = ex.boss, ex.id
  local x = ex.byName["Xavi Ash"]
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "open" }, "an open event cannot be resolved")
  T.eq(boss.model:Lock(id), true, "the officer locks the event")
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "booking" }, "a locked event cannot be resolved at once")
  T.eq(boss.model:ResolvePreview(id).wait, RESOLVE_WAIT, "the preview tells the seconds of the wait")
  ex.net:Advance(RESOLVE_WAIT - 1)
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "booking" }, "nor one second before the wait is over")
  T.eq(boss.model:ResolvePreview(id).wait, 1, "the preview counts down")
  ex.net:Advance(1)
  T.eq(boss.model:ResolvePreview(id).wait, 0, "and gives 0 when the event can be resolved")
  T.eq({ x.model:Resolve(id, NOTA_WINS) }, { nil, "not an officer" }, "a member cannot resolve")
  T.eq({ boss.model:Resolve("no such id", NOTA_WINS) }, { nil, "unknown event" }, "an unknown event")
  T.eq({ boss.model:Resolve(id, { true }) }, { nil, "bad results" }, "too few results")
  T.eq({ boss.model:Resolve(id, { true, false, true }) }, { nil, "bad results" }, "too many results")
  T.eq({ boss.model:Resolve(id, { true, 1 }) }, { nil, "bad results" }, "a result that is no boolean")
  T.eq({ boss.model:Resolve(id, { true, false, x = true }) }, { nil, "bad results" }, "a result list with a name")
  T.eq({ boss.model:Resolve(id, "true") }, { nil, "bad results" }, "results that are no table")
  T.eq({ boss.model:Resolve(id, NOTA_WINS, "Xavi Ash") }, { nil, "bad banker" }, "a banker who is no officer")
  T.eq({ boss.model:Resolve(id, NOTA_WINS, "Bad:Name") }, { nil, "bad banker" }, "a banker with a bad name")
  T.eq({ boss.model:Resolve(id, NOTA_WINS, 42) }, { nil, "bad banker" }, "a banker that is no name")
  local noRoster = boss.ns.gamble.new({ sync = boss.sync, now = function() return now(ex.net) end,
    playerName = function() return "Officer One" end, sanitize = boss.ns.mentions.sanitize, random = random })
  T.eq({ noRoster:Resolve(id, NOTA_WINS, "Officer Two") }, { nil, "bad banker" },
    "without the roster part only the own character can be the banker")
  local unnamed = boss.ns.gamble.new({ sync = boss.sync, now = function() return now(ex.net) end,
    playerName = function() return nil end, sanitize = boss.ns.mentions.sanitize, random = random })
  T.eq({ unnamed:Resolve(id, NOTA_WINS) }, { nil, "not ready" }, "a resolution without the own name")
  T.eq(boss.model:Event(id).s, 1, "no refused resolution changed the event")
  T.eq(boss.sync:Get(TABLE, data.dueKey(id, 1)), nil, "nor wrote a due")

  -- A due that cannot be written stops the resolution before the event
  local put = boss.sync.Put
  boss.sync.Put = function(sync, tableName, key, payload)
    if key == data.dueKey(id, 2) then
      return nil, "too large"
    end
    return put(sync, tableName, key, payload)
  end
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "too large" }, "a due that cannot be written stops it")
  boss.sync.Put = put
  T.eq(boss.model:Event(id).s, 1, "the event is not written")
  T.ok(boss.sync:Get(TABLE, data.dueKey(id, 1)), "the due written before stays")
  T.eq(boss.model:Result(id), nil, "and a locked event has no result")

  T.eq(boss.model:Resolve(id, NOTA_WINS, "Officer Two"), true, "another officer can be the banker")
  T.eq(boss.model:Event(id).k, "Officer Two", "the event names the banker")
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "resolved" }, "a resolved event cannot be resolved again")
  ex.settle()
  sameEverywhere(ex, NOTA_WINS, "Officer Two", "a banker who is not the resolver")
  local banker = ex.second.model:Result(id)
  T.eq({ banker.net, banker.bankHeld, banker.inSettlement, #banker.ownDues, banker.ownDues[1].mine,
    banker.ownDues[1].confirmable }, { 0, 3, false, 1, "receive", true }, "the banker holds the bank share")
  T.eq(boss.model:Result(id).ownDues, {}, "the resolver has no due")
  T.eq(ex.second.model:Confirm(id, 1), true, "the banker confirms the bank due")
  T.eq({ boss.model:Confirm(id, 1) }, { nil, "not the receiver" }, "the resolver cannot")
end

-- Receipts: only the receiver's, only of the token in force
do
  local ex = example()
  local id, boss = ex.id, ex.boss
  local x, y, z = ex.byName["Xavi Ash"], ex.byName["Yara Bell"], ex.byName["Zed Cole"]
  T.eq({ y.model:Confirm(id, 1) }, { nil, "not resolved" }, "an open event has no due to confirm")
  boss.model:Lock(id)
  T.eq({ y.model:Confirm(id, 1) }, { nil, "not resolved" }, "nor has a locked one")
  ex.net:Advance(RESOLVE_WAIT)
  T.eq(boss.model:Resolve(id, NOTA_WINS), true, "the officer resolves: Nota wins")
  ex.settle()
  local token = boss.model:Event(id).q

  ---Returns the confirmations of the three dues on a replica.
  ---@param replica GambleTestReplica
  ---@return boolean[]
  local function confirmations(replica)
    local list = {}
    for index, due in ipairs(replica.model:Result(id).dues) do
      list[index] = due.confirmed
    end
    return list
  end

  T.eq({ x.model:Confirm(id, 3) }, { nil, "not the receiver" }, "a member cannot confirm a due of another")
  T.eq({ z.model:Confirm(id, 2) }, { nil, "not the receiver" }, "nor the payer")
  T.eq({ x.model:Confirm(id, 4) }, { nil, "unknown due" }, "a due number over the count")
  T.eq({ x.model:Confirm(id, 0) }, { nil, "unknown due" }, "due number 0")
  T.eq({ x.model:Confirm(id, "2") }, { nil, "unknown due" }, "a due number that is a string")
  T.eq({ x.model:Confirm("no such id", 2) }, { nil, "unknown event" }, "an unknown event")
  T.eq(x.sync:Get(PLAYER_TABLE, data.receiptKey("Xavi Ash", id)), nil, "no refused confirmation wrote a receipt")

  -- Hand-written receipts: Yara claims due 2 (Xavi's), Xavi holds a receipt of another token
  T.eq(y.sync:Put(PLAYER_TABLE, data.receiptKey("Yara Bell", id), { q = token, n = { [2] = true, [3] = true } }),
    true, "Yara writes a receipt for due 2 of Xavi and her own due 3")
  local oldToken = token == "zzzz" and "yyyy" or "zzzz"
  T.eq(x.sync:Put(PLAYER_TABLE, data.receiptKey("Xavi Ash", id), { q = oldToken, n = { [2] = true, [7] = true } }),
    true, "Xavi holds a receipt of another token")
  T.eq({ z.sync:Put(PLAYER_TABLE, data.receiptKey("Xavi Ash", id), { q = token, n = { [2] = true } }) },
    { nil, "not the owner" }, "nobody can write the receipt record of another")
  ex.settle()
  for _, replica in ipairs(ex.all) do
    T.eq(confirmations(replica), { false, false, true },
      replica.name .. ": a receipt of the wrong character and one of another token do not count")
  end

  T.eq(x.model:Confirm(id, 2), true, "Xavi confirms due 2")
  T.eq(x.sync:Get(PLAYER_TABLE, data.receiptKey("Xavi Ash", id)), { q = token, n = { [2] = true } },
    "the receipt of the old token is replaced, not merged")
  T.eq(x.model:Confirm(id, 2), true, "a second confirmation is no error")
  ex.settle()
  T.eq(confirmations(z), { false, true, true }, "every replica sees the confirmation")
  T.eq(z.model:Result(id).settled, false, "the bank due is not confirmed yet")
  T.eq(boss.model:Confirm(id, 1), true, "the banker confirms the bank due")
  ex.settle()
  for _, replica in ipairs(ex.all) do
    T.eq({ replica.model:Result(id).settled, ids(replica.model:Events().done) }, { true, { id } },
      replica.name .. ": settled and done")
  end

  T.eq(x.model:Unconfirm(id, 2), true, "Xavi takes his confirmation back")
  T.eq(x.sync:Get(PLAYER_TABLE, data.receiptKey("Xavi Ash", id)), nil, "a receipt without numbers is deleted")
  T.eq(x.model:Unconfirm(id, 2), true, "taking back what is not confirmed is no error")
  T.eq({ z.model:Unconfirm(id, 2) }, { nil, "not the receiver" }, "only the receiver can take it back")
  T.eq({ y.model:Unconfirm(id, 2) }, { nil, "not the receiver" }, "Yara cannot take back what she never could confirm")
  ex.settle()
  for _, replica in ipairs(ex.all) do
    T.eq({ confirmations(replica), replica.model:Result(id).settled, ids(replica.model:Events().toPay) },
      { { true, false, true }, false, { id } }, replica.name .. ": back to pay")
  end
  T.eq(y.model:Unconfirm(id, 3), true, "Yara takes back due 3")
  T.eq(y.sync:Get(PLAYER_TABLE, data.receiptKey("Yara Bell", id)), { q = token, n = { [2] = true } },
    "the other numbers of her record stay")
end

-- Two officers resolve at the same time with different results: every replica shows one of the two, whole
do
  -- In the same second the origin of the ids decides for every key at once; `firstLater`: the first officer
  -- resolves one second after the second, before either has heard of the other
  local cases = { { NOTA_WINS, OTHER_WINS }, { BOTH_WIN, NOTA_WINS }, { NOTA_WINS, BOTH_WIN },
    { OTHER_WINS, NOTA_WINS }, { BOTH_WIN, NOTA_WINS, firstLater = true }, { NOTA_WINS, BOTH_WIN, firstLater = true } }
  local staleSeen = false
  for index, case in ipairs(cases) do
    local ex = example({ secondOfficer = true })
    local first, second = ex.boss, ex.second ---@cast second GambleTestReplica
    T.eq(first.model:Lock(ex.id), true, "case " .. index .. ": the first officer locks")
    ex.settle()
    ex.net:Advance(RESOLVE_WAIT)
    if case.firstLater then
      T.eq(second.model:Resolve(ex.id, case[2]), true, "case " .. index .. ": the second officer resolves")
      ex.net:Advance(1)
      T.eq(first.model:Resolve(ex.id, case[1]), true, "case " .. index .. ": the first officer resolves a second later")
    else
      T.eq(first.model:Resolve(ex.id, case[1]), true, "case " .. index .. ": the first officer resolves")
      T.eq(second.model:Resolve(ex.id, case[2]), true, "case " .. index .. ": the second officer resolves too")
    end
    -- Long enough for the periodic summaries: the push of the later writer can meet a peer that has just
    -- written itself, and a pull repairs that
    ex.net:Advance(HOUR)
    local winner = first.model:Result(ex.id)
    local results = winner.results[1] == case[1][1] and winner.results[2] == case[1][2] and case[1] or case[2]
    T.eq(winner.results, results, "case " .. index .. ": the result is one of the two")
    local banker = results == case[1] and "Officer One" or "Officer Two"
    T.eq(winner.banker, banker, "case " .. index .. ": with the banker of its resolver")
    sameEverywhere(ex, results, banker, "case " .. index)
    if case.firstLater then
      T.eq(results, case[1], "case " .. index .. ": the later resolution wins")
    end
    if results == BOTH_WIN then
      for _, replica in ipairs(ex.all) do
        local result = replica.model:Result(ex.id)
        T.eq({ result.dues, result.net, result.settled, ids(replica.model:Events().done) },
          { {}, 0, true, { ex.id } }, "case " .. index .. ", " .. replica.name .. ": no loser, nothing owed, done")
        -- The dues of the other resolution are still stored, under their own token
        local stale = replica.sync:Get(TABLE, data.dueKey(ex.id, 1))
        staleSeen = staleSeen or (stale ~= nil and stale.q ~= replica.model:Event(ex.id).q)
      end
    end
  end
  T.ok(staleSeen, "a winner without dues left the dues of the other token stored, and no reader counted them")
end

-- A cancel after the resolution: nobody owes anything
do
  local ex = example()
  local id, boss = ex.id, ex.boss
  boss.model:Lock(id)
  ex.net:Advance(RESOLVE_WAIT)
  T.eq(boss.model:Resolve(id, OTHER_WINS), true, "the officer resolves")
  ex.settle()
  T.eq(ex.byName["Zed Cole"].model:Confirm(id, 2), true, "a receiver confirms a due")
  T.eq(boss.model:Cancel(id), true, "the officer cancels the resolved event")
  ex.settle()
  for _, replica in ipairs(ex.all) do
    local result = replica.model:Result(id)
    T.eq({ result.state, result.dues, result.ownDues, result.net, result.bankHeld, result.settled },
      { "cancelled", {}, {}, 0, 0, true }, replica.name .. ": nobody owes anything")
    T.eq(ids(replica.model:Events().done), { id }, replica.name .. ": the event is done")
    T.eq(replica.model:Detail(id).state, "cancelled", replica.name .. ": and cancelled")
  end
  T.eq({ ex.byName["Zed Cole"].model:Confirm(id, 3) }, { nil, "cancelled" }, "no due of it can be confirmed")
  T.eq({ ex.byName["Zed Cole"].model:Unconfirm(id, 2) }, { nil, "cancelled" }, "nor taken back")
  T.eq({ boss.model:Resolve(id, NOTA_WINS) }, { nil, "cancelled" }, "nor can it be resolved again")
end

-- A book entry that arrives after the resolution changes no due: its bettor is not in the settlement
do
  local ex = example()
  local id, boss = ex.id, ex.boss
  local late = withGamble(ex.net, "Will Dee")
  ex.all[#ex.all + 1] = late
  ex.settle()
  T.eq(late.model:PlaceBet(id, { [2] = 10 }), true, "a fourth member bets, and no officer books it in time")
  boss.model:Lock(id)
  ex.net:Advance(RESOLVE_WAIT)
  local preview = boss.model:ResolvePreview(id)
  T.eq({ preview.bets, preview.sum }, { 3, 90 }, "the preview counts the booked bets only")
  T.eq(boss.model:Resolve(id, NOTA_WINS), true, "the officer resolves: Nota wins")
  ex.settle()
  local before = {}
  for index, replica in ipairs(ex.all) do
    before[index] = storedDues(replica, id, 3)
  end
  T.eq(late.model:Result(id).inSettlement, false, "a member without a book entry is not in the settlement")

  -- The entry was received before the close and is written now, as an officer who held the bet in its waiting
  -- list would do
  local key = data.betKey("Will Dee", id)
  T.eq(boss.sync:Put(TABLE, data.bookKey(id, "Will Dee"), { g = late.sync:Get(PLAYER_TABLE, key).g,
    b = late.sync:GetId(PLAYER_TABLE, key), t = boss.model:Event(id).c }), true, "the late entry is written")
  ex.settle()
  for index, replica in ipairs(ex.all) do
    T.eq(storedDues(replica, id, 3), before[index], replica.name .. ": no due changed")
    T.eq(shared(replica.model:Result(id).dues), exampleDues(NOTA_WINS, "Officer One"),
      replica.name .. ": the dues are those of the resolution")
    T.eq(replica.model:Result(id).mismatch, true, replica.name .. ": the book now gives other dues")
  end
  local result = late.model:Result(id)
  T.eq({ result.booked, result.inSettlement, result.net, result.ownDues, result.state },
    { true, false, 0, {}, "ready" }, "the late bettor is not in the settlement and owes nothing")
  T.eq(ex.byName["Xavi Ash"].model:Result(id).net, 20, "a counted bettor keeps the net of the resolution")
end

-- A replica with the event and half of the dues shows "loading"
do
  local ex = example()
  local id, boss = ex.id, ex.boss
  boss.model:Lock(id)
  ex.net:Advance(RESOLVE_WAIT)
  T.eq(boss.model:Resolve(id, OTHER_WINS), true, "the officer resolves: Other wins")
  local fresh = withGamble(Fakenet.new({ random = random, start = ex.net:Now() }), "Will Dee")

  ---Applies records of the officer to the fresh replica, as a pull would, in the order of their ids.
  ---@param keys string[]
  local function apply(keys)
    local records = {}
    for index, key in ipairs(keys) do
      records[index] = { key = key, id = boss.sync:GetId(TABLE, key), payload = boss.sync:Get(TABLE, key) }
    end
    table.sort(records, function(a, b)
      return a.id < b.id
    end)
    local changed, dropped = fresh.sync:ApplyRemote(TABLE, records)
    T.eq({ #changed, dropped }, { #keys, 0 }, "the fresh replica takes " .. #keys .. " records")
  end

  apply({ data.eventKey(id), data.dueKey(id, 1) })
  local result = fresh.model:Result(id)
  T.eq({ result.state, result.held, result.count, result.dues, result.ownDues, result.net, result.bankHeld,
    result.settled, result.inSettlement, result.results },
    { "loading", 1, 3, {}, {}, nil, nil, false, nil, OTHER_WINS }, "the event and one of three dues: loading")
  T.eq(ids(fresh.model:Events().toPay), { id }, "a loading event is to pay")
  apply({ data.dueKey(id, 2) })
  T.eq({ fresh.model:Result(id).state, fresh.model:Result(id).held }, { "loading", 2 }, "two of three: loading")
  -- A due of the number 3 with another token does not count
  local stray = boss.sync:Get(TABLE, data.dueKey(id, 3))
  local token = stray.q
  fresh.sync:ApplyRemote(TABLE, { { key = data.dueKey(id, 3), id = fresh.ns.versionId.make(now(ex.net) - 600, "QQQQ",
    0), payload = { q = token == "zzzz" and "yyyy" or "zzzz", f = stray.f, t = stray.t, g = stray.g } } })
  T.eq(fresh.model:Result(id).state, "loading", "a due of another token does not count")
  apply({ data.dueKey(id, 3) })
  result = fresh.model:Result(id)
  T.eq({ result.state, result.held }, { "ready", 3 }, "every due: ready")
  T.eq(shared(result.dues), exampleDues(OTHER_WINS, "Officer One"), "with the dues of the officer")
end

-- Lonely tests: a capped outcome pays by the cap; a banker who pays the bank share; "not in the settlement" by
-- the book of the replica
do
  local lonelyNet = Fakenet.new({ random = random })
  local aaron = withGamble(lonelyNet, "Aaron Bank", OFFICER_RANK)
  lonelyNet:Advance(60)
  local model = aaron.model

  ---Opens an event, books the given stakes by hand, and locks it.
  ---@param outcomes table[]
  ---@param bets table<string, table<integer, integer>>
  ---@return string
  local function bookedEvent(outcomes, bets)
    local id = model:Open({ title = "Lonely", outcomes = outcomes, close = now(lonelyNet) + HOUR, maxStake = 100 })
    for name, stakes in pairs(bets) do
      T.eq(aaron.sync:Put(TABLE, data.bookKey(id, name), { g = stakes, b = id, t = now(lonelyNet) }), true,
        "the entry of " .. name .. " is booked")
    end
    lonelyNet:Advance(1)
    model:Lock(id)
    lonelyNet:Advance(RESOLVE_WAIT)
    return id
  end

  local capped = bookedEvent({ { n = "Sword", p = 2, x = 10 }, { n = "No sword", p = 98 } },
    { ["Ann Axe"] = { [1] = 5 }, ["Aaron Bank"] = { [2] = 100 }, ["Cid Cog"] = { [2] = 100 } })
  T.eq(model:Resolve(capped, { true, false }), true, "the sword drops")
  local result = model:Result(capped)
  T.eq(shared(result.dues), {
    { n = 1, from = "Aaron Bank", to = "Aaron Bank", gold = 5, bank = true },
    { n = 2, from = "Aaron Bank", to = "Ann Axe", gold = 23, bank = false },
    { n = 3, from = "Cid Cog", to = "Ann Axe", gold = 27, bank = false },
  }, "5 gold on 2% with a cap of 10 win 50, not 245; the banker pays the bank share to himself")
  T.eq({ result.net, result.bankHeld, result.inSettlement, result.mismatch }, { -28, 5, true, false },
    "the banker's own net leaves the bank share out")
  T.eq({ result.ownDues[1].mine, result.ownDues[1].confirmable, result.ownDues[2].mine,
    result.ownDues[2].confirmable, #result.ownDues }, { "pay", true, "pay", false, 2 },
    "a bank due that names the banker on both sides is paid and confirmed by the banker")

  -- The resolver lacked the own entry: a resolution written by hand without dues
  ---Writes a resolution by hand.
  ---@param id string
  ---@param results boolean[]
  local function resolveByHand(id, results)
    local event = model:Event(id)
    T.eq(aaron.sync:Put(TABLE, data.eventKey(id), { n = event.n, o = event.o, c = event.c, m = event.m, s = 2,
      by = event.by, r = results, q = "QQQQ", d = 0, k = "Aaron Bank" }), true, "a resolution is written by hand")
  end
  local missed = bookedEvent({ { n = "A", p = 60 }, { n = "B", p = 40 } },
    { ["Aaron Bank"] = { [1] = 10 }, ["Ann Axe"] = { [2] = 10 } })
  resolveByHand(missed, { true, false })
  result = model:Result(missed)
  T.eq({ result.state, result.dues, result.net, result.booked, result.inSettlement, result.mismatch },
    { "ready", {}, 0, true, false, true }, "a winning entry that the dues leave out is not in the settlement")
  T.eq(ids(model:Events().done), { missed }, "an event without dues is done at once")
  local even = bookedEvent({ { n = "A", p = 60 }, { n = "B", p = 40 } }, { ["Aaron Bank"] = { [1] = 10 } })
  resolveByHand(even, { true, false })
  result = model:Result(even)
  T.eq({ result.booked, result.inSettlement, result.mismatch }, { true, true, false },
    "an entry that gives a net of 0 cannot be told from one that broke even: in the settlement")
  T.eq(model:Result("no such id"), nil, "an unknown event has no result")
  T.eq(model:ResolvePreview("no such id"), nil, "nor a preview")
  local open = model:Open(spec(lonelyNet))
  T.eq(model:Result(open), nil, "an open event has no result")
  T.eq(model:ResolvePreview(open), { bets = 0, sum = 0, behind = false, wait = HOUR + RESOLVE_WAIT },
    "and a preview without bets that waits for the close and the bookings")
end

-- Names from other players are sanitized in the result
do
  local lonelyNet = Fakenet.new({ random = random })
  local boss = withGamble(lonelyNet, "Officer One", OFFICER_RANK)
  local id = boss.model:Open(spec(lonelyNet))
  boss.sync:Put(TABLE, data.bookKey(id, "Bad|Hname"), { g = { [1] = 10 }, b = id, t = now(lonelyNet) })
  boss.sync:Put(TABLE, data.bookKey(id, "Loser One"), { g = { [2] = 50 }, b = id, t = now(lonelyNet) })
  boss.model:Lock(id)
  lonelyNet:Advance(RESOLVE_WAIT)
  T.eq(boss.model:Resolve(id, NOTA_WINS), true, "an event with a bettor whose name has a `|` is resolved")
  local result = boss.model:Result(id)
  T.eq(shared(result.dues), { { n = 1, from = "Loser One", to = "Bad||Hname", gold = 6, bank = false } },
    "the name of a receiver is shown as text")
end

T.finish()
