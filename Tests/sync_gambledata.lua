-- Host test of the gambling tables (.agents/00-plan.md, sections 15.2 and 15.3, step 14.1;
-- Addon/Src/Gamble/GambleData.lua): the keys, the checks, and the write rules of the two tables.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local DATA_FILE = "Addon/Src/Gamble/GambleData.lua"
local OFFICER_RANK = 0

---Makes a replica that has the gambling tables.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return TestReplica
local function withGamble(net, name, rankIndex)
  local replica = Replica.new(net, name, { random = random, rankIndex = rankIndex })
  T.load(DATA_FILE, replica.ns)
  return replica
end

local net = Fakenet.new({ random = random })
local officer = withGamble(net, "Officer One", OFFICER_RANK)
local member = withGamble(net, "Nota Scam")
local data = officer.ns.gambleData
local versionId = officer.ns.versionId

-- An event id with `:` in it, on purpose
local EVENT = versionId.make(1795300000, "a:b:", 7)
T.ok(EVENT:find(":", 1, true) and versionId.isWellFormed(EVENT), "the test event id has a colon and is well formed")
local OTHER_EVENT = versionId.make(1795300001, "::::", 8835)
local NAME = "Nota Scam"

---Returns a valid event; a test changes a copy.
---@return table
local function event()
  return { n = "Who wins the duel on Friday?", o = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } },
    c = 1795300000, m = 100, s = 1, by = "Officer One" }
end

---Returns a valid resolved event.
---@return table
local function resolved()
  local e = event()
  e.s, e.r, e.q, e.d, e.k = 2, { true, false }, "aB3$", 3, "Officer One"
  return e
end

-- Constants
T.eq({ data.TABLE, data.PLAYER_TABLE, data.KEEP_DAYS, data.MAX_GOLD }, { "gamble", "gamble_player", 90, 100000 },
  "the names, the keeping time, and the highest stake")
T.eq({ data.MAX_OUTCOMES, data.MIN_OUTCOMES, data.CAP_BELOW, data.MAX_CAP, data.TOKEN_LENGTH }, { 8, 2, 20, 99, 4 },
  "the limits of the outcomes and the token")
T.eq({ data.STATE_OPEN, data.STATE_RESOLVED, data.STATE_CANCELLED }, { 1, 2, 3 }, "the states")

