local addonName, ns = ...

-- Version ids of the shared database: 11 base-94 characters, `TTTTT OOOO RR` (.agents/00-plan.md, section 3).
-- A plain `<` on two ids gives their order in time; the release client compares strings by bytes (step 1.2).
--
-- This file uses no WoW API. The time, the random source, and the origin are parameters, so the host tests
-- run the same code (Tests/sync_versionid.lua).

---@class OOOOVersionId
local versionId = {}
ns.versionId = versionId

local base94 = ns.base94

local TIME_WIDTH = 5
local ORIGIN_WIDTH = 4
local COUNTER_WIDTH = 2
---Number of counter values: 94^2
local COUNTER_LIMIT = 94 * 94
---A received id may be this many seconds ahead of the server time
local MAX_SECONDS_AHEAD = 300

---Length of every version id
versionId.LENGTH = TIME_WIDTH + ORIGIN_WIDTH + COUNTER_WIDTH
---The smallest id. It stands for "nothing seen": every real id is greater.
versionId.ZERO = string.rep("!", versionId.LENGTH)

---Builds an id from its three parts.
---@param timestamp integer Seconds, as GetServerTime() gives them
---@param origin string 4 base-94 characters
---@param counter integer 0 to 8835
---@return string id
function versionId.make(timestamp, origin, counter)
  return base94.encode(timestamp, TIME_WIDTH) .. origin .. base94.encode(counter, COUNTER_WIDTH)
end

---Tells whether a value has the form of an id: a string of 11 base-94 characters.
---@param id any
---@return boolean
function versionId.isWellFormed(id)
  return type(id) == "string" and #id == versionId.LENGTH and base94.isValid(id)
end

---Checks a received id: its form, and that it is not more than 5 minutes ahead of the server time.
---The time limit bounds the damage of a wrong or forged clock: an id far in the future would win every merge.
---@param id any
---@param now integer Server time in seconds
---@return boolean
function versionId.isValid(id, now)
  return versionId.isWellFormed(id) and base94.decode(id:sub(1, TIME_WIDTH)) <= now + MAX_SECONDS_AHEAD
end

---Splits an id into its parts.
---@param id any
---@return integer|nil timestamp nil when `id` is not well formed
---@return string|nil origin
---@return integer|nil counter
function versionId.parse(id)
  if not versionId.isWellFormed(id) then
    return nil
  end
  return base94.decode(id:sub(1, TIME_WIDTH)), id:sub(TIME_WIDTH + 1, TIME_WIDTH + ORIGIN_WIDTH),
    base94.decode(id:sub(TIME_WIDTH + ORIGIN_WIDTH + 1))
end

---Returns the origin of a well-formed id: the player who wrote the record.
---@param id string
---@return string origin
function versionId.originOf(id)
  return id:sub(TIME_WIDTH + 1, TIME_WIDTH + ORIGIN_WIDTH)
end

---Makes the origin of a new install: 4 random base-94 characters.
---@param randomFn fun(m: integer, n: integer): integer Like math.random(m, n)
---@return string origin
function versionId.newOrigin(randomFn)
  local chars = {}
  for position = 1, ORIGIN_WIDTH do
    chars[position] = string.char(randomFn(33, 126))
  end
  return table.concat(chars)
end

---Makes the id source of one replica. The returned function gives ids that always increase:
--- - in the same second as the previous id, or when the clock went back, the counter is the previous one plus 1;
--- - in a later second, the counter is a random value in the lower half of its range;
--- - when the counter is used up, the timestamp moves one second ahead;
--- - an id is greater than `maxId`: if the current second does not give that, the timestamp is the second
---   after `maxId`. A new write is therefore newer than everything that the table has seen.
---@param origin string 4 base-94 characters
---@param timeFn fun(): integer Server time in seconds
---@param randomFn fun(m: integer, n: integer): integer Like math.random(m, n)
---@return fun(maxId: string?): string next Returns a new id; `maxId` is the greatest id that the table has seen
function versionId.newGenerator(origin, timeFn, randomFn)
  if type(origin) ~= "string" or #origin ~= ORIGIN_WIDTH or not base94.isValid(origin) then
    error("versionId.newGenerator: the origin must be 4 base-94 characters", 2)
  end
  ---Timestamp and counter of the previous id; nil before the first one
  ---@type integer|nil, integer|nil
  local previousTime, previousCounter

  ---A fresh counter: the lower half, so that the ids of this second have room to count up
  local function randomCounter()
    return randomFn(0, math.floor(COUNTER_LIMIT / 2) - 1)
  end

  return function(maxId)
    local timestamp = timeFn()
    local counter
    if previousTime and timestamp <= previousTime then
      timestamp, counter = previousTime, previousCounter + 1
      if counter >= COUNTER_LIMIT then
        timestamp, counter = timestamp + 1, randomCounter()
      end
    else
      counter = randomCounter()
    end
    local id = versionId.make(timestamp, origin, counter)
    if versionId.isWellFormed(maxId) and id <= maxId then
      timestamp, counter = base94.decode(maxId:sub(1, TIME_WIDTH)) + 1, randomCounter()
      id = versionId.make(timestamp, origin, counter)
    end
    previousTime, previousCounter = timestamp, counter
    return id
  end
end
