local addonName, ns = ...

-- The messages of the shared database: how they are written, read, and checked
-- (.agents/00-plan.md, sections 6 and 8).
--
-- A message from another member is untrusted input. `decode` hands out only fields that it has checked, in
-- new tables, and it never raises. Received text goes to the serializer and nowhere else: it is never run.
--
-- This file uses no WoW API. The serializer is passed in, so the host tests run it with a stub
-- (Tests/sync_protocol.lua). It needs Base94.lua, VersionId.lua, and SyncStore.lua.

---@class OOOOSerializer What `protocol.new` needs; AceSerializer-3.0 has this form
---@field Serialize fun(self: OOOOSerializer, ...: any): string
---@field Deserialize fun(self: OOOOSerializer, text: string): boolean, ...

---@class OOOOSyncCodec Writes and reads messages with one serializer
---@field encode fun(messageType: string, ...: any): string
---@field decode fun(text: any): string|nil, any

---@class OOOOSyncProtocol
local protocol = {}
ns.syncProtocol = protocol

local base94 = ns.base94
local versionId = ns.versionId
local store = ns.syncStore

---Version of the message layout. A receiver ignores a message with a greater one.
protocol.VERSION = 1
---Reason that `decode` gives for a message of a newer addon version
protocol.NEWER = "newer"
---Most tables in one hello or summary
protocol.MAX_TABLES = 64
---Longest table name, as in SyncTables.lua
protocol.MAX_NAME_LENGTH = 32
---Length of a table version: an id of 11 characters and a fingerprint of 5
protocol.TABLE_VERSION_LENGTH = 16

---Longest record key, as in SyncTables.lua
protocol.MAX_KEY_LENGTH = 64
---Most origins in a digest, a clock rest, or a list of wants: far more than the guild has installs
protocol.MAX_ORIGINS = 2000
---Most records in one delta batch; a batch of 2 KB holds about 100 of the smallest records
protocol.MAX_BATCH_RECORDS = 500
---Greatest batch number of one pull
protocol.MAX_BATCH_NUMBER = 100000
---Greatest nonce: a pull request carries a random number from 1 to this
protocol.MAX_NONCE = 2147483647
---Greatest schema number of a table
protocol.MAX_SCHEMA = 1000000
---Longest wait in seconds that a refusal can ask for
protocol.MAX_RETRY_SECONDS = 3600

---Message type -> the channel on which it travels. A type that arrives on the other channel is dropped.
---@type table<string, "GUILD"|"WHISPER">
protocol.CHANNELS = {
  H = "GUILD", -- hello: sent once after login, asks peers to answer
  S = "GUILD", -- summary: answer to a hello, and notice after a merge
  Q = "WHISPER", -- pull request: asks one peer for the records that the sender lacks
  D = "WHISPER", -- delta: one batch of the answer to a pull request
  B = "WHISPER", -- busy: the peer refuses a pull request
  P = "GUILD", -- push: new records for everybody
}

---@class OOOOSyncPullRequest Checked fields of a `Q`
---@field table string Table name; the receiver may not have it
---@field schema integer Payload layout version of the table on the sender's side
---@field nonce integer Random number that the answers repeat
---@field clock table<string, string> Origin -> id: the clock of the sender, read from the digest

---@class OOOOSyncDelta Checked fields of a `D`
---@field table string
---@field nonce integer The nonce of the pull request
---@field batch integer Number of the batch, from 1
---@field last boolean true in the last batch of the pull
---@field records OOOOSyncWireRecord[] In ascending id order; payloads are not checked here
---@field rest table<string, string> Origin -> id: clock entries that no record carries; empty before the last batch
---@field wants table<string, string> Origin -> the sender's clock value where the requester is ahead

---@class OOOOSyncBusy Checked fields of a `B`
---@field table string
---@field nonce integer The nonce of the pull request
---@field reason string Why the pull is refused: a `protocol.REASON_*` value, or a word of a newer version
---@field retry number Seconds after which the request may be repeated

---@class OOOOSyncPush Checked fields of a `P`
---@field table string
---@field schema integer Payload layout version of the table on the sender's side
---@field version string Table version of the sender when it sent the push
---@field own boolean true: the sender's own new writes; false: records passed on after a pull
---@field base table<string, string> Origin -> the id before the first pushed record of that origin; the zero
---id when the sender pushed nothing of that origin before
---@field records OOOOSyncWireRecord[] In ascending id order; payloads are not checked here
---@field rest table<string, string> Origin -> id: clock values that no record of this push carries

---Reasons of a refusal
protocol.REASON_BUSY = "busy" -- the peer serves another pull, or may not send now
protocol.REASON_UNKNOWN = "unknown" -- the peer does not have the table
protocol.REASON_SCHEMA = "schema" -- the peer has the table with another schema

---Tells whether a value is an integer in a range.
---@param value any
---@param low integer
---@param high integer
---@return boolean
local function isInteger(value, low, high)
  return type(value) == "number" and value >= low and value <= high and value == math.floor(value)
end

