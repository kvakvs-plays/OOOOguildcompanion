local addonName, ns = ...

-- The book of the gambling feature (.agents/00-plan.md, section 15.4 "Booking", step 14.4). A receiver knows
-- only when it received a record, never when it was written (14.1). So an officer's addon copies every bet that
-- it receives first hand into the table `gamble`, with the server time of receipt `t`, and a bet counts only
-- with an entry whose `t` is not after the close of its event.
--
-- - The time of receipt is noted at once; the entry is written after a random delay, so that of several online
--   officers usually one writes and the others find its entry (same or newer bet id) and write nothing.
-- - A bet that the officer got from another officer or from a pull (not first hand) is never booked: the time
--   at which it was first received is unknown here, and the entry of the first officer comes the same way.
-- - A change received after the close leaves the entry and a pending booking alone.
-- - A bet whose event is not held yet waits in memory, with its time of receipt, until the event arrives.
--
-- This file uses no WoW API at file scope, so the host tests load it (Tests/sync_gamblebook.lua).

---@class OOOOGambleBookTimer A timer that can be stopped before it fires
---@field Cancel fun(self: OOOOGambleBookTimer)

---@class OOOOGambleBookParts What a booker is built from
---@field sync OOOOSync
---@field now fun(): integer Server time in seconds
---@field after fun(seconds: number, fn: fun()): OOOOGambleBookTimer Calls `fn` once, `seconds` from now
---@field random fun(): number A number in [0, 1)

---@class OOOOGambleBookChange A first-hand change of a bet, as the booker received it
---@field key string Key of the bet record
---@field eventId string Event id
---@field name string Name of the bettor
---@field stakes table<integer, integer>|nil Copy of the stakes; nil for a bet that was taken back
---@field id string|nil Version id of the bet record at the time of receipt; nil for a bet that was taken back
---@field t integer Server time of receipt

---@class OOOOGambleBookPending A booking that waits for its delay
---@field change OOOOGambleBookChange
---@field timer OOOOGambleBookTimer

---@class OOOOGambleBookModule
---@field current OOOOGambleBooker|nil The booker of the game, made by `Start`
local book = {}
ns.gambleBook = book

local data = ns.gambleData
local TABLE, PLAYER_TABLE = data.TABLE, data.PLAYER_TABLE

---Longest delay in seconds between the receipt of a bet and the write of its entry; the delay is random
book.BOOK_DELAY_MAX = 20
---Most changes that wait for their event; more are dropped, because a member could send bets on made-up events
book.MAX_WAITING = 500

---Tells whether a value is an integer within a range; false for NaN, fractions, and other types.
---@param value any
---@param low number
---@param high number
---@return boolean
local function isInteger(value, low, high)
  return type(value) == "number" and value >= low and value <= high and value == math.floor(value)
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

