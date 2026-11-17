local addonName, ns = ...

-- The tables of the shared database: the registry of table definitions and the API that feature modules
-- use to store data (.agents/00-plan.md, section 5).
--
-- This file uses no WoW API. It needs LibStub and CallbackHandler-1.0, which the host tests load as well
-- (Tests/sync_tables.lua, Tests/sync_api.lua).

---@class OOOOSyncPolicy When a table may send (plan section 7.4)
---@field when "nocombat"|"noraid"|"resting" Weakest state in which the table may send
---@field pushDelay number Seconds to wait after a local change, to collect several changes into one push
---@field minInterval number Shortest time in seconds between two pushes of the table

---@class OOOOSyncTableDefinition What a feature module passes to `ns.sync:RegisterTable`
---@field name string Lower case letters, digits, and `_`; starts with a letter; at most 32 characters
---@field schema integer Payload layout version; a change empties the stored table
---@field keyKind "character"|"free" "character": the key starts with a character name
---@field validate fun(key: string, payload: any): boolean Rejects a payload with wrong types or ranges
---@field maxRecordBytes integer Largest record, by `syncStore.estimateSize`
---@field writers "owner"|"officer"|"anyone" Who may write: the owner of the key, officers, or every member
---@field memberRelay boolean|nil Officer tables: members may copy from members when no officer is online
---@field policy OOOOSyncPolicy|nil Defaults of the send policy; omitted fields take `DEFAULT_POLICY`

---@class OOOOSync
---@field definitions table<string, OOOOSyncTableDefinition> Table name -> definition
---@field names string[] Table names in the order of registration
---@field data OOOOSyncData|nil The stored database; nil until `Initialize`
---@field timeFn (fun(): integer)|nil Server time in seconds
---@field nextId (fun(maxId: string?): string)|nil Id source of this install
---@field callbacks table CallbackHandler registry; fires "OnRecordChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)
---@field UnregisterAllCallbacks fun(owner: any)
local sync = { definitions = {}, names = {} }
ns.sync = sync

local store = ns.syncStore
local versionId = ns.versionId

---Events for feature modules and the UI, in the CallbackHandler form:
---`ns.sync.RegisterCallback(owner, "OnRecordChanged", function(event, tableName, key, payload, isRemote) end)`.
---`payload` is nil when the record was deleted. The event fires for local and for received changes.
sync.callbacks = LibStub("CallbackHandler-1.0"):New(sync)

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_NAME_LENGTH = 32
local KEY_KINDS = { character = true, free = true }
local WRITERS = { owner = true, officer = true, anyone = true }
local WHEN = { nocombat = true, noraid = true, resting = true }
---Send policy of a table that names none (plan section 5)
local DEFAULT_POLICY = { when = "nocombat", pushDelay = 300, minInterval = 600 }

---Tells whether a value is an integer of at least 1.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value >= 1 and value == math.floor(value)
end

---Checks a table definition and returns the first problem.
---@param definition any
---@return string|nil problem nil when the definition is good
local function definitionProblem(definition)
  if type(definition) ~= "table" then
    return "the definition must be a table"
  end
  local name = definition.name
  if type(name) ~= "string" or #name > MAX_NAME_LENGTH or not name:find(NAME_PATTERN) then
    return "bad name"
  end
  if not isPositiveInteger(definition.schema) then
    return "schema must be a positive integer"
  end
  if not KEY_KINDS[definition.keyKind] then
    return "keyKind must be \"character\" or \"free\""
  end
  if not WRITERS[definition.writers] then
    return "writers must be \"owner\", \"officer\", or \"anyone\""
  end
  if type(definition.validate) ~= "function" then
    return "validate must be a function"
  end
  if not isPositiveInteger(definition.maxRecordBytes) then
    return "maxRecordBytes must be a positive integer"
  end
  if definition.memberRelay ~= nil and type(definition.memberRelay) ~= "boolean" then
    return "memberRelay must be a boolean"
  end
  local policy = definition.policy
  if policy ~= nil then
    if type(policy) ~= "table" then
      return "policy must be a table"
    end
    if policy.when ~= nil and not WHEN[policy.when] then
      return "policy.when must be \"nocombat\", \"noraid\", or \"resting\""
    end
    for _, field in ipairs({ "pushDelay", "minInterval" }) do
      local value = policy[field]
      if value ~= nil and (type(value) ~= "number" or value < 0) then
        return "policy." .. field .. " must be a number that is not negative"
      end
    end
  end
  return nil
