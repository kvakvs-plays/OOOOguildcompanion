local addonName, ns = ...

-- The model of the gambling feature, without frames (.agents/00-plan.md, sections 15.3 to 15.6, steps 14.3 and
-- 14.5): the officers open, lock, resolve, and cancel events; every member places and takes back the own bet and
-- confirms the dues that it received; and the reading of the events, of one event, of the state of the own bet,
-- and of the result with its dues.
--
-- Every write checks the state of the event (15.3) before it is made. A stored record has passed the check of
-- its kind (GambleData.lua), but a check sees one record only: this reader compares a book entry or a bet with
-- its event and ignores what does not fit.
--
-- The written dues are the settlement (15.5): a reader takes the dues `1..d` whose token equals the event's and
-- never computes them again. A cancelled event owes nothing, whatever dues are stored.
--
-- This file uses no WoW API at file scope, so the host tests load it (Tests/sync_gamble.lua).

---@class OOOOGambleParts What a gambling model is built from
---@field sync OOOOSync
---@field now fun(): integer Server time in seconds
---@field playerName fun(): string|nil Name of the logged-in character as the roster shows it
---@field sanitize fun(text: string): string Makes an untrusted text safe to show (`ns.mentions.sanitize`)
---@field random fun(m: integer, n: integer): integer Like math.random(m, n); makes the settlement tokens
---@field isOfficer (fun(name: string): boolean)|nil Tells whether the roster shows a character with an officer
---rank; without it only the own character can be the banker of a resolution

---@class OOOOGambleSpec What an officer gives to open an event
---@field title string 1 to `MAX_TITLE` bytes
---@field outcomes OOOOGambleOutcome[] 2 to 8 outcomes `{ n, p, x? }`
---@field close integer Server time after now, at most `MAX_CLOSE_AHEAD` ahead
---@field maxStake integer Highest stake of one character on one outcome, 1 to `MAX_GOLD`

---@class OOOOGambleListEntry One event in a group of `Events`
---@field id string Event id
---@field event OOOOGambleEvent The stored payload: do not change it

---@class OOOOGambleGroups The events in the four groups of the window, each newest first
---@field open OOOOGambleListEntry[] Bets are taken
---@field waiting OOOOGambleListEntry[] Closed, waiting for the resolution
---@field toPay OOOOGambleListEntry[] Resolved, with a due that is not confirmed or a due that is not held yet
---@field done OOOOGambleListEntry[] Cancelled, or resolved with every due confirmed (also with no dues)

---@class OOOOGambleDetailOutcome One outcome as the window shows it
---@field n string Name, sanitized
---@field p integer Chance in whole percent
---@field x integer|nil Cap of the profit as a multiple of the stake
---@field booked integer|nil Sum of the valid booked stakes; nil while the event is open
---@field own integer|nil Stake of the own bet record on this outcome

---@class OOOOGambleDetail What the window shows for one event
---@field id string Event id
---@field title string Sanitized
---@field by string Name of the officer who opened it, sanitized
---@field outcomes OOOOGambleDetailOutcome[]
---@field close integer Server time of the close
---@field maxStake integer
---@field state "open"|"locked"|"resolved"|"cancelled"
---@field betState OOOOGambleBetState|nil
---@field betInfo OOOOGambleBetInfo|nil

---@alias OOOOGambleBetState "none"|"accepted"|"waiting"|"late"|"outdated"

---@class OOOOGambleBetInfo Extra facts of a bet state
---@field stakes table<integer, integer> The booked stakes that stay in force (state "outdated")

---@class OOOOGambleResultDue One due as the window shows it
---@field n integer Due number
---@field from string Payer, sanitized
---@field to string Receiver, sanitized; the banker for a bank due
---@field gold integer
---@field bank boolean The gold is the share of the guild bank
---@field confirmed boolean The receiver has confirmed it with a receipt of the current token
---@field mine "pay"|"receive"|nil The own character pays it ("pay" also for a bank due that names the banker on
---both sides), or receives it
---@field confirmable boolean The own character is its receiver, so `Confirm` and `Unconfirm` take it

