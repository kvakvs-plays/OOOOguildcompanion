local addonName, ns = ...

-- One table of the shared database: records, the clock, and the fingerprint (.agents/00-plan.md, section 4).
--
-- This file uses no WoW API, so the host tests run the same code (Tests/sync_store.lua, Tests/sync_delta.lua).

---@class OOOOSyncRecord One stored record
---@field v string Version id of the write
---@field d any Payload; nil in a tombstone
---@field x boolean|nil true in a tombstone: the record was deleted by the write `v`

---@class OOOOSyncTable One table, as it is kept in `db.global.sync.tables[name]`
---@field schema integer Payload layout version of the table
---@field clock table<string, string> Origin -> greatest version id received from that origin
---@field maxId string Greatest value in `clock`; `versionId.ZERO` while the clock is empty
---@field fp integer Fingerprint of `clock`: sum of the hashes of its ids, modulo 2^32
---@field records table<string, OOOOSyncRecord> Key -> record
---@field syncedAt integer|nil Server time of the last completed pull; nil when there was none
---@field trusted boolean|nil Officer tables only (plan section 7.5)

---@class OOOOSyncStore
local store = {}
ns.syncStore = store

local base94 = ns.base94
local versionId = ns.versionId

---2^32, written out because `2^32` is a float on Lua 5.4
local TWO_32 = 4294967296
---Characters of the fingerprint in a table version
local FP_WIDTH = 5

---Length of a table version: an id and the fingerprint
store.TABLE_VERSION_LENGTH = versionId.LENGTH + FP_WIDTH

---Makes an empty table.
---@param schema integer Payload layout version
---@return OOOOSyncTable
function store.newTable(schema)
  return { schema = schema, clock = {}, maxId = versionId.ZERO, fp = 0, records = {} }
end

---Raises the clock of an id's origin to the id, when the id is greater, and keeps `fp` and `maxId` in step.
---@param tbl OOOOSyncTable
---@param id string A well-formed version id
---@return boolean changed true when the clock entry rose
local function see(tbl, id)
  local origin = versionId.originOf(id)
  local seen = tbl.clock[origin]
  if seen and id <= seen then
    return false
  end
  tbl.fp = (tbl.fp - (seen and base94.hash(seen) or 0) + base94.hash(id)) % TWO_32
  tbl.clock[origin] = id
  if id > tbl.maxId then
    tbl.maxId = id
  end
  return true
end

---Merges one record into a table. Last writer wins per key: the record is stored when its id is greater
---than the stored one. The clock of the record's origin rises also when the record loses, because the
---table has then seen that write. `fp` and `maxId` follow the clock in place.
---@param tbl OOOOSyncTable
---@param key string
---@param id string A well-formed version id
---@param payload any Ignored for a tombstone
---@param isTombstone boolean? true when the write deleted the record
---@return boolean changed true when the stored record changed
function store.apply(tbl, key, id, payload, isTombstone)
  see(tbl, id)
  local record = tbl.records[key]
  if record and record.v >= id then
    return false
  end
  if isTombstone then
    tbl.records[key] = { v = id, x = true }
  else
    tbl.records[key] = { v = id, d = payload }
  end
  return true
end

---Returns the table version: `maxId` and the fingerprint, 16 characters. Two tables with equal versions
---have equal clocks; `maxId` tells which of two different tables has the most recent write.
---@param tbl OOOOSyncTable
---@return string
function store.tableVersion(tbl)
  return tbl.maxId .. base94.encode(tbl.fp, FP_WIDTH)
end

---Splits a received table version.
---@param text any
---@return string|nil maxId nil when `text` is not a table version
---@return integer|nil fp
function store.parseTableVersion(text)
  if type(text) ~= "string" or #text ~= store.TABLE_VERSION_LENGTH or not base94.isValid(text) then
    return nil
  end
  local fp = base94.decode(text:sub(versionId.LENGTH + 1))
  if fp >= TWO_32 then
    return nil
  end
  return text:sub(1, versionId.LENGTH), fp
end

---Computes the greatest id and the fingerprint of a clock.
---@param clock table<string, string> Origin -> id
---@return string maxId `versionId.ZERO` for an empty clock
---@return integer fp
local function summarize(clock)
  local maxId, fp = versionId.ZERO, 0
  for _, id in pairs(clock) do
    fp = (fp + base94.hash(id)) % TWO_32
    if id > maxId then
      maxId = id
    end
  end
  return maxId, fp