end

---Makes the stored table of a definition usable: creates it when it is missing, and empties it together
---with its clock when its schema differs from the definition or its structure is broken.
---@param name string
local function prepareStorage(name)
  local definition = sync.definitions[name]
  local tables = sync.data.tables
  local stored = tables[name]
  if type(stored) == "table" and stored.schema == definition.schema and type(stored.clock) == "table"
    and type(stored.records) == "table" then
    -- maxId and fp are derived from the clock; computing them again repairs a file that was edited by hand
    store.rebuild(stored)
  else
    tables[name] = store.newTable(definition.schema)
  end
end

---Registers a table of the shared database. A feature module calls this at file scope.
---A bad definition or a repeated name raises an error, because it is a programming error.
---@param definition OOOOSyncTableDefinition
function sync:RegisterTable(definition)
  local problem = definitionProblem(definition)
  if problem then
    error("ns.sync:RegisterTable: " .. problem, 2)
  end
  local name = definition.name
  if self.definitions[name] then
    error("ns.sync:RegisterTable: table registered twice: " .. name, 2)
  end
  local policy = definition.policy or {}
  self.definitions[name] = {
    name = name,
    schema = definition.schema,
    keyKind = definition.keyKind,
    validate = definition.validate,
    maxRecordBytes = definition.maxRecordBytes,
    writers = definition.writers,
    memberRelay = definition.memberRelay == true,
    policy = {
      when = policy.when or DEFAULT_POLICY.when,
      pushDelay = policy.pushDelay or DEFAULT_POLICY.pushDelay,
      minInterval = policy.minInterval or DEFAULT_POLICY.minInterval,
    },
  }
  self.names[#self.names + 1] = name
  if self.data then
    prepareStorage(name)
  end
end

---Connects the registry to the stored database, after the saved variables have loaded and migrated.
---A stored table without a definition stays untouched: a newer addon version may have written it.
---@param data OOOOSyncData `db.global.sync`
---@param timeFn fun(): integer Server time in seconds
---@param randomFn fun(m: integer, n: integer): integer Like math.random(m, n)
function sync:Initialize(data, timeFn, randomFn)
  self.data = data
  self.timeFn = timeFn
  self.nextId = versionId.newGenerator(data.origin, timeFn, randomFn)
  for _, name in ipairs(self.names) do
    prepareStorage(name)
  end
end

---Returns the origin of this install; nil before `Initialize`.
---@return string|nil
function sync:GetOrigin()
  return self.data and self.data.origin
end

---Returns the stored table and the definition of a registered table.
---@param tableName any
---@return OOOOSyncTable|nil tbl nil when the table cannot be used
---@return OOOOSyncTableDefinition|nil definition
---@return string|nil reason Why there is no table: "unknown table" or "not ready"
function sync:GetTable(tableName)
  local definition = self.definitions[tableName]
  if not definition then
    return nil, nil, "unknown table"
  end
  if not self.data then
    return nil, nil, "not ready"
  end
  return self.data.tables[tableName], definition
end

--------------------------------------------------------------------------------
-- API for feature modules
--------------------------------------------------------------------------------

---Longest key of a record, in bytes
sync.MAX_KEY_LENGTH = 64
---Deepest nesting of tables in a payload
local MAX_PAYLOAD_DEPTH = 8

---Table name -> server time of the first local change that has not been pushed yet (plan section 7.3)
---@type table<string, integer>
sync.dirtySince = {}

---Tells whether a value can be a record key.
---@param key any
---@return boolean
local function isKey(key)
  return type(key) == "string" and #key >= 1 and #key <= sync.MAX_KEY_LENGTH
end

---Tells whether a value can travel in a message and be stored: strings, booleans, finite numbers, and
---tables of these with string or number keys.
---@param value any
---@param depth integer?
---@return boolean
local function isPlainData(value, depth)
  local kind = type(value)
  if kind == "string" or kind == "boolean" then
    return true
  elseif kind == "number" then
    -- NaN is not equal to itself; the infinities do not survive a serializer
    return value == value and value ~= math.huge and value ~= -math.huge
  elseif kind ~= "table" or (depth or 0) >= MAX_PAYLOAD_DEPTH then
    return false
  end
  for key, item in pairs(value) do
    local keyKind = type(key)
    if (keyKind ~= "string" and keyKind ~= "number") or not isPlainData(key)
      or not isPlainData(item, (depth or 0) + 1) then
      return false
    end
  end
  return true
end

---Compares two payloads by content.
---@param a any
---@param b any
---@return boolean
local function isEqual(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for key, item in pairs(a) do
    if not isEqual(item, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

---Copies a payload, so that a later change of the caller's table cannot change the stored record.
---@param value any
---@return any
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

---Marks a table as having local changes that are not pushed yet.
---@param tableName string
local function markDirty(tableName)
  sync.dirtySince[tableName] = sync.dirtySince[tableName] or sync.timeFn()
end

---Writes a record with a new version id, which is greater than every id that the table has seen.
---Nothing is written when the payload equals the stored one, so a repeated scan sends nothing.
---@param tableName string
---@param key string 1 to 64 bytes
---@param payload any Strings, booleans, numbers, and tables of these; it must pass the table's `validate`
---@return boolean|nil written true: written; false: equal to the stored payload; nil: refused
---@return string|nil reason Why the write was refused
function sync:Put(tableName, key, payload)
  local tbl, definition, reason = self:GetTable(tableName)
  if not tbl or not definition then
    return nil, reason
  end
  if not isKey(key) then
    return nil, "bad key"
  end
  if payload == nil or not isPlainData(payload) or not definition.validate(key, payload) then
    return nil, "bad payload"
  end
  local record = tbl.records[key]
  if record and not record.x and isEqual(record.d, payload) then
    return false
  end
  local stored = copy(payload)
  store.apply(tbl, key, self.nextId(tbl.maxId), stored)
  markDirty(tableName)
  self.callbacks:Fire("OnRecordChanged", tableName, key, stored, false)
  return true
end

---Deletes a record by writing a tombstone with a new version id. A key that is absent or already
---deleted is left alone.
---@param tableName string
---@param key string
---@return boolean|nil deleted true: deleted; false: there was no record; nil: refused
---@return string|nil reason Why the delete was refused
function sync:Delete(tableName, key)
  local tbl, definition, reason = self:GetTable(tableName)
  if not tbl or not definition then
    return nil, reason
  end
  if not isKey(key) then
    return nil, "bad key"
  end
  local record = tbl.records[key]
  if not record or record.x then
    return false
  end
  store.apply(tbl, key, self.nextId(tbl.maxId), nil, true)
  markDirty(tableName)
  self.callbacks:Fire("OnRecordChanged", tableName, key, nil, false)
  return true
end

---Returns the payload of a record. The table that is returned is the stored one: do not change it.
---@param tableName string
---@param key string
---@return any payload nil when there is no record, when it was deleted, or when the table cannot be used
function sync:Get(tableName, key)
  local tbl = self:GetTable(tableName)
  local record = tbl and tbl.records[key]
  if record and not record.x then
    return record.d
  end
  return nil
end

---Iterates over the records of a table that are not deleted: `for key, payload in ns.sync:Iterate(name) do`.
---The payloads are the stored tables: do not change them, and do not write to the table inside the loop.
---@param tableName string
---@return fun(): string|nil, any iterator Gives nothing when the table cannot be used
function sync:Iterate(tableName)
  local tbl = self:GetTable(tableName)
  local records = tbl and tbl.records or {}
  local key, record
  return function()
    repeat
      key, record = next(records, key)
    until not key or not record.x
    if key then
      return key, record.d
    end
    return nil
  end
end

---Counts the records of a table.
---@param tableName string
---@return integer live Records that are not deleted
---@return integer deleted Tombstones
function sync:Count(tableName)
  local tbl = self:GetTable(tableName)
  local live, deleted = 0, 0
  for _, record in pairs(tbl and tbl.records or {}) do
    if record.x then
      deleted = deleted + 1
    else
      live = live + 1
    end
  end
  return live, deleted
end