---@class OOOOGambleResult The result of a resolved or cancelled event as the window shows it
---@field state "loading"|"ready"|"cancelled" "loading": fewer than `count` dues of the token are held, and the
---lists are empty; "cancelled": nobody owes anything, and the lists are empty
---@field results boolean[]|nil Result per outcome; nil for a cancelled event
---@field banker string|nil Name of the banker, sanitized; nil for a cancelled event
---@field held integer Dues of the current token that this replica holds
---@field count integer Dues that the resolution wrote
---@field dues OOOOGambleResultDue[] Every due, in the order of n
---@field ownDues OOOOGambleResultDue[] The dues that name the own character, in the order of n
---@field net integer|nil Received minus paid over the own dues, bank dues left out; nil while loading
---@field bankHeld integer|nil Gold of the bank dues that the own character receives as banker; nil while loading
---@field settled boolean Every due is confirmed; true with no dues; false while loading
---@field booked boolean The own character has a valid book entry (`t <= c`)
---@field inSettlement boolean|nil Whether the settlement counted the own bet; nil while loading. See `Result`.
---@field mismatch boolean|nil The dues that a settlement over the book that this replica holds now would give
---differ from the written ones: the resolving officer lacked a book entry, or this replica lacks one

---@class OOOOGamblePreview What the window shows before an officer resolves an event
---@field bets integer Characters with a valid book entry
---@field sum integer Gold of all valid booked stakes
---@field behind boolean A peer has announced a newer state of the book that no online officer can supply

---@class OOOOGambleHeldDue A stored due of the token in force, with its confirmation
---@field n integer Due number
---@field due OOOOGambleDue The stored payload: do not change it
---@field confirmed boolean

---@class OOOOGambleHeldSettlement The dues of the token in force of a resolved event that a replica holds
---@field dues OOOOGambleHeldDue[] In the order of n
---@field held integer
---@field ready boolean Every due of the token is held
---@field settled boolean Ready, and every due is confirmed

---@class OOOOGambleModule
---@field current OOOOGamble|nil The model of the game, made by `Start`
local gamble = {}
ns.gamble = gamble

local data = ns.gambleData
local gambleSettle = ns.gambleSettle
local TABLE, PLAYER_TABLE = data.TABLE, data.PLAYER_TABLE
---Most dues of one resolution: the highest due number that a key and the event field `d` take
local MAX_DUES = 999
---Lowest and highest byte of a base-94 character
local FIRST_BYTE, LAST_BYTE = 33, 126

---Tells whether a value is an integer within a range; false for NaN, fractions, and other types.
---@param value any
---@param low number
---@param high number
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

---Tells the state of an event at a time (15.3): open before `c`, locked from `c` on until it is resolved.
---@param event OOOOGambleEvent
---@param now integer
---@return "open"|"locked"|"resolved"|"cancelled"
local function stateOf(event, now)
  if event.s == data.STATE_CANCELLED then
    return "cancelled"
  elseif event.s == data.STATE_RESOLVED then
    return "resolved"
  end
  return now < event.c and "open" or "locked"
end

---The reason of a refusal for each state of an event that does not take the write
local REFUSAL = { locked = "closed", resolved = "resolved", cancelled = "cancelled" }

---Tells whether a value can be a character name: 1 to `MAX_NAME` bytes, no `:`.
---@param value any
---@return boolean
local function isName(value)
  return isText(value, data.MAX_NAME) and not value:find(":", 1, true)
end

