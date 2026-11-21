-- Host test of the book (.agents/00-plan.md, section 15.4 "Booking", step 14.4; Addon/Src/Gamble/GambleBook.lua):
-- an officer's addon books the bets that it receives first hand before the close, after a random delay, and
-- nothing else. The replicas run on the fake network; each has a gambling model and a booker. The delay of a
-- booker is fixed where the order of two officers matters, so that no seed makes a test flaky.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local FILES = { "Addon/Src/Gamble/GambleData.lua", "Addon/Src/Gamble/Gamble.lua", "Addon/Src/Gamble/GambleBook.lua" }
local TABLE, PLAYER_TABLE = "gamble", "gamble_player"
local HOUR = 3600
local OFFICER, SECOND_OFFICER = 0, 1

---A delay source that always gives the shortest delay
local function fast()
  return 0
end

---A delay source that always gives a delay of 19.8 seconds
local function slow()
  return 0.99
end

---@class BookTestReplica: TestReplica
---@field model table The gambling model of this replica
---@field booker table|nil The booker while the replica is logged in
---@field delay fun(): number The random source of the booker; a test may change it
---@field bookWrites { key: string, payload: table|nil }[] Local writes and deletes of book entries
---@field received table<string, integer> Key of a bet record -> server time of its last first-hand receipt

---Returns the server time of a network as the addon sees it.
---@param net Fakenet
---@return integer
local function now(net)
  return math.floor(net:Now())
end

---Starts the booker of a replica.
---@param replica BookTestReplica
local function startBooker(replica)
  replica.booker = replica.ns.gambleBook.new({
    sync = replica.sync,
    now = function()
      return now(replica.net)
    end,
    after = function(seconds, fn)
      return replica.endpoint:After(seconds, fn)
    end,
    random = function()
      return replica.delay()
    end,
  })
end

---Logs a replica in and starts its booker.
---@param replica BookTestReplica
local function login(replica)
  replica:Login()
  startBooker(replica)
end

---Stops the booker of a replica and logs it out.
---@param replica BookTestReplica
local function logout(replica)
  replica.booker:Stop()
  replica.booker = nil
  replica:Logout()
end

---Makes a replica with the gambling tables, a model, and a booker. It is logged in unless `offline` is set.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@param delay (fun(): number)? Random source of the booker; the seeded one when omitted
---@param offline boolean?
---@return BookTestReplica
local function withBook(net, name, rankIndex, delay, offline)
  local replica = Replica.new(net, name, { random = random, rankIndex = rankIndex }) --[[@as BookTestReplica]]
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
  })
  replica.delay = delay or function()
    return random()
  end
  replica.bookWrites = {}
  replica.received = {}
  local data = replica.ns.gambleData
  replica.sync.RegisterCallback({}, "OnRecordChanged", function(_event, tableName, key, payload, isRemote, firstHand)
    local parts = data.parseKey(tableName, key)
    if tableName == TABLE and not isRemote and parts and parts.kind == "book" then
      replica.bookWrites[#replica.bookWrites + 1] = { key = key, payload = payload }
    elseif tableName == PLAYER_TABLE and firstHand then
      replica.received[key] = now(net)
    end
  end)
  if offline then
    net:SetOnline(name, false)
  else
    login(replica)
  end
  return replica
end

---Returns a valid spec of an event that closes `ahead` seconds from now.
---@param net Fakenet
---@param ahead integer?
---@return table
local function spec(net, ahead)
  return { title = "Who wins the duel on Friday?", outcomes = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } },
    close = now(net) + (ahead or HOUR), maxStake = 100 }
end

---Lets the replicas exchange their changes and the bookers write.
---@param net Fakenet
local function exchange(net)
  net:Advance(60)
end

---Counts the local writes of the book entries of one key.
---@param replica BookTestReplica
---@param key string
---@return integer
local function writesOf(replica, key)
  local count = 0
  for _, write in ipairs(replica.bookWrites) do
    if write.key == key then
      count = count + 1
    end
  end
  return count
end