---Tells whether a stake map fits its event: at least one stake, every outcome exists, every stake is 1 to `m`.
---@param stakes table<integer, integer>
---@param event OOOOGambleEvent
---@return boolean
local function fitsEvent(stakes, event)
  if next(stakes) == nil then
    return false
  end
  for outcome, gold in pairs(stakes) do
    if not isInteger(outcome, 1, #event.o) or not isInteger(gold, 1, event.m) then
      return false
    end
  end
  return true
end

---Tells whether an event takes a bet received at a time: it is open and the time is not after its close.
---@param event OOOOGambleEvent
---@param t integer Server time of receipt
---@return boolean
local function takesBetAt(event, t)
  return event.s == data.STATE_OPEN and t <= event.c
end

---@class OOOOGambleBooker
---@field sync OOOOSync
---@field now fun(): integer
---@field after fun(seconds: number, fn: fun()): OOOOGambleBookTimer
---@field random fun(): number
---@field pending table<string, OOOOGambleBookPending> Key of the bet record -> the booking that waits
---@field waiting table<string, table<string, OOOOGambleBookChange>> Event id -> key of the bet record -> the
---latest change of that bet, for an event that is not held yet
---@field waitingCount integer Number of changes in `waiting`
local Booker = {}
Booker.__index = Booker

---Makes a booker and registers it for "OnRecordChanged" of the engine. It acts only while the logged-in
---character is an officer, which it asks at every change.
---@param parts OOOOGambleBookParts
---@return OOOOGambleBooker
function book.new(parts)
  local self = setmetatable({
    sync = parts.sync,
    now = parts.now,
    after = parts.after,
    random = parts.random,
    pending = {},
    waiting = {},
    waitingCount = 0,
  }, Booker)
  self.sync.RegisterCallback(self, "OnRecordChanged", function(_event, tableName, key, payload, _isRemote,
      firstHand)
    self:OnRecordChanged(tableName, key, payload, firstHand)
  end)
  return self
end

---Builds the booker of the game as `book.current`, replacing an earlier one. Called after login, never at file
---scope.
---@return OOOOGambleBooker
function book.Start()
  if book.current then
    book.current:Stop()
  end
  book.current = book.new({
    sync = ns.sync,
    now = GetServerTime,
    after = C_Timer.NewTimer,
    random = math.random,
  })
  return book.current
end

---Unregisters the booker and forgets its pending bookings and waiting bets.
function Booker:Stop()
  self.sync.UnregisterCallback(self, "OnRecordChanged")
  for _, pending in pairs(self.pending) do
    pending.timer:Cancel()
  end
  self.pending = {}
  self.waiting = {}
  self.waitingCount = 0
end

---Returns the held payload of an event.
---@param eventId string
---@return OOOOGambleEvent|nil
function Booker:Event(eventId)
  local event = self.sync:Get(TABLE, data.eventKey(eventId))
  return type(event) == "table" and event or nil
end

---Handles a change of a record: a first-hand bet is received, and an event that arrives releases the bets that
---wait for it. Nothing happens while the logged-in character is no officer.
---@param tableName string
---@param key string
---@param payload any nil for a deleted record
---@param firstHand boolean|nil
function Booker:OnRecordChanged(tableName, key, payload, firstHand)
  if tableName ~= PLAYER_TABLE and tableName ~= TABLE then
    return
  end
  -- The time of receipt is the proof of a bet, so it is taken before anything else
  local now = self.now()
  if not self.sync:IsOfficer() then
    return
  end
  if tableName == TABLE then
    local parts = payload ~= nil and data.parseKey(TABLE, key)
    if parts and parts.kind == "event" then
      self:Release(parts.eventId)
    end
    return
  end
  -- A vouched bet (from another officer, or from a pull) is never booked
  if not firstHand then
    return
  end
  local parts = data.parseKey(PLAYER_TABLE, key)
  if not parts or parts.kind ~= "bet" then
    return
  end
  local change = { key = key, eventId = parts.eventId, name = parts.name, t = now } ---@type OOOOGambleBookChange
  if payload ~= nil then
    -- The engine has checked the payload with `validatePlayer`; this guards against a change of that check
    if type(payload) ~= "table" or type(payload.g) ~= "table" then
      return
    end
    change.stakes = copyStakes(payload.g)
    change.id = self.sync:GetId(PLAYER_TABLE, key)
    if not change.id then
      return
    end
  end
  self:Receive(change)
end

---Judges a received change against its event: it waits when the event is not held; it is dropped when it came
---after the close; a take back deletes the entry at once; a valid bet is booked after the delay.
---@param change OOOOGambleBookChange
function Booker:Receive(change)
  local event = self:Event(change.eventId)
  if not event then
    self:Wait(change)
    return
  end
  -- After the close the entry stays as it is, and so does a booking of an earlier change that is still pending
  if not takesBetAt(event, change.t) then
    return
  end
  self:DropPending(change.key)
  if not change.stakes or not fitsEvent(change.stakes, event) then
    -- No valid bet stands: a take back, or a bet that does not fit its event. The delete is made at once: a
    -- delayed one could remove the entry of a newer bet that another officer booked in between, and two officers
    -- that both delete write nothing worse than two tombstones.
    self.sync:Delete(TABLE, data.bookKey(change.eventId, change.name))
    return
  end
  local pending ---@type OOOOGambleBookPending
  pending = { change = change, timer = self.after(self.random() * book.BOOK_DELAY_MAX, function()
    self:Fire(pending)
  end) }
  self.pending[change.key] = pending
end

---Stops the pending booking of a bet, if there is one.
---@param key string Key of the bet record
function Booker:DropPending(key)
  local pending = self.pending[key]
  if pending then
    pending.timer:Cancel()
    self.pending[key] = nil
  end
end

---Writes the entry of a pending booking after its delay, when the character is still an officer, the event
---still takes a bet received at that time (a lock moves the close earlier), and no entry of the same or a newer
---bet record is held (another officer was faster).
---@param pending OOOOGambleBookPending
function Booker:Fire(pending)
  local change = pending.change
  if self.pending[change.key] ~= pending then
    return
  end
  self.pending[change.key] = nil
  if not self.sync:IsOfficer() then
    return
  end
  local event = self:Event(change.eventId)
  if not event or not takesBetAt(event, change.t) then
    return
  end
  local bookKey = data.bookKey(change.eventId, change.name)
  local held = self.sync:Get(TABLE, bookKey)
  -- A pending booking always has the id of its bet record
  local id = change.id --[[@as string]]
  -- Ids compare by time with `<`, so a newer bet record has a greater id
  if type(held) == "table" and type(held.b) == "string" and held.b >= id then
    return
  end
  self.sync:Put(TABLE, bookKey, { g = change.stakes, b = id, t = change.t })
end

---Keeps a change whose event is not held yet; a later change of the same bet replaces it.
---@param change OOOOGambleBookChange
function Booker:Wait(change)
  local list = self.waiting[change.eventId]
  if list and list[change.key] then
    list[change.key] = change
    return
  end
  if self.waitingCount >= book.MAX_WAITING then
    return
  end
  if not list then
    list = {}
    self.waiting[change.eventId] = list
  end
  list[change.key] = change
  self.waitingCount = self.waitingCount + 1
end

---Judges the changes that waited for an event that has arrived, with their original times of receipt.
---@param eventId string
function Booker:Release(eventId)
  local list = self.waiting[eventId]
  if not list then
    return
  end
  self.waiting[eventId] = nil
  for _, change in pairs(list) do
    self.waitingCount = self.waitingCount - 1
    self:Receive(change)
  end
end