---Reads the dues of the token in force of a resolved event and their confirmations (15.6). A due counts when
---its token is the event's; a receipt counts when its token is the event's, and it is read only from the record
---of the receiver that the due names, which the self rule lets nobody else write.
---@param sync OOOOSync
---@param eventId string
---@param event OOOOGambleEvent With `s = STATE_RESOLVED`
---@return OOOOGambleHeldSettlement
local function readSettlement(sync, eventId, event)
  local dues, receipts = {}, {}
  local allConfirmed = true
  for n = 1, event.d do
    local due = sync:Get(TABLE, data.dueKey(eventId, n))
    if type(due) == "table" and due.q == event.q then
      local receipt = receipts[due.t]
      if receipt == nil then
        receipt = sync:Get(PLAYER_TABLE, data.receiptKey(due.t, eventId))
        if type(receipt) ~= "table" or receipt.q ~= event.q or type(receipt.n) ~= "table" then
          receipt = false
        end
        receipts[due.t] = receipt
      end
      local confirmed = receipt ~= false and receipt.n[n] == true
      allConfirmed = allConfirmed and confirmed
      dues[#dues + 1] = { n = n, due = due, confirmed = confirmed }
    end
  end
  local ready = #dues == event.d
  return { dues = dues, held = #dues, ready = ready, settled = ready and allConfirmed }
end

---Tells the group of the window that an event belongs to: a resolved event moves from "toPay" to "done" when
---every due of its token is held and confirmed. This is the one place for that decision.
---@param sync OOOOSync
---@param eventId string
---@param event OOOOGambleEvent
---@param now integer
---@return "open"|"waiting"|"toPay"|"done"
local function groupOf(sync, eventId, event, now)
  local state = stateOf(event, now)
  if state == "open" then
    return "open"
  elseif state == "locked" then
    return "waiting"
  elseif state == "resolved" then
    return readSettlement(sync, eventId, event).settled and "done" or "toPay"
  end
  return "done"
end

---Tells whether a stake map fits its event: every outcome exists and every stake is 1 to `m`.
---@param stakes any
---@param event OOOOGambleEvent
---@return boolean
local function fitsEvent(stakes, event)
  if type(stakes) ~= "table" or next(stakes) == nil then
    return false
  end
  for outcome, gold in pairs(stakes) do
    if not isInteger(outcome, 1, #event.o) or not isInteger(gold, 1, event.m) then
      return false
    end
  end
  return true
end

---Tells whether a book entry counts for its event: received not after the close, and its stakes fit.
---@param entry any
---@param event OOOOGambleEvent
---@return boolean
local function isValidEntry(entry, event)
  return type(entry) == "table" and isInteger(entry.t, 1, event.c) and type(entry.b) == "string"
    and fitsEvent(entry.g, event)
end

---Copies a stake map.
---@param stakes table<integer, integer>
---@return table<integer, integer>
local function copyStakes(stakes)
  local result = {}
  for outcome, gold in pairs(stakes) do
    result[outcome] = gold
  end
  return result
end

---Checks the spec of a new event.
---@param spec any
---@param now integer
---@return string|nil reason nil when the spec is good
local function specProblem(spec, now)
  if type(spec) ~= "table" then
    return "bad spec"
  end
  if not isText(spec.title, data.MAX_TITLE) then
    return "bad title"
  end
  local outcomes = spec.outcomes
  if type(outcomes) ~= "table" or #outcomes < data.MIN_OUTCOMES or #outcomes > data.MAX_OUTCOMES then
    return "bad outcomes"
  end
  for index = 1, #outcomes do
    local outcome = outcomes[index]
    if type(outcome) ~= "table" or not isText(outcome.n, data.MAX_OUTCOME_NAME) or not isInteger(outcome.p, 1, 99) then
      return "bad outcome"
    end
    if outcome.x ~= nil and (outcome.p >= data.CAP_BELOW or not isInteger(outcome.x, 1, data.MAX_CAP)) then
      return "bad cap"
    end
  end
  if not isInteger(spec.close, now + 1, now + data.MAX_CLOSE_AHEAD) then
    return "bad close"
  end
  if not isInteger(spec.maxStake, 1, data.MAX_GOLD) then
    return "bad stake"
  end
  return nil
end

---@class OOOOGamble
---@field sync OOOOSync
---@field now fun(): integer
---@field playerName fun(): string|nil
---@field sanitize fun(text: string): string
---@field random fun(m: integer, n: integer): integer
---@field isOfficer (fun(name: string): boolean)|nil
local Model = {}
Model.__index = Model

---Makes a gambling model over the tables of the engine.
---@param parts OOOOGambleParts
---@return OOOOGamble
function gamble.new(parts)
  return setmetatable({
    sync = parts.sync,
    now = parts.now,
    playerName = parts.playerName,
    sanitize = parts.sanitize,
    random = parts.random,
    isOfficer = parts.isOfficer,
  }, Model)
end

---Builds the model of the game as `gamble.current`. Called after login, never at file scope.
---@return OOOOGamble
function gamble.Start()
  gamble.current = gamble.new({
    sync = ns.sync,
    now = GetServerTime,
    playerName = ns.syncCharacter.playerName,
    sanitize = ns.mentions.sanitize,
    random = math.random,
    isOfficer = function(name)
      return ns.guildState:IsOfficer(name)
    end,
  })
  return gamble.current
end

---Returns the stored payload of an event.
---@param eventId any
---@return OOOOGambleEvent|nil event nil for an unknown event; the stored table: do not change it
function Model:Event(eventId)
  if type(eventId) ~= "string" then
    return nil
  end
  local event = self.sync:Get(TABLE, data.eventKey(eventId))
  return type(event) == "table" and event or nil
end

---Makes a copy of an event that a write can change; the outcomes stay shared, because no write changes them.
---@param event OOOOGambleEvent
---@return OOOOGambleEvent
local function copyEvent(event)
  local result = {}
  for field, value in pairs(event) do
    result[field] = value
  end
  return result
end

---Finds the event of an officer's change, or the reason why there is none.
---@param model OOOOGamble
---@param eventId any
---@return OOOOGambleEvent|nil event
---@return string|nil reason
local function officerEvent(model, eventId)
  if not model.sync:IsOfficer() then
    return nil, "not an officer"
  end
  local event = model:Event(eventId)
  if not event then
    return nil, "unknown event"
  end
  return event
end

---Opens an event: the officer's addon writes it under a fresh event id.
---@param spec OOOOGambleSpec
---@return string|nil eventId nil when refused
---@return string|nil reason "not an officer", "bad spec", "bad title", "bad outcomes", "bad outcome", "bad cap",
---"bad close", "bad stake", "not ready", or a refusal of the engine
function Model:Open(spec)
  if not self.sync:IsOfficer() then
    return nil, "not an officer"
  end
  local problem = specProblem(spec, self.now())
  if problem then
    return nil, problem
  end
  local name = self.playerName()
  if not name then
    return nil, "not ready"
  end
  local outcomes = {}
  for index, outcome in ipairs(spec.outcomes) do
    outcomes[index] = { n = outcome.n, p = outcome.p, x = outcome.x }
  end
  local eventId = self.sync:NewId(TABLE)
  if not eventId then
    return nil, "not ready"
  end
  local written, reason = self.sync:Put(TABLE, data.eventKey(eventId), { n = spec.title, o = outcomes,
    c = spec.close, m = spec.maxStake, s = data.STATE_OPEN, by = name })
  if not written then
    return nil, reason
  end
  return eventId
end

---Locks an open event before its close: the close becomes now. The close never moves later.
---@param eventId string
---@return true|nil locked nil when refused
---@return string|nil reason "not an officer", "unknown event", "closed", "resolved", "cancelled", or a refusal of
---the engine
function Model:Lock(eventId)
  local event, reason = officerEvent(self, eventId)
  if not event then
    return nil, reason
  end
  local now = self.now()
  local state = stateOf(event, now)
  if state ~= "open" then
    return nil, REFUSAL[state]
  end
  local locked = copyEvent(event)
  locked.c = now
  local written, refusal = self.sync:Put(TABLE, data.eventKey(eventId), locked)
  if written == nil then
    return nil, refusal
  end
  return true
end

---Cancels an event in any state but cancelled: nothing is owed. The other fields stay, also a resolution.
---@param eventId string
---@return true|nil cancelled nil when refused
---@return string|nil reason "not an officer", "unknown event", "cancelled", or a refusal of the engine
function Model:Cancel(eventId)
  local event, reason = officerEvent(self, eventId)
  if not event then
    return nil, reason
  end
  if event.s == data.STATE_CANCELLED then
    return nil, "cancelled"
  end
  local cancelled = copyEvent(event)
  cancelled.s = data.STATE_CANCELLED
  local written, refusal = self.sync:Put(TABLE, data.eventKey(eventId), cancelled)
  if written == nil then
    return nil, refusal
  end
  return true
end

---Finds the open event of a change of the own bet and the own name, or the reason why the change is refused.
---@param model OOOOGamble
---@param eventId any
---@return OOOOGambleEvent|nil event
---@return string|nil nameOrReason The own name, or the reason of the refusal
local function betEvent(model, eventId)
  local name = model.playerName()
  if not name then
    return nil, "not ready"
  end
  local event = model:Event(eventId)
  if not event then
    return nil, "unknown event"
  end
  local state = stateOf(event, model.now())
  if state ~= "open" then
    return nil, REFUSAL[state]
  end
  return event, name
end

---Changes the own bet: the given stakes are applied to the current bet record, a stake of 0 removes that
---outcome, and a bet without any stake left is taken back. Only while the event is open and before its close.
---@param eventId string
---@param stakes table<integer, integer> Outcome index -> whole gold, 0 to the highest stake of the event
---@return true|nil placed nil when refused
---@return string|nil reason "not ready", "unknown event", "closed", "resolved", "cancelled", "bad stakes",
---"bad outcome", "bad stake", "stake too high", "no bet" (all stakes 0 and no bet held), or a refusal of the engine
function Model:PlaceBet(eventId, stakes)
  local event, name = betEvent(self, eventId)
  if not event then
    return nil, name
  end
  ---@cast name string
  if type(stakes) ~= "table" then
    return nil, "bad stakes"
  end
  for outcome, gold in pairs(stakes) do
    if not isInteger(outcome, 1, #event.o) then
      return nil, "bad outcome"
    end
    if not isInteger(gold, 0, data.MAX_GOLD) then
      return nil, "bad stake"
    end
    if gold > event.m then
      return nil, "stake too high"
    end
  end
  local key = data.betKey(name, eventId)
  local current = self.sync:Get(PLAYER_TABLE, key)
  local merged = {}
  if type(current) == "table" and type(current.g) == "table" then
    for outcome, gold in pairs(current.g) do
      -- A stake that does not fit the event is dropped
      if isInteger(outcome, 1, #event.o) and isInteger(gold, 1, event.m) then
        merged[outcome] = gold
      end
    end
  end
  for outcome, gold in pairs(stakes) do
    merged[outcome] = gold > 0 and gold or nil
  end
  if next(merged) == nil then
    return self:TakeBack(eventId)
  end
  local written, reason = self.sync:Put(PLAYER_TABLE, key, { g = merged })
  if written == nil then
    return nil, reason
  end
  return true
end

---Takes the own bet back: deletes the bet record, only while the event is open and before its close.
---@param eventId string
---@return true|nil taken nil when refused
---@return string|nil reason "not ready", "unknown event", "closed", "resolved", "cancelled", "no bet", or a
---refusal of the engine
function Model:TakeBack(eventId)
  local event, name = betEvent(self, eventId)
  if not event then
    return nil, name
  end
  ---@cast name string
  local deleted, reason = self.sync:Delete(PLAYER_TABLE, data.betKey(name, eventId))
  if deleted == nil then
    return nil, reason
  elseif not deleted then
    return nil, "no bet"
  end
  return true
end

---Sorts the entries of a group newest first: version ids compare by time with `>`.
---@param a OOOOGambleListEntry
---@param b OOOOGambleListEntry
---@return boolean
local function newestFirst(a, b)
  return a.id > b.id
end

---Returns the held events in the four groups of the window, each newest first.
---@return OOOOGambleGroups
function Model:Events()
  local groups = { open = {}, waiting = {}, toPay = {}, done = {} }
  local now = self.now()
  for key, payload in self.sync:Iterate(TABLE) do
    local parts = data.parseKey(TABLE, key)
    if parts and parts.kind == "event" and type(payload) == "table" then
      local group = groups[groupOf(self.sync, parts.eventId, payload, now)]
      group[#group + 1] = { id = parts.eventId, event = payload }
    end
  end
  for _, group in pairs(groups) do
    table.sort(group, newestFirst)
  end
  return groups
end

---Returns the valid book entries of an event: received not after the close, every outcome exists, every stake
---is 1 to `m`. An entry that does not fit is left out whole.
---@param eventId string
---@return table<string, table<integer, integer>> booked Character name -> copy of the booked stakes; empty for an
---unknown event
function Model:BookedBets(eventId)
  local booked = {}
  local event = self:Event(eventId)
  if not event then
    return booked
  end
  for key, payload in self.sync:Iterate(TABLE) do
    local parts = data.parseKey(TABLE, key)
    if parts and parts.kind == "book" and parts.eventId == eventId and isValidEntry(payload, event) then
      booked[parts.name] = copyStakes(payload.g)
    end
  end
  return booked
end

---Tells the state of the own bet in an event (15.4). "none": no bet record and no book entry; "accepted": a
---valid book entry with the id of the bet record; "waiting": before the close, a bet record without such an
---entry, or a book entry of a bet that was taken back; after the close "late": a bet record and no valid
---entry; "outdated": a valid entry that is not the current bet record, whose stakes stay in force.
---@param eventId string
---@return OOOOGambleBetState|nil state nil for an unknown event
---@return OOOOGambleBetInfo|nil info With the state "outdated"
function Model:BetState(eventId)
  local event = self:Event(eventId)
  if not event then
    return nil
  end
  local name = self.playerName()
  if not name then
    return "none"
  end
  local betId = self.sync:GetId(PLAYER_TABLE, data.betKey(name, eventId))
  local entry = self.sync:Get(TABLE, data.bookKey(eventId, name))
  if not isValidEntry(entry, event) then
    entry = nil
  end
  if entry and betId and entry.b == betId then
    return "accepted"
  end
  if not entry and not betId then
    return "none"
  end
  if stateOf(event, self.now()) == "open" then
    return "waiting"
  end
  if entry then
    return "outdated", { stakes = copyStakes(entry.g) }
  end
  return "late"
end

---Returns what the window shows for one event, every text sanitized. The booked sums are given only when the
---event no longer takes bets (decided by the user on 2026-11-21).
---@param eventId string
---@return OOOOGambleDetail|nil detail nil for an unknown event
function Model:Detail(eventId)
  local event = self:Event(eventId)
  if not event then
    return nil
  end
  local sanitize = self.sanitize
  local state = stateOf(event, self.now())
  local sums ---@type table<integer, integer>|nil
  if state ~= "open" then
    sums = {}
    for _, stakes in pairs(self:BookedBets(eventId)) do
      for outcome, gold in pairs(stakes) do
        sums[outcome] = (sums[outcome] or 0) + gold
      end
    end
  end
  local name = self.playerName()
  local bet = name and self.sync:Get(PLAYER_TABLE, data.betKey(name, eventId))
  local own = type(bet) == "table" and type(bet.g) == "table" and bet.g or {}
  local outcomes = {}
  for index, outcome in ipairs(event.o) do
    local stake = own[index]
    outcomes[index] = { n = sanitize(outcome.n), p = outcome.p, x = outcome.x,
      booked = sums and (sums[index] or 0) or nil, own = isInteger(stake, 1, data.MAX_GOLD) and stake or nil }
  end
  local betState, betInfo = self:BetState(eventId)
  return { id = eventId, title = sanitize(event.n), by = sanitize(event.by), outcomes = outcomes, close = event.c,
    maxStake = event.m, state = state, betState = betState, betInfo = betInfo }
end

---Returns what the window shows before an officer resolves an event (15.5).
---@param eventId string
---@return OOOOGamblePreview|nil preview nil for an unknown event
function Model:ResolvePreview(eventId)
  if not self:Event(eventId) then
    return nil
  end
  local bets, sum = 0, 0
  for _, stakes in pairs(self:BookedBets(eventId)) do
    bets = bets + 1
    for _, gold in pairs(stakes) do
      sum = sum + gold
    end
  end
  return { bets = bets, sum = sum, behind = self.sync:IsBehind(TABLE) }
end

---Copies a result list when it has exactly one boolean per outcome.
---@param results any
---@param count integer Number of outcomes
---@return boolean[]|nil copy nil when the list does not fit
local function copyResults(results, count)
  if type(results) ~= "table" then
    return nil
  end
  local size = 0
  for _ in pairs(results) do
    size = size + 1
  end
  if size ~= count then
    return nil
  end
  local copy = {}
  for index = 1, count do
    if type(results[index]) ~= "boolean" then
      return nil
    end
    copy[index] = results[index]
  end
  return copy
end

---Makes a settlement token: `TOKEN_LENGTH` random base-94 characters.
---@param random fun(m: integer, n: integer): integer
---@return string
local function newToken(random)
  local chars = {}
  for position = 1, data.TOKEN_LENGTH do
    chars[position] = string.char(random(FIRST_BYTE, LAST_BYTE))
  end
  return table.concat(chars)
end

---Resolves a locked event (15.5): settles the valid book entries that this replica holds, writes the dues
---`d:<event>:1..count` under a fresh token, and then the event with `s = 2`, the results, the token, the count,
---and the banker. The event comes last, so a replica that holds it and not all of its dues shows "loading".
---When a due cannot be written, the event is not written; dues that were written stay, and no reader counts
---them, because the token of the event is not theirs. Dues of an earlier resolution with a higher number stay
---too, told apart by their token.
---
---The banker: nil means the own character. Another character is accepted only when the part `isOfficer` says
---that the roster shows it with an officer rank; without that part only the own character can be the banker.
---The own character always can: the resolver passed the officer check of the engine.
---@param eventId string
---@param results boolean[] One boolean per outcome: true for an outcome that came true
---@param banker string|nil Character that receives the share of the guild bank
---@return true|nil resolved nil when refused
---@return string|nil reason "not an officer", "unknown event", "open", "resolved", "cancelled", "bad results",
---"not ready", "bad banker", "too many dues", or a refusal of the engine
function Model:Resolve(eventId, results, banker)
  local event, reason = officerEvent(self, eventId)
  if not event then
    return nil, reason
  end
  local state = stateOf(event, self.now())
  if state ~= "locked" then
    return nil, state == "open" and "open" or REFUSAL[state]
  end
  local copy = copyResults(results, #event.o)
  if not copy then
    return nil, "bad results"
  end
  local name = self.playerName()
  if not name then
    return nil, "not ready"
  end
  if banker == nil then
    banker = name
  end
  if not isName(banker) or (banker ~= name and not (self.isOfficer and self.isOfficer(banker) == true)) then
    return nil, "bad banker"
  end
  local dues = gambleSettle.dues(gambleSettle.settle(event.o, copy, self:BookedBets(eventId)), banker)
  if #dues > MAX_DUES then
    return nil, "too many dues"
  end
  local token = newToken(self.random)
  for n, due in ipairs(dues) do
    local written, refusal = self.sync:Put(TABLE, data.dueKey(eventId, n),
      { q = token, f = due.f, t = due.t, g = due.g, k = due.k })
    if written == nil then
      return nil, refusal
    end
  end
  local resolved = copyEvent(event)
  resolved.s, resolved.r, resolved.q, resolved.d, resolved.k = data.STATE_RESOLVED, copy, token, #dues, banker
  local written, refusal = self.sync:Put(TABLE, data.eventKey(eventId), resolved)
  if written == nil then
    return nil, refusal
  end
  return true
end

---Adds a due number to the own receipt record of an event, or removes it (15.6). A record with an older token
---is replaced, not merged; a record left without numbers is deleted.
---@param model OOOOGamble
---@param eventId any
---@param n any Due number
---@param confirmed boolean
---@return true|nil changed nil when refused
---@return string|nil reason
local function changeReceipt(model, eventId, n, confirmed)
  local name = model.playerName()
  if not name then
    return nil, "not ready"
  end
  local event = model:Event(eventId)
  if not event then
    return nil, "unknown event"
  end
  if event.s == data.STATE_CANCELLED then
    return nil, "cancelled"
  elseif event.s ~= data.STATE_RESOLVED then
    return nil, "not resolved"
  end
  local due = isInteger(n, 1, event.d) and model.sync:Get(TABLE, data.dueKey(eventId, n)) or nil
  if type(due) ~= "table" or due.q ~= event.q then
    return nil, "unknown due"
  end
  if due.t ~= name then
    return nil, "not the receiver"
  end
  local key = data.receiptKey(name, eventId)
  local current = model.sync:Get(PLAYER_TABLE, key)
  local numbers = {}
  if type(current) == "table" and current.q == event.q and type(current.n) == "table" then
    for number, flag in pairs(current.n) do
      numbers[number] = flag
    end
  end
  numbers[n] = confirmed or nil
  local done, reason
  if next(numbers) == nil then
    done, reason = model.sync:Delete(PLAYER_TABLE, key)
  else
    done, reason = model.sync:Put(PLAYER_TABLE, key, { q = event.q, n = numbers })
  end
  if done == nil then
    return nil, reason
  end
  return true
end

---Confirms that the own character has received a due: only its receiver can, only for a due of the token in
---force of a resolved event. Confirming a confirmed due again is no error.
---@param eventId string
---@param n integer Due number
---@return true|nil confirmed nil when refused
---@return string|nil reason "not ready", "unknown event", "cancelled", "not resolved", "unknown due" (also a due
---that this replica does not hold yet), "not the receiver", or a refusal of the engine
function Model:Confirm(eventId, n)
  return changeReceipt(self, eventId, n, true)
end

---Takes back the confirmation of a due by its receiver. Taking back a due that is not confirmed is no error.
---@param eventId string
---@param n integer Due number
---@return true|nil unconfirmed nil when refused
---@return string|nil reason As in `Confirm`
function Model:Unconfirm(eventId, n)
  return changeReceipt(self, eventId, n, false)
end

---Tells whether two lists of dues are equal: the computed ones of `gambleSettle.dues` and the held ones.
---@param computed GambleDue[]
---@param held OOOOGambleHeldDue[]
---@return boolean
local function sameDues(computed, held)
  if #computed ~= #held then
    return false
  end
  for index, due in ipairs(computed) do
    local stored = held[index].due
    if due.f ~= stored.f or due.t ~= stored.t or due.g ~= stored.g or (due.k == true) ~= (stored.k == true) then
      return false
    end
  end
  return true
end

---Returns the result of a resolved or cancelled event with its dues and their confirmations (15.5, 15.6).
---
---"loading": the replica holds fewer than `count` dues of the event's token; the lists are then empty and the
---sums nil, because a part of the dues gives a wrong net.
---
---`inSettlement`: the dues do not say whom the resolving officer counted, so this is the best that the stored
---data allows. True when a due names the own character as payer, or as receiver of a share that is not the
---bank's. Otherwise false without a valid own book entry; false when the own book entry carries a later version
---id than the resolution, because the resolving officer cannot have held it; and else false only when a
---settlement over the book that this replica holds gives the own character a net that is not 0. An own bet that
---broke even therefore counts as in the settlement, and so does a late entry of an officer who was offline when
---the resolver wrote, when this replica's book also gives it a net of 0.
---@param eventId string
---@return OOOOGambleResult|nil result nil for an unknown event, and for an event that is open or locked
function Model:Result(eventId)
  local event = self:Event(eventId)
  if not event then
    return nil
  end
  local state = stateOf(event, self.now())
  if state == "cancelled" then
    return { state = "cancelled", held = 0, count = 0, dues = {}, ownDues = {}, net = 0, bankHeld = 0,
      settled = true, booked = false, inSettlement = false, mismatch = false }
  elseif state ~= "resolved" then
    return nil
  end
  local sanitize = self.sanitize
  local own = self.playerName()
  local booked = self:BookedBets(eventId)
  local held = readSettlement(self.sync, eventId, event)
  local result = { state = held.ready and "ready" or "loading", results = copyResults(event.r, #event.o),
    banker = sanitize(event.k), held = held.held, count = event.d, dues = {}, ownDues = {},
    settled = held.settled, booked = own ~= nil and booked[own] ~= nil }
  if not held.ready then
    return result
  end
  local net, bankHeld, named = 0, 0, false
  for _, entry in ipairs(held.dues) do
    local due = entry.due
    local mine ---@type "pay"|"receive"|nil
    if own ~= nil and due.f == own then
      mine, net, named = "pay", net - due.g, true
    elseif own ~= nil and due.t == own then
      mine = "receive"
    end
    if own ~= nil and due.t == own then
      if due.k then
        bankHeld = bankHeld + due.g
      else
        net, named = net + due.g, true
      end
    end
    local shown = { n = entry.n, from = sanitize(due.f), to = sanitize(due.t), gold = due.g, bank = due.k == true,
      confirmed = entry.confirmed, mine = mine, confirmable = own ~= nil and due.t == own }
    result.dues[#result.dues + 1] = shown
    if mine then
      result.ownDues[#result.ownDues + 1] = shown
    end
  end
  result.net, result.bankHeld = net, bankHeld
  local settlement = gambleSettle.settle(event.o, event.r, booked)
  result.mismatch = not sameDues(gambleSettle.dues(settlement, event.k), held.dues)
  if named then
    result.inSettlement = true
  elseif not result.booked then
    result.inSettlement = false
  else
    ---@cast own string
    local entryId = self.sync:GetId(TABLE, data.bookKey(eventId, own))
    local resolutionId = self.sync:GetId(TABLE, data.eventKey(eventId))
    if entryId and resolutionId and entryId > resolutionId then
      result.inSettlement = false
    else
      result.inSettlement = (settlement.nets[own] or 0) == 0
    end
  end
  return result
end