end

---Computes `maxId` and `fp` again from the clock: after the saved variables load, and in tests.
---The normal path never needs it, because `apply` keeps both current.
---@param tbl OOOOSyncTable
function store.rebuild(tbl)
  tbl.maxId, tbl.fp = summarize(tbl.clock)
end

---Returns the table version that a table with the given clock has. A requester uses it to work out the
---version of the replica that it has pulled from.
---@param clock table<string, string> Origin -> id
---@return string
function store.versionOfClock(clock)
  local maxId, fp = summarize(clock)
  return maxId .. base94.encode(fp, FP_WIDTH)
end

--------------------------------------------------------------------------------
-- Digest, delta, batches
--------------------------------------------------------------------------------

---@class OOOOSyncWireRecord A record on its way between two replicas
---@field key string
---@field id string Version id
---@field payload any nil in a tombstone
---@field tombstone boolean|nil true when the write deleted the record

---Returns the clock as one string of ids, sorted. It tells a peer what this table has seen.
---@param tbl OOOOSyncTable
---@return string digest Length is a multiple of 11
function store.digest(tbl)
  local ids = {}
  for _, id in pairs(tbl.clock) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return table.concat(ids)
end

---Reads a received digest.
---@param text any
---@return table<string, string>|nil clock Origin -> id; nil when `text` is not a digest
---@return string|nil reason Why the digest was rejected
function store.parseDigest(text)
  if type(text) ~= "string" or #text % versionId.LENGTH ~= 0 then
    return nil, "length"
  end
  local clock = {}
  for position = 1, #text, versionId.LENGTH do
    local id = text:sub(position, position + versionId.LENGTH - 1)
    if not versionId.isWellFormed(id) then
      return nil, "id"
    end
    local origin = versionId.originOf(id)
    if clock[origin] then
      return nil, "repeated origin"
    end
    clock[origin] = id
  end
  return clock
end