---Tells whether a value has the form of a table name of SyncTables.lua.
---@param name any
---@return boolean
local function isTableName(name)
  return type(name) == "string" and #name <= protocol.MAX_NAME_LENGTH and name:find("^[a-z][a-z0-9_]*$") ~= nil
end

---Tells whether a value is an origin: 4 base-94 characters.
---@param origin any
---@return boolean
local function isOrigin(origin)
  return type(origin) == "string" and #origin == 4 and base94.isValid(origin)
end

---Checks a table `origin -> id` and copies it. A missing table gives an empty one.
---@param clock any
---@param ownIds boolean true when every id must be an id of its origin
---@return table<string, string>|nil clock nil when the field is bad
local function checkClock(clock, ownIds)
  if clock == nil then
    return {}
  end
  if type(clock) ~= "table" then
    return nil
  end
  local result, count = {}, 0
  for origin, id in pairs(clock) do
    count = count + 1
    if count > protocol.MAX_ORIGINS or not isOrigin(origin) or not versionId.isWellFormed(id)
      or (ownIds and versionId.originOf(id) ~= origin) then
      return nil
    end
    result[origin] = id
  end
  return result
end

---Puts records into the form in which they travel: `{ key, id, payload }`, or `{ key, id, [4] = true }` for
---a tombstone.
---@param records OOOOSyncWireRecord[]
---@return any[] packed
function protocol.packRecords(records)
  local packed = {}
  for index, record in ipairs(records) do
    if record.tombstone then
      packed[index] = { record.key, record.id, [4] = true }
    else
      packed[index] = { record.key, record.id, record.payload }
    end
  end
  return packed
end

---Checks the records of a delta and puts them back into the form of SyncStore.lua. The key and the id of
---every record are checked; the payload is checked by the receiver against its table definition.
---@param packed any
---@return OOOOSyncWireRecord[]|nil records nil when the field is bad
local function unpackRecords(packed)
  if type(packed) ~= "table" then
    return nil
  end
  local count = 0
  for _ in pairs(packed) do
    count = count + 1
    if count > protocol.MAX_BATCH_RECORDS then
      return nil
    end
  end
  local records = {}
  -- Every index from 1 to the number of entries must be there: a list without gaps and without other keys
  for index = 1, count do
    local item = packed[index]
    if type(item) ~= "table" then
      return nil
    end
    local key, id, payload, tombstone = item[1], item[2], item[3], item[4]
    if type(key) ~= "string" or #key < 1 or #key > protocol.MAX_KEY_LENGTH or not versionId.isWellFormed(id) then
      return nil
    end
    if tombstone == true and payload == nil then
      records[index] = { key = key, id = id, tombstone = true }
    elseif tombstone == nil and payload ~= nil then
      records[index] = { key = key, id = id, payload = payload }
    else
      return nil
    end
  end
  return records
end

---Checks the field of a hello or a summary, `table name -> table version`, and copies it.
---@param versions any
---@return table<string, string>|nil versions nil when the field is bad
---@return string|nil reason
local function checkVersions(versions)
  if type(versions) ~= "table" then
    return nil, "versions are not a table"
  end
  local result, count = {}, 0
  for name, version in pairs(versions) do
    count = count + 1
    if count > protocol.MAX_TABLES then
      return nil, "too many tables"
    end
    if type(name) ~= "string" or #name < 1 or #name > protocol.MAX_NAME_LENGTH then
      return nil, "bad table name"
    end
    if type(version) ~= "string" or #version ~= protocol.TABLE_VERSION_LENGTH or not base94.isValid(version) then
      return nil, "bad table version"
    end
    result[name] = version
  end
  return result
end

---Message type -> function that checks the fields after the type and returns them, or nil and a reason.
---@type table<string, fun(...: any): any, string|nil>
local checks = {
  H = checkVersions,
  S = checkVersions,
}

---Pull request: table, schema, nonce, digest. The digest is the clock as one string of ids.
---@return OOOOSyncPullRequest|nil
---@return string|nil reason
function checks.Q(tableName, schema, nonce, digest)
  if not isTableName(tableName) then
    return nil, "bad table name"
  end
  if not isInteger(schema, 1, protocol.MAX_SCHEMA) then
    return nil, "bad schema"
  end
  if not isInteger(nonce, 1, protocol.MAX_NONCE) then
    return nil, "bad nonce"
  end
  if type(digest) ~= "string" or #digest > protocol.MAX_ORIGINS * versionId.LENGTH then
    return nil, "bad digest"
  end
  local clock = store.parseDigest(digest)
  if not clock then
    return nil, "bad digest"
  end
  return { table = tableName, schema = schema, nonce = nonce, clock = clock }
end

