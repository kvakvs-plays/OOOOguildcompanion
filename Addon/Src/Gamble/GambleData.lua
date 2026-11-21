local addonName, ns = ...

-- The tables of the gambling feature (.agents/00-plan.md, sections 15.2 and 15.3): the events, the book, and the
-- dues in `gamble`, written by officers; the bets and the receipts of each character in `gamble_player`.
-- This file holds the keys and the checks of their records. A check sees one record only: it cannot compare a
-- stake with the outcomes of its event; the reader does that.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_gambledata.lua).

---@class OOOOGambleOutcome One outcome of an event
---@field n string Name, 1 to `MAX_OUTCOME_NAME` bytes
---@field p integer Chance in whole percent, 1 to 99
---@field x integer|nil Cap of the profit as a multiple of the stake, 1 to 99; only with `p` under `CAP_BELOW`

---@class OOOOGambleEvent Payload of the key `e:<event id>`
---@field n string Title, 1 to `MAX_TITLE` bytes
---@field o OOOOGambleOutcome[] 2 to 8 outcomes
---@field c integer Close: server time after which no bet counts
---@field m integer Highest stake of one character on one outcome
---@field s integer State: `STATE_OPEN`, `STATE_RESOLVED`, or `STATE_CANCELLED`
---@field by string Name of the officer who opened the event
---@field r boolean[]|nil Result per outcome; present with `q`, `d`, and `k`
---@field q string|nil Settlement token
---@field d integer|nil Number of dues
---@field k string|nil Name of the banker

---@class OOOOGambleBookEntry Payload of the key `b:<event id>:<name>`
---@field g table<integer, integer> Outcome index -> gold
---@field b string Version id of the bet record
---@field t integer Server time at which an officer received the bet

---@class OOOOGambleDue Payload of the key `d:<event id>:<n>`
---@field q string Settlement token
---@field f string Name of the payer
---@field t string Name of the receiver
---@field g integer Gold
---@field k true|nil true for the share of the guild bank

---@class OOOOGambleReceipt Payload of the key `<name>:r:<event id>`
---@field q string Settlement token
---@field n table<integer, true> Due number -> true for a due that the character has received

---@class OOOOGambleKey The parts of a parsed key
---@field kind string "event", "book", "due", "bet", or "receipt"
---@field eventId string Version id of the event
---@field name string|nil Character name; in the kinds "book", "bet", and "receipt"
---@field n integer|nil Due number; in the kind "due"

---@class OOOOGambleData
local data = {}
ns.gambleData = data

local base94 = ns.base94
local versionId = ns.versionId

---Name of the table of the events, the book, and the dues
data.TABLE = "gamble"
---Name of the table of the bets and the receipts
data.PLAYER_TABLE = "gamble_player"
---Days that a record is kept after its last write
data.KEEP_DAYS = 90
---Highest gold amount of a stake
data.MAX_GOLD = 100000
---Most outcomes of an event
data.MAX_OUTCOMES = 8
---Fewest outcomes of an event
data.MIN_OUTCOMES = 2
---Longest title of an event, in bytes
data.MAX_TITLE = 80
---Longest name of an outcome, in bytes
data.MAX_OUTCOME_NAME = 40
---Longest character name, in bytes; with it every key fits the 64 bytes of the engine
data.MAX_NAME = 48
---An outcome with a chance under this many percent can carry a cap
data.CAP_BELOW = 20
---Highest cap, as a multiple of the stake
data.MAX_CAP = 99
---Farthest close of an event, in seconds after it is opened
data.MAX_CLOSE_AHEAD = 30 * 86400
---State of an event: bets are taken
data.STATE_OPEN = 1
---State of an event: the result is known
data.STATE_RESOLVED = 2
---State of an event: nothing is owed
data.STATE_CANCELLED = 3
---Characters of a settlement token
data.TOKEN_LENGTH = 4

local ID_LENGTH = versionId.LENGTH
local MAX_DUE_NUMBER = 999

---Tells whether a value is an integer within a range; false for NaN, fractions, and other types.
---@param value any
---@param low integer
---@param high integer
---@return boolean
local function isInteger(value, low, high)
  return type(value) == "number" and value >= low and value <= high and value == math.floor(value)
end

---Tells whether a value is a string of 1 to `max` bytes.
---@param value any
---@param max integer
---@return boolean
local function isText(value, max)
  return type(value) == "string" and #value >= 1 and #value <= max
end

---Tells whether a value can be a character name: 1 to `MAX_NAME` bytes, no `:`.
---@param value any
---@return boolean
local function isName(value)
  return isText(value, data.MAX_NAME) and not value:find(":", 1, true)
end

---Tells whether a value is a settlement token: 4 base-94 characters.
---@param value any
---@return boolean
local function isToken(value)
  return type(value) == "string" and #value == data.TOKEN_LENGTH and base94.isValid(value)