---Selects the records that another replica lacks: those with an id above the other clock's value for the
---record's origin. The list is sorted by id, ascending; a transfer must keep that order (see `applyBatch`).
---@param tbl OOOOSyncTable
---@param remoteClock table<string, string> Origin -> id, from `parseDigest`
---@return OOOOSyncWireRecord[]
function store.selectDelta(tbl, remoteClock)
  local records = {}
  for key, record in pairs(tbl.records) do
    local seen = remoteClock[versionId.originOf(record.v)]
    if not seen or record.v > seen then
      records[#records + 1] = { key = key, id = record.v, payload = record.d, tombstone = record.x }
    end
  end
  table.sort(records, function(a, b) return a.id < b.id end)
  return records
end

---Estimates the size of a value on the wire without a serializer: close enough to cut batches and to
---limit record sizes. Tables are counted to a depth of 8.
---@param value any
---@param depth integer?
---@return integer bytes
function store.estimateSize(value, depth)
  local kind = type(value)
  if kind == "string" then
    return #value + 2
  elseif kind == "number" then
    return #tostring(value) + 2
  elseif kind == "boolean" then
    return 2
  elseif kind ~= "table" or (depth or 0) >= 8 then
    return 0
  end
  local bytes = 4
  for key, item in pairs(value) do
    bytes = bytes + store.estimateSize(key, (depth or 0) + 1) + store.estimateSize(item, (depth or 0) + 1)
  end
  return bytes
end

---Estimates the size of one record on the wire.
---@param record OOOOSyncWireRecord
---@return integer bytes
function store.recordSize(record)
  return #record.key + 2 + versionId.LENGTH + 2 + store.estimateSize(record.payload) + 2
end

---Cuts a list of records into batches of at most `maxBytes`, by `recordSize`, without changing the order.
---A record that alone is larger than `maxBytes` gets a batch of its own.
---@param records OOOOSyncWireRecord[]
---@param maxBytes integer
---@return OOOOSyncWireRecord[][] batches No batch is empty; no records give no batches
function store.splitBatches(records, maxBytes)
  local batches = {}
  local batch, bytes = nil, 0
  for _, record in ipairs(records) do
    local size = store.recordSize(record)
    if not batch or bytes + size > maxBytes then
      batch, bytes = {}, 0
      batches[#batches + 1] = batch
    end
    batch[#batch + 1] = record
    bytes = bytes + size
  end
  return batches
end

---Applies a received batch in its order. A bad record is dropped together with all later records of the
---same origin in the batch: the clock of an origin must not pass a write that was not taken. A record
---whose id has no readable origin ends the batch, because it cannot be told which origin to stop.
---
---Why the order matters: records travel sorted by id and a batch is applied whole, so when the clock of
---an origin reaches an id, every record with a smaller id that the sender had to give has been applied.
---
---`validateFn` can also answer "seen": the record is good but this replica does not keep it (a character
---that is no longer in the guild). The clock then rises as if the record had been applied and then removed
---by the local cleanup, and the record does not count as dropped.
---@param tbl OOOOSyncTable
---@param records any[] Received records; every field is checked here or by `validateFn`
---@param validateFn (fun(record: OOOOSyncWireRecord): boolean|"seen")? Further checks: id time, key, payload
---@return string[] changed Keys whose stored record changed
---@return integer dropped Number of records that were not applied
function store.applyBatch(tbl, records, validateFn)
  local changed, dropped = {}, 0
  ---Origins that had a bad record in this batch
  local blocked = {}
  for index = 1, #records do
    local record = records[index]
    local id = type(record) == "table" and record.id
    if not versionId.isWellFormed(id) then
      dropped = dropped + (#records - index + 1)
      break
    end
    local origin = versionId.originOf(id)
    if blocked[origin] then
      dropped = dropped + 1
    else
      local verdict = type(record.key) == "string" and (not validateFn or validateFn(record))
      if not verdict then
        blocked[origin] = true
        dropped = dropped + 1
      elseif verdict == "seen" then
        see(tbl, id)
      elseif store.apply(tbl, record.key, id, record.payload, record.tombstone == true) then
        changed[#changed + 1] = record.key
      end
    end
  end
  return changed, dropped
end

---Lists the clock entries that another replica will still lack after it has applied `records`: origins whose
---last write here was replaced by a newer write of another origin, so no record carries their clock value.
---Without these entries the two clocks, and with them the table versions, would never become equal.
---@param tbl OOOOSyncTable
---@param remoteClock table<string, string> Origin -> id, from `parseDigest`
---@param records OOOOSyncWireRecord[] The delta from `selectDelta` for the same clock
---@return table<string, string> rest Origin -> this table's clock value
function store.clockRest(tbl, remoteClock, records)
  local reached = {}
  for _, record in ipairs(records) do
    local origin = versionId.originOf(record.id)
    if not reached[origin] or record.id > reached[origin] then
      reached[origin] = record.id
    end
  end
  local rest = {}
  for origin, id in pairs(tbl.clock) do
    local seen = remoteClock[origin]
    if (not seen or id > seen) and (not reached[origin] or id > reached[origin]) then
      rest[origin] = id
    end
  end
  return rest
end

---Raises the clock to the values of another replica's clock, after a pull from that replica is complete.
---Call it only when every batch of the pull was applied and no record was dropped: the table has then
---seen everything that the other replica has seen. An entry whose id is not of its origin is skipped.
---@param tbl OOOOSyncTable
---@param clock table<any, any> Origin -> id, from `clockRest` on the other side; checked here
---@return boolean changed true when a clock entry rose
function store.mergeClock(tbl, clock)
  local changed = false
  for origin, id in pairs(clock) do
    if versionId.isWellFormed(id) and versionId.originOf(id) == origin and see(tbl, id) then
      changed = true
    end
  end
  return changed
end

---Lists the origins for which another replica is ahead of this table, each with this table's clock value
---(`versionId.ZERO` when the origin is unknown here). The other replica then knows which records to push.
---@param tbl OOOOSyncTable
---@param remoteClock table<string, string> Origin -> id, from `parseDigest`
---@return table<string, string> wants Origin -> this table's clock value
function store.wants(tbl, remoteClock)
  local wants = {}
  for origin, id in pairs(remoteClock) do
    local seen = tbl.clock[origin] or versionId.ZERO
    if id > seen then
      wants[origin] = seen
    end
  end
  return wants
end