---Joins a member that runs no addon and can send hand-made messages.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return table
local function joinRaw(net, name, rankIndex)
  local raw = { endpoint = net:Join(name, rankIndex) }
  raw.endpoint.receive = function() end
  ---Sends a hand-made push of records of one origin with the zero base, which is never a gap.
  ---@param tableName string
  ---@param origin string
  ---@param records OOOOSyncWireRecord[]
  function raw:Push(tableName, origin, records)
    local version = "!!!!!RRRR!!!!!!!"
    self.endpoint:Send(codec.encode("P", tableName, 1, version, version, true, { [origin] = "!!!!!!!!!!!" },
      Replica.protocol.packRecords(records)), "GUILD")
  end
  return raw
end

-- The checkpoint, and a bet before the close with two officers online: one entry, the same everywhere
do
  local net = Fakenet.new({ random = random })
  local first = withBook(net, "Officer One", OFFICER, fast)
  local second = withBook(net, "Officer Two", SECOND_OFFICER, slow)
  local member = withBook(net, "Nota Scam", nil, fast)
  exchange(net)
  local data = first.ns.gambleData
  local id = first.model:Open(spec(net))
  exchange(net)

  T.eq(member.model:PlaceBet(id, { [1] = 30 }), true, "the member bets")
  local betKey, bookKey = data.betKey("Nota Scam", id), data.bookKey(id, "Nota Scam")
  local betId = member.sync:GetId(PLAYER_TABLE, betKey)
  T.eq({ member.model:BetState(id) }, { "waiting" }, "the member waits for an officer")
  exchange(net)
  local receipt = first.received[betKey]
  T.ok(receipt and second.received[betKey] == receipt, "both officers received the bet first hand")
  local entry = { g = { [1] = 30 }, b = betId, t = receipt }
  T.eq(first.sync:Get(TABLE, bookKey), entry, "the faster officer books it with the time of receipt")
  T.eq(second.sync:Get(TABLE, bookKey), entry, "the other officer holds the same entry")
  T.eq(member.sync:Get(TABLE, bookKey), entry, "and so does the member")
  T.eq({ writesOf(first, bookKey), writesOf(second, bookKey) }, { 1, 0 },
    "one write: the slower officer found the entry of the same bet")
  T.eq({ member.model:BetState(id) }, { "accepted" }, "checkpoint: the bet shows as accepted on the member's replica")
  T.eq(#member.bookWrites, 0, "a member's booker writes nothing")

  -- An officer's own bet is booked too
  T.eq(second.model:PlaceBet(id, { [2] = 50 }), true, "an officer bets")
  exchange(net)
  local ownKey = data.bookKey(id, "Officer Two")
  T.eq(first.sync:Get(TABLE, ownKey).b, second.sync:GetId(PLAYER_TABLE, data.betKey("Officer Two", id)),
    "the officer's own bet is booked")
  T.eq({ second.model:BetState(id) }, { "accepted" }, "and accepted")

  -- Both officers with seeded delays: at most two writes, and every replica ends with the same entry
  local other = withBook(net, "Other One")
  exchange(net)
  T.eq(other.model:PlaceBet(id, { [1] = 10, [2] = 20 }), true, "another member bets")
  first.delay, second.delay = function() return random() end, function() return random() end
  exchange(net)
  exchange(net)
  local otherKey = data.bookKey(id, "Other One")
  local writes = writesOf(first, otherKey) + writesOf(second, otherKey)
  T.ok(writes >= 1 and writes <= 2, "one or two writes with random delays")
  local held = first.sync:Get(TABLE, otherKey)
  T.eq(held and held.b, other.sync:GetId(PLAYER_TABLE, data.betKey("Other One", id)), "the entry has the bet id")
  T.ok(held and held.t <= first.model:Event(id).c, "and a time of receipt before the close")
  T.eq({ second.sync:Get(TABLE, otherKey), other.sync:Get(TABLE, otherKey) }, { held, held },
    "all replicas hold the same entry")
  T.eq({ other.model:BetState(id) }, { "accepted" }, "the bet is accepted")
end

-- A change before the close replaces the entry; a take back deletes it; after the close nothing changes
do
  local net = Fakenet.new({ random = random })
  local officer = withBook(net, "Officer One", OFFICER)
  local member = withBook(net, "Nota Scam")
  exchange(net)
  local data = officer.ns.gambleData
  local id = officer.model:Open(spec(net, 600))
  exchange(net)
  local betKey, bookKey = data.betKey("Nota Scam", id), data.bookKey(id, "Nota Scam")

  member.model:PlaceBet(id, { [1] = 10 })
  exchange(net)
  local firstEntry = officer.sync:Get(TABLE, bookKey)
  T.eq(firstEntry and firstEntry.g, { [1] = 10 }, "the bet is booked")
  member.model:PlaceBet(id, { [1] = 20 })
  local changedId = member.sync:GetId(PLAYER_TABLE, betKey)
  exchange(net)
  local entry = { g = { [1] = 20 }, b = changedId, t = officer.received[betKey] }
  T.eq(officer.sync:Get(TABLE, bookKey), entry, "a change before the close replaces the entry")
  T.ok(entry.t > firstEntry.t, "with the later time of receipt")
  T.eq({ member.model:BetState(id) }, { "accepted" }, "the changed bet is accepted")

  net:Advance(600)
  local writes = #officer.bookWrites
  -- A modified addon writes past the model, which refuses a bet after the close
  T.eq(member.sync:Put(PLAYER_TABLE, betKey, { g = { [1] = 40 } }), true, "the member changes the bet after the close")
  exchange(net)
  T.ok(officer.received[betKey] > officer.model:Event(id).c, "the officer receives the change after the close")
  T.eq(officer.sync:Get(TABLE, bookKey), entry, "a change after the close leaves the entry")
  T.eq(#officer.bookWrites, writes, "and writes nothing")
  T.eq({ member.model:BetState(id) }, { "outdated", { stakes = { [1] = 20 } } },
    "BetState says outdated, with the stakes that stay in force")
  T.eq(member.sync:Delete(PLAYER_TABLE, betKey), true, "the member deletes the bet after the close")
  exchange(net)
  T.eq(officer.sync:Get(TABLE, bookKey), entry, "a take back after the close leaves the entry too")

  -- A take back before the close deletes the entry
  local taken = officer.model:Open(spec(net, 600))
  exchange(net)
  local takenBook = data.bookKey(taken, "Nota Scam")
  member.model:PlaceBet(taken, { [2] = 5 })
  exchange(net)
  T.ok(officer.sync:Get(TABLE, takenBook), "a bet is booked")
  T.eq(member.model:TakeBack(taken), true, "and taken back before the close")
  exchange(net)
  T.eq({ officer.sync:Get(TABLE, takenBook), member.sync:Get(TABLE, takenBook) }, { nil, nil },
    "the entry is deleted everywhere")
  T.eq({ member.model:BetState(taken) }, { "none" }, "the member has no bet")

  -- A take back during the delay drops the pending booking
  officer.delay = slow
  local dropped = officer.model:Open(spec(net, 600))
  exchange(net)
  member.model:PlaceBet(dropped, { [1] = 7 })
  net:Advance(6)
  local droppedBet = data.betKey("Nota Scam", dropped)
  T.ok(officer.booker.pending[droppedBet], "the officer has a pending booking")
  T.eq(member.model:TakeBack(dropped), true, "the bet is taken back before the booking is written")
  net:Advance(16)
  T.eq(officer.booker.pending[droppedBet], nil, "the take back drops the pending booking")
  exchange(net)
  local droppedBook = data.bookKey(dropped, "Nota Scam")
  T.eq({ officer.sync:Get(TABLE, droppedBook), writesOf(officer, droppedBook) }, { nil, 0 },
    "the pending booking is dropped: no entry, and the delete found nothing to delete")
end

-- A lock: an entry received before the new close is written after it; one received after it is not
do
  local net = Fakenet.new({ random = random })
  local first = withBook(net, "Officer One", OFFICER, slow)
  local second = withBook(net, "Officer Two", SECOND_OFFICER, slow)
  local member = withBook(net, "Nota Scam")
  exchange(net)
  local data = first.ns.gambleData
  local id = first.model:Open(spec(net))
  exchange(net)
  member.model:PlaceBet(id, { [1] = 10 })
  net:Advance(7)
  local betKey = data.betKey("Nota Scam", id)
  T.ok(first.received[betKey], "the officer has received the bet")
  T.eq(first.model:Lock(id), true, "and locks the event before the booking is written")
  exchange(net)
  local entry = first.sync:Get(TABLE, data.bookKey(id, "Nota Scam"))
  local close = first.model:Event(id).c
  T.ok(entry and entry.t <= close, "the entry is written after the lock, with a time of receipt before it")
  T.eq({ member.model:BetState(id) }, { "accepted" }, "the bet is accepted")

  -- The second officer locks; the first gets the bet before it gets the lock
  local locked = first.model:Open(spec(net))
  exchange(net)
  exchange(net)
  T.ok(second.model:Event(locked) and member.model:Event(locked), "the others hold a new event")
  T.eq(second.model:Lock(locked), true, "the second officer locks it")
  local lockedAt = now(net)
  net:Advance(1)
  T.eq(member.model:PlaceBet(locked, { [1] = 10 }), true, "the member, who has not heard of the lock, bets")
  local lockedBet = data.betKey("Nota Scam", locked)
  net:Advance(6)
  T.ok(first.received[lockedBet] and first.received[lockedBet] > lockedAt,
    "the first officer receives the bet after the new close")
  T.eq(first.model:Event(locked).c > lockedAt, true, "while it still holds the old close")
  exchange(net)
  T.eq(first.model:Event(locked).c, lockedAt, "the lock arrives before the booking is due")
  T.eq(first.sync:Get(TABLE, data.bookKey(locked, "Nota Scam")), nil, "and the booking is not written")
  T.eq(writesOf(first, data.bookKey(locked, "Nota Scam")) + writesOf(second, data.bookKey(locked, "Nota Scam")), 0,
    "by neither officer")
  T.eq({ member.model:BetState(locked) }, { "late" }, "the bet is too late")
end

-- A bet that an officer receives after the close is not booked, also when its id is from before the close; a
-- hand-made push with a bet under another name gives no entry
do
  local net = Fakenet.new({ random = random })
  local officer = withBook(net, "Officer One", OFFICER)
  local member = withBook(net, "Nota Scam")
  local raw = joinRaw(net, "Raw Member")
  exchange(net)
  local data, versionId = officer.ns.gambleData, officer.ns.versionId
  local id = officer.model:Open(spec(net, 600))
  local close = officer.model:Event(id).c
  exchange(net)

  -- Before the close: the own record is booked, the forged one and the later records of its origin are dropped
  local at = now(net)
  raw:Push(PLAYER_TABLE, "XXXX", {
    { key = data.betKey("Raw Member", id), id = versionId.make(at - 3, "XXXX", 0), payload = { g = { [1] = 9 } } },
    { key = data.betKey("Nota Scam", id), id = versionId.make(at - 2, "XXXX", 0), payload = { g = { [1] = 99 } } },
  })
  exchange(net)
  T.eq(officer.sync:Get(TABLE, data.bookKey(id, "Raw Member")).g, { [1] = 9 },
    "a hand-made bet of the sender is booked")
  T.eq(officer.sync:Get(PLAYER_TABLE, data.betKey("Nota Scam", id)), nil, "a bet under another name is dropped")
  T.eq(officer.sync:Get(TABLE, data.bookKey(id, "Nota Scam")), nil, "and gives no entry")
  T.eq(member.sync:Get(TABLE, data.bookKey(id, "Nota Scam")), nil, "also on the member whose name it used")

  -- After the close, with an id from before it
  net:Advance(600)
  local late = officer.model:Open(spec(net, 600))
  exchange(net)
  local lateClose = officer.model:Event(late).c
  net:Advance(600)
  raw:Push(PLAYER_TABLE, "YYYY", {
    { key = data.betKey("Raw Member", late), id = versionId.make(lateClose - 100, "YYYY", 0),
      payload = { g = { [1] = 9 } } },
  })
  exchange(net)
  T.eq(officer.sync:Get(PLAYER_TABLE, data.betKey("Raw Member", late)), { g = { [1] = 9 } },
    "the officer holds a bet received after the close with an old id")
  T.ok(officer.received[data.betKey("Raw Member", late)] > lateClose, "received first hand after the close")
  T.eq(officer.sync:Get(TABLE, data.bookKey(late, "Raw Member")), nil, "it is not booked")
  T.ok(close < lateClose, "the first event had closed before")
end

-- A bet that an officer gets from another officer is not booked a second time
do
  local net = Fakenet.new({ random = random })
  local first = withBook(net, "Officer One", OFFICER, fast)
  local second = withBook(net, "Officer Two", SECOND_OFFICER, fast, true)
  local member = withBook(net, "Nota Scam")
  exchange(net)
  local data = first.ns.gambleData
  local id = first.model:Open(spec(net))
  exchange(net)
  member.model:PlaceBet(id, { [1] = 25 })
  exchange(net)
  local bookKey = data.bookKey(id, "Nota Scam")
  local entry = first.sync:Get(TABLE, bookKey)
  T.ok(entry, "the online officer books the bet")

  -- The second officer logs in later and gets the bet and the entry from the first
  net:Advance(100)
  login(second)
  for _ = 1, 5 do
    exchange(net)
  end
  T.ok(second.sync:Get(PLAYER_TABLE, data.betKey("Nota Scam", id)), "the second officer holds the bet")
  T.eq(second.sync:Get(TABLE, bookKey), entry, "and the entry of the first, with its time of receipt")
  T.eq(writesOf(second, bookKey), 0, "it writes no entry of its own")

  -- Both online, the member's push to the second officer is lost: it gets the bet only from the first
  net.dropIf = function(entryOfLog, to)
    return to == "Officer Two" and entryOfLog.from == "Nota Scam"
  end
  first.delay = slow
  T.eq(member.model:PlaceBet(id, { [1] = 35 }), true, "the member changes the bet")
  for _ = 1, 5 do
    exchange(net)
  end
  net.dropIf = nil
  local changed = first.sync:Get(TABLE, bookKey)
  T.eq(changed.g, { [1] = 35 }, "the first officer books the change")
  T.eq(second.received[data.betKey("Nota Scam", id)], nil, "the second officer never received it first hand")
  T.eq(second.sync:Get(TABLE, bookKey), changed, "but holds the entry of the first")
  T.eq(writesOf(second, bookKey), 0, "and writes none")
end

-- No officer online until the close: the bet is too late
do
  local net = Fakenet.new({ random = random })
  local officer = withBook(net, "Officer One", OFFICER)
  local member = withBook(net, "Nota Scam")
  exchange(net)
  local data = officer.ns.gambleData
  local id = officer.model:Open(spec(net, 600))
  exchange(net)
  logout(officer)
  T.eq(member.model:PlaceBet(id, { [1] = 10 }), true, "the member bets while no officer is online")
  exchange(net)
  T.eq({ member.model:BetState(id) }, { "waiting" }, "the bet waits")
  net:Advance(600)
  T.eq({ member.model:BetState(id) }, { "late" }, "after the close it is too late")
  login(officer)
  for _ = 1, 5 do
    exchange(net)
  end
  local betKey = data.betKey("Nota Scam", id)
  T.ok(officer.received[betKey] and officer.received[betKey] > officer.model:Event(id).c,
    "the officer who logs in after the close receives the bet first hand")
  T.eq(officer.sync:Get(TABLE, data.bookKey(id, "Nota Scam")), nil, "and does not book it")
  T.eq({ member.model:BetState(id) }, { "late" }, "the bet stays too late")
end

-- The bet arrives before its event: it waits, and is booked with the original time of receipt
do
  local net = Fakenet.new({ random = random })
  local officer = withBook(net, "Officer One", OFFICER, fast)
  local member = withBook(net, "Nota Scam")
  local rawOfficer = joinRaw(net, "Raw Officer", OFFICER)
  exchange(net)
  local data, versionId = officer.ns.gambleData, officer.ns.versionId

  ---Pushes an event as the raw officer; with `hidden` the booking officer does not get the push.
  ---@param id string
  ---@param event table
  ---@param hidden boolean
  local function pushEvent(id, event, hidden)
    net.dropIf = hidden and function(entry, to)
      return to == "Officer One" and entry.from == "Raw Officer"
    end or nil
    rawOfficer:Push(TABLE, "OOOO", { { key = data.eventKey(id), id = id, payload = event } })
    net:Advance(1)
    net.dropIf = nil
  end

  local at = now(net)
  local id = versionId.make(at, "OOOO", 0)
  local event = { n = "Raw event", o = { { n = "A", p = 50 }, { n = "B", p = 50 } }, c = at + HOUR, m = 100, s = 1,
    by = "Raw Officer" }
  pushEvent(id, event, true)
  T.ok(member.model:Event(id), "the member holds the event")
  T.eq(officer.model:Event(id), nil, "the officer does not")
  T.eq(member.model:PlaceBet(id, { [2] = 40 }), true, "the member bets")
  local betKey, bookKey = data.betKey("Nota Scam", id), data.bookKey(id, "Nota Scam")
  exchange(net)
  local receipt = officer.received[betKey]
  T.ok(receipt, "the officer receives the bet first hand")
  T.eq(officer.sync:Get(TABLE, bookKey), nil, "and books nothing without the event")
  net:Advance(100)
  pushEvent(id, event, false)
  T.ok(officer.model:Event(id), "the event arrives")
  exchange(net)
  T.eq(officer.sync:Get(TABLE, bookKey), { g = { [2] = 40 }, b = member.sync:GetId(PLAYER_TABLE, betKey), t = receipt },
    "the bet is booked with the original time of receipt")
  T.ok(receipt < now(net) - 100, "which is long before the event arrived")
  -- The officer pushes the entry only after its pull from the raw officer, which never answers, has timed out
  for _ = 1, 5 do
    exchange(net)
  end
  T.eq({ member.model:BetState(id) }, { "accepted" }, "and is accepted")

  -- The event arrives locked with a close before the receipt: no entry
  at = now(net)
  local lockedId = versionId.make(at, "OOOO", 1)
  local open = { n = "Raw event", o = event.o, c = at + HOUR, m = 100, s = 1, by = "Raw Officer" }
  pushEvent(lockedId, open, true)
  member.model:PlaceBet(lockedId, { [1] = 5 })
  exchange(net)
  local lockedReceipt = officer.received[data.betKey("Nota Scam", lockedId)]
  T.ok(lockedReceipt, "the officer receives a bet without its event")
  -- The lock is a newer write of the same key: a newer id
  rawOfficer:Push(TABLE, "OOOO", { { key = data.eventKey(lockedId), id = versionId.make(now(net), "OOOO", 2),
    payload = { n = open.n, o = open.o, c = lockedReceipt - 1, m = 100, s = 1, by = "Raw Officer" } } })
  exchange(net)
  T.eq(officer.model:Event(lockedId).c, lockedReceipt - 1, "the event arrives locked before the receipt")
  T.eq(officer.sync:Get(TABLE, data.bookKey(lockedId, "Nota Scam")), nil, "the waiting bet is not booked")
  T.eq({ member.model:BetState(lockedId) }, { "late" }, "it is too late")
end

-- A booker writes nothing after Stop, nor when its character is no longer an officer when the delay ends
do
  local net = Fakenet.new({ random = random })
  local officer = withBook(net, "Officer One", OFFICER, slow)
  local member = withBook(net, "Nota Scam")
  exchange(net)
  local data = officer.ns.gambleData
  local stopped, demoted = officer.model:Open(spec(net)), officer.model:Open(spec(net))
  exchange(net)
  member.model:PlaceBet(stopped, { [1] = 1 })
  net:Advance(8)
  T.ok(officer.received[data.betKey("Nota Scam", stopped)], "the officer receives a bet")
  officer.booker:Stop()
  exchange(net)
  T.eq(officer.sync:Get(TABLE, data.bookKey(stopped, "Nota Scam")), nil, "a stopped booker does not write it")
  startBooker(officer)
  member.model:PlaceBet(demoted, { [1] = 1 })
  net:Advance(8)
  T.ok(officer.received[data.betKey("Nota Scam", demoted)], "the officer receives another bet")
  net:SetRank("Officer One", 5)
  exchange(net)
  T.eq(officer.sync:Get(TABLE, data.bookKey(demoted, "Nota Scam")), nil, "a demoted officer does not write it")
  member.model:PlaceBet(demoted, { [1] = 2 })
  exchange(net)
  T.eq(officer.sync:Get(TABLE, data.bookKey(demoted, "Nota Scam")), nil, "nor book a new bet")
end

T.finish()