---Delta: table, nonce, batch number, last flag, records, clock rest, wants.
---@return OOOOSyncDelta|nil
---@return string|nil reason
function checks.D(tableName, nonce, batch, last, packed, rest, wants)
  if not isTableName(tableName) then
    return nil, "bad table name"
  end
  if not isInteger(nonce, 1, protocol.MAX_NONCE) then
    return nil, "bad nonce"
  end
  if not isInteger(batch, 1, protocol.MAX_BATCH_NUMBER) then
    return nil, "bad batch number"
  end
  if type(last) ~= "boolean" then
    return nil, "bad last flag"
  end
  local records = unpackRecords(packed)
  if not records then
    return nil, "bad records"
  end
  -- The rest holds clock values of the sender: ids of their origin. The wants hold the sender's value for
  -- an origin where the requester is ahead, which is the zero id when the sender has none.
  local checkedRest, checkedWants = checkClock(rest, true), checkClock(wants, false)
  if not checkedRest then
    return nil, "bad clock rest"
  end
  if not checkedWants then
    return nil, "bad wants"
  end
  return { table = tableName, nonce = nonce, batch = batch, last = last, records = records, rest = checkedRest,
    wants = checkedWants }
end

---Push: table, schema, table version, own flag, base, records, clock rest.
---@return OOOOSyncPush|nil
---@return string|nil reason
function checks.P(tableName, schema, version, own, base, packed, rest)
  if not isTableName(tableName) then
    return nil, "bad table name"
  end
  if not isInteger(schema, 1, protocol.MAX_SCHEMA) then
    return nil, "bad schema"
  end
  if type(version) ~= "string" or #version ~= protocol.TABLE_VERSION_LENGTH or not base94.isValid(version) then
    return nil, "bad table version"
  end
  if type(own) ~= "boolean" then
    return nil, "bad own flag"
  end
  -- A base is an id of its origin, or the zero id for an origin of which nothing was pushed before
  local checkedBase = checkClock(base, false)
  if not checkedBase or base == nil then
    return nil, "bad base"
  end
  for origin, id in pairs(checkedBase) do
    if id ~= versionId.ZERO and versionId.originOf(id) ~= origin then
      return nil, "bad base"
    end
  end
  local records = unpackRecords(packed)
  if not records then
    return nil, "bad records"
  end
  local checkedRest = checkClock(rest, true)
  if not checkedRest then
    return nil, "bad clock rest"
  end
  return { table = tableName, schema = schema, version = version, own = own, base = checkedBase, records = records,
    rest = checkedRest }
end

---Busy: table, nonce, reason, retry seconds.
---@return OOOOSyncBusy|nil
---@return string|nil reason
function checks.B(tableName, nonce, reason, retry)
  if not isTableName(tableName) then
    return nil, "bad table name"
  end
  if not isInteger(nonce, 1, protocol.MAX_NONCE) then
    return nil, "bad nonce"
  end
  if type(reason) ~= "string" or #reason < 1 or #reason > 16 or not reason:find("^[a-z]+$") then
    return nil, "bad reason"
  end
  if type(retry) ~= "number" or retry ~= retry or retry < 0 or retry > protocol.MAX_RETRY_SECONDS then
    return nil, "bad retry time"
  end
  return { table = tableName, nonce = nonce, reason = reason, retry = retry }
end

---Makes the pair of functions that write and read messages with a serializer.
---@param serializer OOOOSerializer
---@return OOOOSyncCodec
function protocol.new(serializer)
  local codec = {}

  ---Writes a message: the protocol version, the type, and the fields of the type.
  ---@param messageType string A key of `protocol.CHANNELS`
  ---@param ... any Fields of the type
  ---@return string text
  function codec.encode(messageType, ...)
    return serializer:Serialize(protocol.VERSION, messageType, ...)
  end

  ---Reads the fields that the serializer gave and checks them.
  ---@param succeeded boolean What `Deserialize` returned first
  ---@param version any
  ---@param messageType any
  ---@param ... any Fields of the type
  ---@return string|nil messageType
  ---@return any fieldsOrReason
  local function check(succeeded, version, messageType, ...)
    if not succeeded then
      return nil, "not a message"
    end
    if type(version) ~= "number" or version < 1 or version ~= math.floor(version) then
      return nil, "bad protocol version"
    end
    if version > protocol.VERSION then
      return nil, protocol.NEWER
    end
    local checkFields = type(messageType) == "string" and checks[messageType]
    if not checkFields then
      return nil, "unknown type"
    end
    local fields, reason = checkFields(...)
    if fields == nil then
      return nil, reason
    end
    return messageType, fields
  end

  ---Takes the results of the protected call of `Deserialize`. Varargs are passed on, not packed into a
  ---table, because `unpack` has another name on the host Lua.
  ---@param called boolean false when `Deserialize` raised
  ---@param ... any What `Deserialize` returned
  ---@return string|nil messageType
  ---@return any fieldsOrReason
  local function afterCall(called, ...)
    if not called then
      return nil, "not a message"
    end
    return check(...)
  end

  ---Reads and checks a received message. It never raises.
  ---@param text any What arrived
  ---@return string|nil messageType nil when the message is refused
  ---@return any fields The checked fields of the type, in a new table; the reason when refused.
  ---The reason `protocol.NEWER` means that the sender has a newer addon version.
  function codec.decode(text)
    if type(text) ~= "string" then
      return nil, "not a string"
    end
    -- AceSerializer catches its own errors; the pcall covers a serializer that does not
    return afterCall(pcall(serializer.Deserialize, serializer, text))
  end

  return codec
end