-- Keys: built and read back
do
  T.eq(data.eventKey(EVENT), "e:" .. EVENT, "an event key")
  T.eq(data.bookKey(EVENT, NAME), "b:" .. EVENT .. ":Nota Scam", "a book key")
  T.eq(data.dueKey(EVENT, 12), "d:" .. EVENT .. ":12", "a due key")
  T.eq(data.betKey(NAME, EVENT), "Nota Scam:b:" .. EVENT, "a bet key")
  T.eq(data.receiptKey(NAME, EVENT), "Nota Scam:r:" .. EVENT, "a receipt key")

  T.eq(data.parseKey("gamble", data.eventKey(EVENT)), { kind = "event", eventId = EVENT }, "an event key is read back")
  T.eq(data.parseKey("gamble", data.bookKey(EVENT, NAME)), { kind = "book", eventId = EVENT, name = NAME },
    "a book key with a space in the name is read back")
  T.eq(data.parseKey("gamble", data.dueKey(EVENT, 999)), { kind = "due", eventId = EVENT, n = 999 },
    "a due key is read back")
  T.eq(data.parseKey("gamble_player", data.betKey(NAME, EVENT)), { kind = "bet", eventId = EVENT, name = NAME },
    "a bet key is read back")
  T.eq(data.parseKey("gamble_player", data.receiptKey(NAME, OTHER_EVENT)),
    { kind = "receipt", eventId = OTHER_EVENT, name = NAME }, "a receipt key with an id of colons is read back")
  T.eq(data.parseKey("gamble", data.bookKey(OTHER_EVENT, "Æz Clap")).name, "Æz Clap", "a name with a UTF-8 letter")

  -- Broken keys
  local broken = { "", "e:", "e:" .. EVENT .. "x", "e:" .. EVENT:sub(1, 10), "x:" .. EVENT, "e" .. EVENT,
    "b:" .. EVENT, "b:" .. EVENT .. ":", "b:" .. EVENT .. "x", "b:" .. EVENT .. ":a:b", "d:" .. EVENT .. ":0",
    "d:" .. EVENT .. ":01", "d:" .. EVENT .. ":1000", "d:" .. EVENT .. ":1x", "d:" .. EVENT .. ":-1",
    "d:" .. EVENT .. ":", "d:" .. EVENT, "b:" .. EVENT .. ":" .. string.rep("n", 49), "e:" .. EVENT .. " " }
  for _, key in ipairs(broken) do
    T.eq(data.parseKey("gamble", key), nil, "the key '" .. key .. "' is refused")
  end
  local brokenPlayer = { "", ":b:" .. EVENT, NAME, NAME .. ":b:", NAME .. ":x:" .. EVENT, NAME .. ":b:" .. EVENT .. "x",
    NAME .. ":b:" .. EVENT:sub(1, 10), string.rep("n", 49) .. ":b:" .. EVENT, "e:" .. EVENT }
  for _, key in ipairs(brokenPlayer) do
    T.eq(data.parseKey("gamble_player", key), nil, "the player key '" .. key .. "' is refused")
  end
  T.eq(data.parseKey("gamble", 5), nil, "a key that is no string")
  T.eq(data.parseKey("other", data.eventKey(EVENT)), nil, "another table")
  T.eq(data.parseKey("gamble_player", data.eventKey(EVENT)), nil, "a key of one table in the other")
  T.eq(data.parseKey("gamble", data.betKey(NAME, EVENT)), nil, "and the other way")

  -- Every key fits the 64 bytes of the engine with the longest name
  local long = string.rep("n", data.MAX_NAME)
  for _, key in ipairs({ data.eventKey(EVENT), data.bookKey(EVENT, long), data.dueKey(EVENT, 999),
    data.betKey(long, EVENT), data.receiptKey(long, EVENT) }) do
    T.ok(#key <= officer.sync.MAX_KEY_LENGTH, "the key of " .. #key .. " bytes fits")
  end
  T.ok(data.parseKey("gamble", data.bookKey(EVENT, long)) and data.parseKey("gamble_player", data.betKey(long, EVENT)),
    "keys with the longest name are read")
end

-- Events
do
  local validate = data.validateGamble
  local key = data.eventKey(EVENT)
  T.ok(validate(key, event()), "an open event is valid")
  T.ok(validate(key, resolved()), "a resolved event is valid")
  local capped = event()
  capped.o[2] = { n = "Sword", p = 2, x = 10 }
  T.ok(validate(key, capped), "an outcome with p = 2 and x = 10 is valid")
  capped.o[2] = { n = "Edge", p = 19, x = 99 }
  T.ok(validate(key, capped), "a cap with p = 19 and x = 99 is valid")
  local cancelled = resolved()
  cancelled.s = 3
  T.ok(validate(key, cancelled), "a cancelled event keeps its resolution")
  cancelled = event()
  cancelled.s = 3
  T.ok(validate(key, cancelled), "a cancelled event without a resolution is valid")
  local eight = event()
  eight.o = {}
  for index = 1, 8 do
    eight.o[index] = { n = "o" .. index, p = 50 }
  end
  T.ok(validate(key, eight), "eight outcomes are valid")
  local zeroDues = resolved()
  zeroDues.d, zeroDues.r = 0, { false, false }
  T.ok(validate(key, zeroDues), "no dues and no winners are valid")

  ---Checks that a change of a valid event makes it invalid.
  ---@param name string
  ---@param change fun(e: table)
  ---@param base (fun(): table)?
  local function refused(name, change, base)
    local e = (base or event)()
    change(e)
    T.eq(validate(key, e), false, name .. " is refused")
  end
  refused("a title that is a number", function(e) e.n = 5 end)
  refused("an empty title", function(e) e.n = "" end)
  refused("a title of 81 bytes", function(e) e.n = string.rep("t", 81) end)
  refused("a title that is a table", function(e) e.n = {} end)
  refused("no outcomes", function(e) e.o = nil end)
  refused("one outcome", function(e) e.o = { { n = "A", p = 50 } } end)
  refused("nine outcomes", function(e)
    e.o = {}
    for index = 1, 9 do
      e.o[index] = { n = "o", p = 50 }
    end
  end)
  refused("outcomes with a gap", function(e) e.o = { { n = "A", p = 50 }, [3] = { n = "B", p = 50 } } end)
  refused("outcomes with another key", function(e) e.o.extra = { n = "B", p = 50 } end)
  refused("a chance of 0", function(e) e.o[1].p = 0 end)
  refused("a chance of 100", function(e) e.o[1].p = 100 end)
  refused("a fractional chance", function(e) e.o[1].p = 50.5 end)
  refused("a chance that is a string", function(e) e.o[1].p = "50" end)
  refused("a chance that is NaN", function(e) e.o[1].p = 0 / 0 end)
  refused("a cap on a chance of 20", function(e) e.o[1] = { n = "A", p = 20, x = 5 } end)
  refused("a cap on a chance of 60", function(e) e.o[1].x = 5 end)
  refused("a cap of 0", function(e) e.o[1] = { n = "A", p = 2, x = 0 } end)
  refused("a cap of 100", function(e) e.o[1] = { n = "A", p = 2, x = 100 } end)
  refused("a cap that is a fraction", function(e) e.o[1] = { n = "A", p = 2, x = 1.5 } end)
  refused("an outcome with another field", function(e) e.o[1].z = 1 end)
  refused("an outcome that is a string", function(e) e.o[1] = "A" end)
  refused("an outcome name of 41 bytes", function(e) e.o[1].n = string.rep("n", 41) end)
  refused("an empty outcome name", function(e) e.o[1].n = "" end)
  refused("a close of 0", function(e) e.c = 0 end)
  refused("a close that is a fraction", function(e) e.c = 1.5 end)
  refused("a close that is a string", function(e) e.c = "1795300000" end)
  refused("a highest stake of 0", function(e) e.m = 0 end)
  refused("a highest stake above the limit", function(e) e.m = 100001 end)
  refused("a state of 0", function(e) e.s = 0 end)
  refused("a state of 4", function(e) e.s = 4 end)
  refused("a state that is a string", function(e) e.s = "1" end)
  refused("no opener", function(e) e.by = nil end)
  refused("an opener with a colon", function(e) e.by = "a:b" end)
  refused("an opener of 49 bytes", function(e) e.by = string.rep("n", 49) end)
  refused("another field", function(e) e.z = 1 end)
  refused("an open event with a resolution", function(e) e.r, e.q, e.d, e.k = { true, false }, "aB3$", 1, "B" end)
  refused("a resolved event without a resolution", function(e) e.s = 2 end)
  refused("a resolution with a missing token", function(e) e.q = nil end, resolved)
  refused("a resolution with a missing banker", function(e) e.k = nil end, resolved)
  refused("a resolution with a missing count", function(e) e.d = nil end, resolved)
  refused("a resolution with no result list", function(e) e.r = nil end, resolved)
  refused("a result list that is too short", function(e) e.r = { true } end, resolved)
  refused("a result list that is too long", function(e) e.r = { true, false, true } end, resolved)
  refused("a result that is a number", function(e) e.r = { 1, 0 } end, resolved)
  refused("a result list with a gap", function(e) e.r = { true, [3] = false } end, resolved)
  refused("a token of 3 characters", function(e) e.q = "aB3" end, resolved)
  refused("a token with a space", function(e) e.q = "aB 3" end, resolved)
  refused("a token that is a number", function(e) e.q = 1234 end, resolved)
  refused("1000 dues", function(e) e.d = 1000 end, resolved)
  refused("-1 dues", function(e) e.d = -1 end, resolved)
  refused("a fractional number of dues", function(e) e.d = 1.5 end, resolved)
  refused("a banker with a colon", function(e) e.k = "a:b" end, resolved)
  T.eq(validate(key, "text"), false, "a payload that is a string")
  T.eq(validate(key, nil), false, "a payload of nil")
  T.eq(validate(key, 5), false, "a payload that is a number")
  T.eq(validate("e:broken", event()), false, "a broken key")
  T.eq(validate(5, event()), false, "a key that is a number")
  T.eq(validate(nil, event()), false, "a key of nil")
  T.eq(validate(data.betKey(NAME, EVENT), event()), false, "a bet key for an event")
  T.eq(validate(data.bookKey(EVENT, NAME), event()), false, "a book key for an event")
end

-- Book entries, dues, bets, receipts
do
  local validate, validatePlayer = data.validateGamble, data.validatePlayer
  local book = data.bookKey(EVENT, NAME)
  local entry = { g = { [1] = 20, [2] = 5 }, b = OTHER_EVENT, t = 1795299000 }
  T.ok(validate(book, entry), "a book entry is valid")
  T.eq(validate(data.eventKey(EVENT), entry), false, "a book entry under an event key")
  T.eq(validate(book, { g = { [1] = 20 }, b = OTHER_EVENT }), false, "a book entry without a time")
  T.eq(validate(book, { g = { [1] = 20 }, b = "short", t = 1 }), false, "a book entry with a short bet id")
  T.eq(validate(book, { g = { [1] = 20 }, b = OTHER_EVENT, t = 0 }), false, "a book entry with a time of 0")
  T.eq(validate(book, { g = { [1] = 20 }, b = OTHER_EVENT, t = 1, z = 1 }), false, "a book entry with another field")
  T.eq(validate(book, { g = { [1] = 0 }, b = OTHER_EVENT, t = 1 }), false, "a book entry with a stake of 0")
  T.eq(validate(book, { g = {}, b = OTHER_EVENT, t = 1 }), false, "a book entry without stakes")

  local due = data.dueKey(EVENT, 3)
  T.ok(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 20 }), "a due is valid")
  T.ok(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 800000, k = true }), "a bank due is valid")
  T.eq(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 800001 }), false, "a due above the limit")
  T.eq(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 0 }), false, "a due of 0 gold")
  T.eq(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 1.5 }), false, "a due of 1.5 gold")
  T.eq(validate(due, { q = "aB3$", f = "Nota Scam", t = "Officer One", g = 5, k = false }), false, "k = false")
  T.eq(validate(due, { q = "aB3$", f = "Nota Scam", g = 5 }), false, "a due without a receiver")
  T.eq(validate(due, { q = "aB3", f = "Nota Scam", t = "Officer One", g = 5 }), false, "a due with a short token")
  T.eq(validate(due, { q = "aB3$", f = "a:b", t = "Officer One", g = 5 }), false, "a payer with a colon")
  T.eq(validate(due, { q = "aB3$", f = "N", t = "O", g = 5, z = 1 }), false, "a due with another field")
  T.eq(validate(data.dueKey(EVENT, "03"), { q = "aB3$", f = "N", t = "O", g = 5 }), false, "a due with a broken key")

  local bet = data.betKey(NAME, EVENT)
  T.ok(validatePlayer(bet, { g = { [1] = 20 } }), "a bet is valid")
  T.ok(validatePlayer(bet, { g = { [8] = 100000, [1] = 1 } }), "a bet on outcome 8 with the highest stake")
  T.eq(validatePlayer(bet, { g = { [1] = 0 } }), false, "a stake of 0")
  T.eq(validatePlayer(bet, { g = { [1] = 100001 } }), false, "a stake above the limit")
  T.eq(validatePlayer(bet, { g = { [1] = 2.5 } }), false, "a fractional stake")
  T.eq(validatePlayer(bet, { g = { [1] = "5" } }), false, "a stake that is a string")
  T.eq(validatePlayer(bet, { g = { [0] = 5 } }), false, "outcome 0")
  T.eq(validatePlayer(bet, { g = { [9] = 5 } }), false, "outcome 9")
  T.eq(validatePlayer(bet, { g = { [1.5] = 5 } }), false, "outcome 1.5")
  T.eq(validatePlayer(bet, { g = { a = 5 } }), false, "an outcome that is a name")
  T.eq(validatePlayer(bet, { g = {} }), false, "a bet without stakes")
  T.eq(validatePlayer(bet, {}), false, "a bet without a map")
  T.eq(validatePlayer(bet, { g = { [1] = 5 }, z = 1 }), false, "a bet with another field")
  T.eq(validatePlayer(bet, { g = 5 }), false, "a map that is a number")
  T.eq(validatePlayer(bet, "text"), false, "a bet that is a string")
  T.eq(validatePlayer(NAME .. ":b:broken", { g = { [1] = 5 } }), false, "a bet with a broken key")
  T.eq(validatePlayer(data.receiptKey(NAME, EVENT), { g = { [1] = 5 } }), false, "a bet under a receipt key")

  local receipt = data.receiptKey(NAME, EVENT)
  T.ok(validatePlayer(receipt, { q = "aB3$", n = { [1] = true, [999] = true } }), "a receipt is valid")
  T.ok(validatePlayer(receipt, { q = "aB3$", n = {} }), "a receipt without dues is valid")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = { [0] = true } }), false, "due 0")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = { [1000] = true } }), false, "due 1000")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = { [1] = false } }), false, "a due marked false")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = { [1] = 1 } }), false, "a due marked 1")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = { x = true } }), false, "a due that is a name")
  T.eq(validatePlayer(receipt, { q = "aB3$" }), false, "a receipt without the map")
  T.eq(validatePlayer(receipt, { n = {} }), false, "a receipt without a token")
  T.eq(validatePlayer(receipt, { q = "aB3$", n = {}, z = 1 }), false, "a receipt with another field")
  T.eq(validatePlayer(bet, { q = "aB3$", n = {} }), false, "a receipt under a bet key")

  -- Nothing raises, whatever the input
  local inputs = { {}, "x", 5, true, 0 / 0, math.huge, { {} }, { g = { {} } }, { g = { [{}] = 1 } }, { n = {}, o = {} },
    { n = {}, o = { {}, {} }, c = {}, m = {}, s = {}, by = {} }, { q = {}, f = {}, t = {}, g = {} },
    { q = {}, n = { [{}] = {} } }, { g = { [1] = 0 / 0 } }, { g = { [math.huge] = 1 } } }
  local keys = { data.eventKey(EVENT), book, due, bet, receipt, {}, 5, true }
  local raised = 0
  for _, key in ipairs(keys) do
    for _, input in ipairs(inputs) do
      if not pcall(validate, key, input) or not pcall(validatePlayer, key, input) then
        raised = raised + 1
      end
    end
  end
  T.eq(raised, 0, "no input makes a check raise")
