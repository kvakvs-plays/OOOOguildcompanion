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
---@return OOOOSyncTableDefinition|string definitionOrReason The definition, or why there is no table
function sync:GetTable(tableName)
  local definition = self.definitions[tableName]
  if not definition then
    return nil, "unknown table"
  end
  if not self.data then
    return nil, "not ready"
  end
  return self.data.tables[tableName], definition
end