end

---Tells whether a table is a list: the keys 1 to n and nothing else.
---@param value any
---@return boolean
local function isList(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  -- The length of a table with gaps is any border, so every index up to it is checked too
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

---Tells whether every field of a table is in a list of names.
---@param payload table
---@param allowed table<string, boolean>
---@return boolean
local function onlyFields(payload, allowed)
  for field in pairs(payload) do
    if not allowed[field] then
      return false
    end
  end
  return true
end

---Builds the key of an event.
---@param eventId string Version id
---@return string
function data.eventKey(eventId)
  return "e:" .. eventId
end

---Builds the key of the book entry of a bettor in an event.
---@param eventId string Version id
---@param name string Character name
---@return string
function data.bookKey(eventId, name)
  return "b:" .. eventId .. ":" .. name
end

---Builds the key of a due.
---@param eventId string Version id
---@param n integer Due number, from 1
---@return string
function data.dueKey(eventId, n)
  return "d:" .. eventId .. ":" .. n
end

---Builds the key of the bet of a character in an event.
---@param name string Character name
---@param eventId string Version id
---@return string
function data.betKey(name, eventId)
  return name .. ":b:" .. eventId
end

---Builds the key of the receipts of a character in an event.
---@param name string Character name
---@param eventId string Version id
---@return string
function data.receiptKey(name, eventId)
  return name .. ":r:" .. eventId
end

---Reads a key of the table `gamble` by position, because an event id can contain `:`.
---@param key string
---@return OOOOGambleKey|nil
local function parseGambleKey(key)
  local prefix = key:sub(1, 2)
  if prefix ~= "e:" and prefix ~= "b:" and prefix ~= "d:" then
    return nil
  end
  local eventId = key:sub(3, 2 + ID_LENGTH)
  if not versionId.isWellFormed(eventId) then
    return nil
  end
  local rest = key:sub(3 + ID_LENGTH)
  if prefix == "e:" then
    return rest == "" and { kind = "event", eventId = eventId } or nil
  end
  if rest:sub(1, 1) ~= ":" then
    return nil
  end
  rest = rest:sub(2)
  if prefix == "b:" then
    return isName(rest) and { kind = "book", eventId = eventId, name = rest } or nil
  end
  -- No leading zero, so that one due has one key
  if #rest > 3 or not rest:match("^[1-9]%d*$") then
    return nil
  end
  return { kind = "due", eventId = eventId, n = tonumber(rest) }
end

---Reads a key of the table `gamble_player`: the name up to the first `:`, `b:` or `r:`, and the event id.
---@param key string
---@return OOOOGambleKey|nil
local function parsePlayerKey(key)
  local name, letter, eventId = key:match("^([^:]+):([br]):(.*)$")
  if not name or #name > data.MAX_NAME or not versionId.isWellFormed(eventId) then
    return nil
  end
  return { kind = letter == "b" and "bet" or "receipt", eventId = eventId, name = name }
end

---Reads a key of one of the two tables.
---@param tableName any `TABLE` or `PLAYER_TABLE`
---@param key any
---@return OOOOGambleKey|nil parts nil for a key of another form, also one with trailing characters
function data.parseKey(tableName, key)
  if type(key) ~= "string" then
    return nil
  end
  if tableName == data.TABLE then
    return parseGambleKey(key)
  elseif tableName == data.PLAYER_TABLE then
    return parsePlayerKey(key)
  end
  return nil
end

---Tells whether a value is a stake map: 1 to 8 entries, outcome index 1 to 8 -> gold 1 to `MAX_GOLD`.
---@param value any
---@return boolean
local function isStakeMap(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for outcome, gold in pairs(value) do
    count = count + 1
    if not isInteger(outcome, 1, data.MAX_OUTCOMES) or not isInteger(gold, 1, data.MAX_GOLD) then
      return false
    end
  end
  return count >= 1 and count <= data.MAX_OUTCOMES
end

---Tells whether a value is one outcome of an event.
---@param outcome any
---@return boolean
local function isOutcome(outcome)
  if type(outcome) ~= "table" or not onlyFields(outcome, { n = true, p = true, x = true }) then
    return false
  end
  if not isText(outcome.n, data.MAX_OUTCOME_NAME) or not isInteger(outcome.p, 1, 99) then
    return false
  end
  return outcome.x == nil or (outcome.p < data.CAP_BELOW and isInteger(outcome.x, 1, data.MAX_CAP))
end

---Tells whether a value is the list of the outcomes of an event.
---@param list any
---@return boolean
local function isOutcomeList(list)
  if not isList(list) or #list < data.MIN_OUTCOMES or #list > data.MAX_OUTCOMES then
    return false
  end
  for _, outcome in ipairs(list) do
    if not isOutcome(outcome) then
      return false
    end
  end
  return true
end

---Tells whether the result list has one boolean per outcome.
---@param results any
---@param count integer
---@return boolean
local function isResultList(results, count)
  if not isList(results) or #results ~= count then
    return false
  end
  for _, result in ipairs(results) do
    if type(result) ~= "boolean" then
      return false
    end
  end
  return true
end

local EVENT_FIELDS = { n = true, o = true, c = true, m = true, s = true, by = true, r = true, q = true, d = true,
  k = true }

---Checks the payload of an event.
---@param event any
---@return boolean
local function isEvent(event)
  if type(event) ~= "table" or not onlyFields(event, EVENT_FIELDS) then
    return false
  end
  if not isText(event.n, data.MAX_TITLE) or not isOutcomeList(event.o) or not isInteger(event.c, 1, 2 ^ 52)
    or not isInteger(event.m, 1, data.MAX_GOLD) or not isInteger(event.s, data.STATE_OPEN, data.STATE_CANCELLED)
    or not isName(event.by) then
    return false
  end
  -- The resolved fields come all together or not at all
  local present = (event.r ~= nil and 1 or 0) + (event.q ~= nil and 1 or 0) + (event.d ~= nil and 1 or 0)
    + (event.k ~= nil and 1 or 0)
  if present == 0 then
    -- A resolution is required only in the state "resolved"
    return event.s ~= data.STATE_RESOLVED
  end
  if present ~= 4 or event.s == data.STATE_OPEN then
    return false
  end
  return isResultList(event.r, #event.o) and isToken(event.q) and isInteger(event.d, 0, 999) and isName(event.k)
end

---Checks the payload of a book entry.
---@param entry any
---@return boolean
local function isBookEntry(entry)
  return type(entry) == "table" and onlyFields(entry, { g = true, b = true, t = true }) and isStakeMap(entry.g)
    and versionId.isWellFormed(entry.b) and isInteger(entry.t, 1, 2 ^ 52)
end

---Checks the payload of a due.
---@param due any
---@return boolean
local function isDue(due)
  return type(due) == "table" and onlyFields(due, { q = true, f = true, t = true, g = true, k = true })
    and isToken(due.q) and isName(due.f) and isName(due.t) and isInteger(due.g, 1, data.MAX_GOLD * 8)
    and (due.k == nil or due.k == true)
end

---Checks the payload of the receipts of a character.
---@param receipt any
---@return boolean
local function isReceipt(receipt)
  if type(receipt) ~= "table" or not onlyFields(receipt, { q = true, n = true }) or not isToken(receipt.q)
    or type(receipt.n) ~= "table" then
    return false
  end
  for number, flag in pairs(receipt.n) do
    if not isInteger(number, 1, MAX_DUE_NUMBER) or flag ~= true then
      return false
    end
  end
  return true
end

---Checks a record of the table `gamble`: the form of the key, and the types and ranges of the payload of its
---kind. Never raises, whatever the input.
---@param key any
---@param payload any
---@return boolean
function data.validateGamble(key, payload)
  local parts = data.parseKey(data.TABLE, key)
  if not parts then
    return false
  elseif parts.kind == "event" then
    return isEvent(payload)
  elseif parts.kind == "book" then
    return isBookEntry(payload)
  end
  return isDue(payload)
end

---Checks a record of the table `gamble_player`: the form of the key, and the types and ranges of the payload
---of its kind. Never raises, whatever the input.
---@param key any
---@param payload any
---@return boolean
function data.validatePlayer(key, payload)
  local parts = data.parseKey(data.PLAYER_TABLE, key)
  if not parts then
    return false
  elseif parts.kind == "bet" then
    return type(payload) == "table" and onlyFields(payload, { g = true }) and isStakeMap(payload.g)
  end
  return isReceipt(payload)
end

ns.sync:RegisterTable({
  name = data.TABLE,
  schema = 1,
  -- No roster cleanup: the due of a member who left stays visible
  keyKind = "free",
  validate = data.validateGamble,
  maxRecordBytes = 1500,
  writers = "officer",
  maxAge = data.KEEP_DAYS * 86400,
  -- Fast, because a lock must reach the other officers before their bookers act on a change that came after it
  -- (GambleBook.lua, `CHANGE_HOLD`); the records are few and small
  policy = { when = "nocombat", pushDelay = 2, minInterval = 5 },
})

ns.sync:RegisterTable({
  name = data.PLAYER_TABLE,
  schema = 1,
  -- The key starts with the character name, so the owner rule and the roster cleanup apply
  keyKind = "character",
  validate = data.validatePlayer,
  maxRecordBytes = 300,
  writers = "self",
  maxAge = data.KEEP_DAYS * 86400,
  policy = { when = "nocombat", pushDelay = 5, minInterval = 15 },
})
