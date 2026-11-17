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
  local origin = versionId.originOf(id)
  local seen = tbl.clock[origin]
  if not seen or id > seen then
    tbl.fp = (tbl.fp - (seen and base94.hash(seen) or 0) + base94.hash(id)) % TWO_32
    tbl.clock[origin] = id
    if id > tbl.maxId then
      tbl.maxId = id
    end
  end
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

---Computes `maxId` and `fp` again from the clock: after the saved variables load, and in tests.
---The normal path never needs it, because `apply` keeps both current.
---@param tbl OOOOSyncTable
function store.rebuild(tbl)
  local maxId, fp = versionId.ZERO, 0
  for _, id in pairs(tbl.clock) do
    fp = (fp + base94.hash(id)) % TWO_32
    if id > maxId then
      maxId = id
    end
  end
  tbl.maxId, tbl.fp = maxId, fp
end
