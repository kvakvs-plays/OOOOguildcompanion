local addonName, ns = ...

-- The model of the gambling feature, without frames (.agents/00-plan.md, sections 15.3 and 15.4, step 14.3):
-- the officers open, lock, and cancel events; every member places and takes back the own bet; and the reading
-- of the events, of one event, and of the state of the own bet.
--
-- Every write checks the state of the event (15.3) before it is made. A stored record has passed the check of
-- its kind (GambleData.lua), but a check sees one record only: this reader compares a book entry or a bet with
-- its event and ignores what does not fit.
--
-- This file uses no WoW API at file scope, so the host tests load it (Tests/sync_gamble.lua).

---@class OOOOGambleParts What a gambling model is built from
---@field sync OOOOSync
---@field now fun(): integer Server time in seconds
---@field playerName fun(): string|nil Name of the logged-in character as the roster shows it
---@field sanitize fun(text: string): string Makes an untrusted text safe to show (`ns.mentions.sanitize`)

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
---@field toPay OOOOGambleListEntry[] Resolved
---@field done OOOOGambleListEntry[] Cancelled

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

---@class OOOOGambleModule
---@field current OOOOGamble|nil The model of the game, made by `Start`
local gamble = {}
ns.gamble = gamble

local data = ns.gambleData
local TABLE, PLAYER_TABLE = data.TABLE, data.PLAYER_TABLE

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

---Tells the group of the window that an event belongs to. Step 14.5 moves a settled event from "toPay" to
---"done"; this is the one place for that decision.
---@param event OOOOGambleEvent
---@param now integer
---@return "open"|"waiting"|"toPay"|"done"
local function groupOf(event, now)
  local state = stateOf(event, now)
  if state == "open" then
    return "open"
  elseif state == "locked" then
    return "waiting"
  elseif state == "resolved" then
    return "toPay"
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
      local group = groups[groupOf(payload, now)]
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