end

-- The registration
do
  local definition = officer.sync.definitions.gamble
  T.eq({ definition.schema, definition.keyKind, definition.maxRecordBytes, definition.writers, definition.maxAge },
    { 1, "free", 1500, "officer", 90 * 86400 }, "the table gamble is registered")
  T.eq(definition.policy, { when = "nocombat", pushDelay = 10, minInterval = 30 }, "with its policy")
  definition = officer.sync.definitions.gamble_player
  T.eq({ definition.schema, definition.keyKind, definition.maxRecordBytes, definition.writers, definition.maxAge },
    { 1, "character", 300, "self", 90 * 86400 }, "the table gamble_player is registered")
  T.eq(definition.policy, { when = "nocombat", pushDelay = 5, minInterval = 15 }, "with its policy")
end

-- The write rules, with the real registry
do
  local eventKey = data.eventKey(EVENT)
  T.eq({ member.sync:Put("gamble", eventKey, event()) }, { nil, "not an officer" }, "a member cannot write an event")
  T.eq(member.sync:Get("gamble", eventKey), nil, "and nothing is stored")
  T.eq(officer.sync:Put("gamble", eventKey, event()), true, "an officer writes an event")
  T.eq(officer.sync:Get("gamble", eventKey), event(), "and it is stored")
  T.eq({ officer.sync:Put("gamble", eventKey, { n = "x" }) }, { nil, "bad payload" },
    "an officer cannot write a bad one")
  T.eq(officer.sync:Put("gamble", data.dueKey(EVENT, 1), { q = "aB3$", f = NAME, t = "Officer One", g = 5 }), true,
    "an officer writes a due")

  local bet = { g = { [1] = 20 } }
  T.eq({ member.sync:Put("gamble_player", data.betKey("Officer One", EVENT), bet) }, { nil, "not the owner" },
    "a character cannot write the bet of another")
  T.eq(member.sync:Put("gamble_player", data.betKey(NAME, EVENT), bet), true, "and can write the own")
  T.eq(member.sync:Get("gamble_player", data.betKey(NAME, EVENT)), bet, "which is stored")
  T.eq({ member.sync:Put("gamble_player", data.receiptKey("Officer One", EVENT), { q = "aB3$", n = {} }) },
    { nil, "not the owner" }, "nor the receipts of another")
  T.eq(member.sync:Put("gamble_player", data.receiptKey(NAME, EVENT), { q = "aB3$", n = { [1] = true } }), true,
    "the own receipts are written")
  T.eq({ member.sync:Put("gamble_player", data.betKey(NAME, EVENT), { g = { [1] = 0 } }) }, { nil, "bad payload" },
    "a bet of stake 0 is refused")
  T.eq(officer.sync:Put("gamble_player", data.betKey("Officer One", EVENT), bet), true, "an officer bets as itself")
end

T.finish()
