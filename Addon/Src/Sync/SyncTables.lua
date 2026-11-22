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
---@field keyKind "character"|"free" "character": the key starts with a character name; an officer table needs
---"free"
---@field validate fun(key: string, payload: any): boolean Rejects a payload with wrong types or ranges
---@field maxRecordBytes integer Largest record, by `syncStore.recordSize`: `Put` refuses a larger one, and
---a larger one that arrives is dropped
---@field writers "owner"|"anyone"|"officer"|"self" Who may write a key: the character that it names, every
---member, only an officer, or only the character that it names with a write of its own character origin
---("officer" and "self" are protected tables, plan section 14)
---@field policy OOOOSyncPolicy|nil Defaults of the send policy; omitted fields take `DEFAULT_POLICY`
---@field maxAge number|nil Seconds for which a record is kept, counted from the time of its id; a record that
---is older is not stored on receive and is removed by `Expire`. nil: records are kept whatever their age
---@field gapCheckHours integer|nil Number of the last hours in which the replicas compare their records per
---hour and fill the holes that the clock does not show (plan section 4.5; SyncGaps.lua). nil: no check. Not
---for a protected table.

---@class OOOOSync
---@field definitions table<string, OOOOSyncTableDefinition> Table name -> definition
---@field names string[] Table names in the order of registration
---@field data OOOOSyncData|nil The stored database; nil until `Initialize`
---@field timeFn (fun(): integer)|nil Server time in seconds
---@field randomFn (fun(m: integer, n: integer): integer)|nil Random source of the id generators
---@field nextId (fun(maxId: string?): string)|nil Id source of this install's origin
---@field generators table<string, fun(maxId: string?): string> Origin -> its id source, made when first used;
---the install origin and the character origins of self tables (plan section 14.4)
---@field playerNameFn (fun(): string|nil)|nil Gives the name of the logged-in character, for the owner rule
---@field isOfficerFn (fun(): boolean)|nil Tells whether the logged-in character is an officer
---@field isBehindFn (fun(tableName: string): boolean)|nil Set by the session (SyncSession.lua): `IsBehind`
---@field IsAltOf (fun(self: OOOOSync, name: string, other: string): boolean)|nil Added by SyncCharacter.lua
---@field IsOriginOf (fun(self: OOOOSync, name: string, origin: string): boolean)|nil Added by SyncCharacter.lua
---@field callbacks table CallbackHandler registry; fires "OnRecordChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)
---@field UnregisterAllCallbacks fun(owner: any)
local sync = { definitions = {}, names = {}, generators = {} }
ns.sync = sync

local store = ns.syncStore
local versionId = ns.versionId
local base94 = ns.base94

---Events for feature modules and the UI, in the CallbackHandler form:
---`ns.sync.RegisterCallback(owner, "OnRecordChanged", function(event, tableName, key, payload, isRemote,
---firstHand) end)`.
---`payload` is nil when the record was deleted or removed by the local cleanup. The event fires for local
---and for received changes. `firstHand` (plan section 14.8) is true for a local write (`Put`, `Append`,
---`Delete`), and for a record of a table with `writers = "self"` that arrived in a push whose sender is the
---character that the key names; false or nil otherwise (a pull, a push of another sender, the cleanup).
sync.callbacks = LibStub("CallbackHandler-1.0"):New(sync)

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_NAME_LENGTH = store.MAX_TABLE_NAME_LENGTH
local KEY_KINDS = { character = true, free = true }
---The values of `writers`. "officer" and "self" make a protected table: only an officer, or only the character
---that a key names, writes it, and only what an officer or that character sends is taken (plan section 14.3)
local WRITERS = { owner = true, anyone = true, officer = true, self = true }
local WHEN = { nocombat = true, noraid = true, resting = true }
---Most hours of a gap check: what one message with the counts carries (SyncProtocol.lua)
local MAX_GAP_HOURS = 96
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
    return "writers must be \"owner\", \"anyone\", \"officer\", or \"self\""
  end
  -- A key of a self table names its writer
  if definition.writers == "self" and definition.keyKind ~= "character" then
    return "writers = \"self\" needs keyKind = \"character\""
  end
  -- The roster cleanup is a local delete: it must not take away what an officer stands for (a due of a member
  -- who left stays visible), so an officer table names characters inside free keys
  if definition.writers == "officer" and definition.keyKind ~= "free" then
    return "writers = \"officer\" needs keyKind = \"free\""
  end
  if type(definition.validate) ~= "function" then
    return "validate must be a function"
  end
  if not isPositiveInteger(definition.maxRecordBytes) then
    return "maxRecordBytes must be a positive integer"
  end
  local maxAge = definition.maxAge
  if maxAge ~= nil and (type(maxAge) ~= "number" or maxAge <= 0 or maxAge == math.huge or maxAge ~= maxAge) then
    return "maxAge must be a positive number"
  end
  local gapCheckHours = definition.gapCheckHours
  if gapCheckHours ~= nil then
    if not isPositiveInteger(gapCheckHours) or gapCheckHours > MAX_GAP_HOURS then
      return "gapCheckHours must be an integer from 1 to " .. MAX_GAP_HOURS
    end
    -- A fill is taken from any member, and nothing vouches for it
    if definition.writers == "officer" or definition.writers == "self" then
      return "gapCheckHours is not for a protected table"
    end
    -- The hours that are compared must be ones that no replica has begun to remove
    if maxAge ~= nil and gapCheckHours * store.HOUR >= maxAge then
      return "gapCheckHours must be shorter than maxAge"
    end
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
  -- A hello with more tables is refused by its receivers (SyncProtocol.lua)
  if #self.names >= store.MAX_TABLES then
    error("ns.sync:RegisterTable: more than " .. store.MAX_TABLES .. " tables", 2)
  end
  local policy = definition.policy or {}
  self.definitions[name] = {
    name = name,
    schema = definition.schema,
    keyKind = definition.keyKind,
    validate = definition.validate,
    maxRecordBytes = definition.maxRecordBytes,
    writers = definition.writers,
    maxAge = definition.maxAge,
    gapCheckHours = definition.gapCheckHours,
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
---@param playerNameFn (fun(): string|nil)? Name of the logged-in character as the roster shows it; without
---it nothing can be written into a table with `writers = "owner"`
---@param isOfficerFn (fun(): boolean)? Tells whether the logged-in character is an officer by the guild
---roster; without it the character counts as a member
function sync:Initialize(data, timeFn, randomFn, playerNameFn, isOfficerFn)
  self.data = data
  self.timeFn = timeFn
  self.randomFn = randomFn
  self.playerNameFn = playerNameFn
  self.isOfficerFn = isOfficerFn
  self.nextId = versionId.newGenerator(data.origin, timeFn, randomFn)
  self.generators = { [data.origin] = self.nextId }
  for _, name in ipairs(self.names) do
    prepareStorage(name)
  end
end

---Returns the origin of this install; nil before `Initialize`.
---@return string|nil
function sync:GetOrigin()
  return self.data and self.data.origin
end

---94^4: the number of origins, written out so that the modulo stays an integer on Lua 5.4
local ORIGIN_VALUES = 78074896

---Returns the origin of the local writes in a table. It is the one place that decides it:
--- - in a table with `writers = "self"`, the character origin: `base94(hash(install origin .. ":" .. name)
---   mod 94^4, 4)`. A clock value then covers the writes of one character only, so the unsent writes of an alt
---   wait under their own clock entry until that alt logs in (plan section 14.4);
--- - in every other table, the install origin.
---@param tableName string
---@return string|nil origin nil before `Initialize`, for a table that is not registered, and in a self table
---while the name of the character is unknown
function sync:OriginFor(tableName)
  local definition = self.definitions[tableName]
  local installOrigin = self:GetOrigin()
  if not definition or not installOrigin then
    return nil
  end
  if definition.writers ~= "self" then
    return installOrigin
  end
  local name = self.playerNameFn and self.playerNameFn()
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return base94.encode(base94.hash(installOrigin .. ":" .. name) % ORIGIN_VALUES, 4)
end

---Tells whether the logged-in character is an officer (plan section 14.2). The answer follows the roster:
---it is false until the roster is read.
---@return boolean
function sync:IsOfficer()
  return self.isOfficerFn ~= nil and self.isOfficerFn() == true
end

---Tells whether an online peer has announced a newer state of a protected table that no online officer can
---supply (plan section 14.6): a feature warns before an officer decides on old data. False without a session
---and for a table that is not protected.
---@param tableName string
---@return boolean
function sync:IsBehind(tableName)
  return self.isBehindFn ~= nil and self.isBehindFn(tableName) == true
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
sync.MAX_KEY_LENGTH = store.MAX_KEY_LENGTH
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

---Returns the character name that a key starts with: the whole key, or the part before the first `:` of a
---joined key (`"Nota Scam:171"`). A name has a space, so the key is never split on whitespace.
---@param key string
---@return string|nil name nil when the key starts with `:`
function sync.keyName(key)
  return key:match("^[^:]+")
end

---The owner rule (plan section 5.2), in one place for `Put`, `Delete`, and the receiver of a push: in a
---table with `writers = "owner"`, a key may be written only by the character that it names. For a received
---push the alts of the sender count as well, because a push carries all unsent writes of the player.
---@param definition OOOOSyncTableDefinition
---@param key string
---@param writer string|nil Character name: the logged-in character, or the sender of a push
---@param withAlts boolean? true: also accept a key of a character that the table `character` lists under
---an origin of the writer's own record
---@return boolean allowed true for a table with `writers = "anyone"` or `"officer"`: the rank rule of an officer
---table is checked by `WriteRefusal` and by the receivers, not by the key. In a table with `writers = "self"`
---the key must name the writer itself; `withAlts` is ignored there.
function sync:MayWrite(definition, key, writer, withAlts)
  local writers = definition.writers
  if writers ~= "owner" and writers ~= "self" then
    return true
  end
  local name = sync.keyName(key)
  if not name or not writer then
    return false
  end
  if name == writer then
    return true
  end
  return writers == "owner" and withAlts == true and self.IsAltOf ~= nil and self:IsAltOf(name, writer)
end

---Tells whether a table is protected (plan section 14): only what an officer sends is taken from others, and
---only an officer is the source of a pull. The tables with `writers = "owner"` or `"anyone"` are not.
---@param tableName any
---@return boolean
function sync:IsProtected(tableName)
  local definition = self.definitions[tableName]
  return definition ~= nil and (definition.writers == "officer" or definition.writers == "self")
end

---Tells why the logged-in character may not write a key of a table, by the rule of the table's `writers`:
---the rank in an officer table, the owner rule otherwise. `Put`, `Delete`, and `Append` share it.
---@param definition OOOOSyncTableDefinition
---@param key string
---@return string|nil reason nil when the write is allowed; "not an officer", "not the owner", or "not ready"
---(a self table while the name of the character, and with it the character origin, is unknown)
function sync:WriteRefusal(definition, key)
  if definition.writers == "officer" then
    return (not self:IsOfficer()) and "not an officer" or nil
  end
  if definition.writers == "self" and not self:OriginFor(definition.name) then
    return "not ready"
  end
  if not self:MayWrite(definition, key, self.playerNameFn and self.playerNameFn()) then
    return "not the owner"
  end
  return nil
end

---Makes a fresh version id for a table: greater than every id that the table has seen, of the origin that
---`OriginFor` gives. A feature uses it for a key that must be unique (an event id); `Put`, `Append`, and
---`Delete` take the id of a write from here. Each origin has one generator, so its ids always increase.
---@param tableName string
---@return string|nil id nil when the table cannot be used, or its origin is not known yet
function sync:NewId(tableName)
  local tbl = self:GetTable(tableName)
  local origin = tbl and self:OriginFor(tableName)
  if not tbl or not origin then
    return nil
  end
  local generator = self.generators[origin]
  if not generator then
    generator = versionId.newGenerator(origin, self.timeFn, self.randomFn)
    self.generators[origin] = generator
  end
  return generator(tbl.maxId)
end

---Returns the version id of a stored record that is not deleted.
---@param tableName string
---@param key string
---@return string|nil id nil when there is no record, when it was deleted, or when the table cannot be used
function sync:GetId(tableName, key)
  local tbl = self:GetTable(tableName)
  local record = tbl and tbl.records[key]
  if record and not record.x then
    return record.v
  end
  return nil
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
---In a table with `writers = "owner"` the key must start with the name of the logged-in character; a table
---with `writers = "officer"` is written only by an officer.
---@return boolean|nil written true: written; false: equal to the stored payload; nil: refused
---@return string|nil reason Why the write was refused: "unknown table", "not ready", "bad key",
---"not the owner", "not an officer", "bad payload", or "too large"
function sync:Put(tableName, key, payload)
  local tbl, definition, reason = self:GetTable(tableName)
  if not tbl or not definition then
    return nil, reason
  end
  if not isKey(key) then
    return nil, "bad key"
  end
  local refusal = self:WriteRefusal(definition, key)
  if refusal then
    return nil, refusal
  end
  if payload == nil or not isPlainData(payload) or not definition.validate(key, payload) then
    return nil, "bad payload"
  end
  if store.recordSize({ key = key, payload = payload }) > definition.maxRecordBytes then
    return nil, "too large"
  end
  local record = tbl.records[key]
  if record and not record.x and isEqual(record.d, payload) then
    return false
  end
  local id = self:NewId(tableName)
  if not id then
    return nil, "not ready"
  end
  local stored = copy(payload)
  store.apply(tbl, key, id, stored)
  markDirty(tableName)
  self.callbacks:Fire("OnRecordChanged", tableName, key, stored, false, true)
  return true
end

---Adds a record under its own version id as key, for a table that is a log: every entry is written once
---and never changed, and the keys sorted with `<` give the entries in the order of time (plan section 5.3).
---The table must have `keyKind = "free"` and `writers = "anyone"`, or `writers = "officer"` for an officer.
---@param tableName string
---@param payload any As in `Put`; `validate` gets the new id as key
---@return string|nil id The id and key of the new record; nil when the write was refused
---@return string|nil reason Why: "unknown table", "not ready", "bad key" (the table is keyed by character),
---"not the owner", "not an officer", "bad payload", or "too large"
function sync:Append(tableName, payload)
  local tbl, definition, reason = self:GetTable(tableName)
  if not tbl or not definition then
    return nil, reason
  end
  if definition.keyKind ~= "free" then
    return nil, "bad key"
  end
  if definition.writers == "officer" then
    if not self:IsOfficer() then
      return nil, "not an officer"
    end
  elseif definition.writers ~= "anyone" then
    -- An id names no character, so the owner rule can never pass
    return nil, "not the owner"
  end
  if payload == nil or not isPlainData(payload) then
    return nil, "bad payload"
  end
  -- The id is made before the last checks because it is the key that they look at. One that is refused is
  -- not used again, which costs nothing: the ids of an install only have to increase.
  local id = self:NewId(tableName)
  if not id then
    return nil, "not ready"
  end
  if not definition.validate(id, payload) then
    return nil, "bad payload"
  end
  if store.recordSize({ key = id, payload = payload }) > definition.maxRecordBytes then
    return nil, "too large"
  end
  local stored = copy(payload)
  store.apply(tbl, id, id, stored)
  markDirty(tableName)
  self.callbacks:Fire("OnRecordChanged", tableName, id, stored, false, true)
  return id
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
  local refusal = self:WriteRefusal(definition, key)
  if refusal then
    return nil, refusal
  end
  local record = tbl.records[key]
  if not record or record.x then
    return false
  end
  local id = self:NewId(tableName)
  if not id then
    return nil, "not ready"
  end
  store.apply(tbl, key, id, nil, true)
  markDirty(tableName)
  self.callbacks:Fire("OnRecordChanged", tableName, key, nil, false, true)
  return true
end

---Checks a record that another replica sent, for `ApplyRemote` and `FillRemote`: the time of its id, and its
---payload against the table definition and its size limit.
---@param definition OOOOSyncTableDefinition
---@param record OOOOSyncWireRecord The key and the id have the right form
---@param now integer Server time
---@return boolean good
local function isGoodRemote(definition, record, now)
  if not versionId.isValid(record.id, now) then
    return false
  end
  if record.tombstone then
    return true
  end
  if record.payload == nil or not isPlainData(record.payload) then
    return false
  end
  -- The payload is untrusted: a `validate` that raises on it counts as a refusal
  local called, valid = pcall(definition.validate, record.key, record.payload)
  if not called or not valid then
    return false
  end
  return store.recordSize(record) <= definition.maxRecordBytes
end

---Merges records that another replica sent into a table, in their order, and fires "OnRecordChanged" for
---every record that changed. Each record is checked: the time of its id, and its payload against the table
---definition and its size limit. A bad record is dropped with the later records of its origin (`syncStore.applyBatch`).
---@param tableName string
---@param records OOOOSyncWireRecord[] From `syncProtocol`: keys and ids have the right form
---@param checkFn (fun(record: OOOOSyncWireRecord, definition: OOOOSyncTableDefinition): boolean|"seen")? A
---further check of the caller, after the checks above; "seen" raises the clock without storing the record
---@param sender string? The character that sent the records in a push: in a table with `writers = "self"`, a
---changed record whose key names it is first hand (`firstHand` of "OnRecordChanged"). nil for a pull.
---@return string[] changed Keys whose stored record changed
---@return integer dropped Number of records that were not applied
function sync:ApplyRemote(tableName, records, checkFn, sender)
  local tbl, definition = self:GetTable(tableName)
  if not tbl or not definition then
    return {}, #records
  end
  local now = self.timeFn()
  local changed, dropped = store.applyBatch(tbl, records, function(record)
    if not isGoodRemote(definition, record, now) then
      return false
    end
    if checkFn then
      return checkFn(record, definition)
    end
    return true
  end)
  local bySelf = sender ~= nil and definition.writers == "self"
  for _, key in ipairs(changed) do
    local record = tbl.records[key]
    self.callbacks:Fire("OnRecordChanged", tableName, key, (not record.x) and record.d or nil, true,
      bySelf and sync.keyName(key) == sender)
  end
  return changed, dropped
end

---Stores records that another replica sent to fill holes: writes that the clock of the table covers and
---that the table does not hold (plan section 4.5). Each record is checked like one of `ApplyRemote`, and it
---must lie in the time range that was asked for. The clock and the table version never change here: a record
---above the clock is skipped, because the pull is what brings it (`syncStore.fill`). A record that is not
---taken stops nothing: every record stands for itself. "OnRecordChanged" fires for every stored record, as
---for a pull.
---@param tableName string
---@param records OOOOSyncWireRecord[] From `syncProtocol`: keys and ids have the right form
---@param from integer Server time, the start of the range that was asked for
---@param to integer Server time, the end of the range
---@param checkFn (fun(record: OOOOSyncWireRecord, definition: OOOOSyncTableDefinition): boolean|"seen")? A
---further check of the caller; only a record for which it gives true is stored
---@return string[] filled Keys whose record was stored
---@return integer skipped Number of records that were not stored
function sync:FillRemote(tableName, records, from, to, checkFn)
  local tbl, definition = self:GetTable(tableName)
  if not tbl or not definition then
    return {}, #records
  end
  local now = self.timeFn()
  local low, high = versionId.timePrefix(from), versionId.timePrefix(to)
  local filled, skipped = {}, 0
  for _, record in ipairs(records) do
    local id = record.id
    local good = versionId.isWellFormed(id) and id >= low and id < high and type(record.key) == "string"
      and isGoodRemote(definition, record, now) and (not checkFn or checkFn(record, definition) == true)
    if good and store.fill(tbl, record.key, id, record.payload, record.tombstone == true) then
      filled[#filled + 1] = record.key
    else
      skipped = skipped + 1
    end
  end
  for _, key in ipairs(filled) do
    local record = tbl.records[key]
    self.callbacks:Fire("OnRecordChanged", tableName, key, (not record.x) and record.d or nil, true)
  end
  return filled, skipped
end

--------------------------------------------------------------------------------
-- Local cleanup (plan section 4.4): it sends nothing and leaves the clock, and so the table version, alone
--------------------------------------------------------------------------------

---Records that one step of `Sweep` looks at; the next step runs in a later frame
sync.SWEEP_CHUNK = 500

---Removes the stored records of a table for which `shouldRemove` gives true, without a change to the
---clock, `maxId`, or `fp`. With `after`, the work is cut into steps of `SWEEP_CHUNK` records, one per frame;
---a record that changes between two steps is judged as it is when its step runs. "OnRecordChanged" fires
---for every removed record that was not a tombstone.
---@param tableName string
---@param shouldRemove fun(key: string, record: OOOOSyncRecord): boolean
---@param after (fun(seconds: number, fn: fun()): any)? Calls `fn` once, later; without it all is done at once
---@param onDone (fun(removed: integer))? Called after the last step
function sync:Sweep(tableName, shouldRemove, after, onDone)
  local tbl = self:GetTable(tableName)
  -- The keys are listed first: a walk over the records themselves cannot go on in a later frame
  local keys = {}
  for key in pairs(tbl and tbl.records or {}) do
    keys[#keys + 1] = key
  end
  local position, removed = 1, 0
  local function step()
    local last = after and math.min(#keys, position + sync.SWEEP_CHUNK - 1) or #keys
    for index = position, last do
      local key = keys[index]
      local record = tbl.records[key]
      if record and shouldRemove(key, record) then
        tbl.records[key] = nil
        removed = removed + 1
        if not record.x then
          self.callbacks:Fire("OnRecordChanged", tableName, key, nil, true)
        end
      end
    end
    position = last + 1
    if position <= #keys and after then
      after(0, step)
    elseif onDone then
      onDone(removed)
    end
  end
  step()
end

---Removes the tombstones of a table that are older than `syncStore.TOMBSTONE_SECONDS`. Every replica does
---this by itself. A replica that was away for longer empties the table before it pulls (`Reset`), so it
---cannot bring back a record whose tombstone is gone.
---@param tableName string
---@param after (fun(seconds: number, fn: fun()): any)? As in `Sweep`
---@param onDone (fun(removed: integer))?
function sync:RemoveOldTombstones(tableName, after, onDone)
  if not self.timeFn then
    if onDone then
      onDone(0)
    end
    return
  end
  local limit = versionId.timePrefix(self.timeFn() - store.TOMBSTONE_SECONDS)
  self:Sweep(tableName, function(_key, record)
    return record.x == true and record.v < limit
  end, after, onDone)
end

---Tells whether a write is older than its table keeps records (`maxAge` of the definition). The age is that
---of the id, so every replica gives the same answer for a record, whenever it has received it.
---@param definition OOOOSyncTableDefinition
---@param id string A well-formed version id
---@return boolean expired false for a table without `maxAge`
function sync:IsExpired(definition, id)
  if not definition.maxAge or not self.timeFn then
    return false
  end
  return id < versionId.timePrefix(self.timeFn() - definition.maxAge)
end

---Removes the records of a table that are older than its `maxAge`, tombstones too, without a change to the
---clock, `maxId`, or `fp`: two replicas with equal versions can then hold different numbers of old records,
---which is intended (plan section 4.4). A table without `maxAge` is left alone.
---@param tableName string
---@param after (fun(seconds: number, fn: fun()): any)? As in `Sweep`
---@param onDone (fun(removed: integer))?
function sync:Expire(tableName, after, onDone)
  local _, definition = self:GetTable(tableName)
  if not definition or not definition.maxAge or not self.timeFn then
    if onDone then
      onDone(0)
    end
    return
  end
  local limit = versionId.timePrefix(self.timeFn() - definition.maxAge)
  self:Sweep(tableName, function(_key, record)
    return record.v < limit
  end, after, onDone)
end

---Empties a table and its clock, and fires "OnRecordChanged" for every record that was not a tombstone.
---The session calls it for a table that was out of contact for too long, before it pulls the table again.
---@param tableName string
---@return boolean emptied false when the table cannot be used
function sync:Reset(tableName)
  local tbl = self:GetTable(tableName)
  if not tbl then
    return false
  end
  local records = tbl.records
  store.reset(tbl, self.timeFn())
  self.dirtySince[tableName] = nil
  for key, record in pairs(records) do
    if not record.x then
      self.callbacks:Fire("OnRecordChanged", tableName, key, nil, true)
    end
  end
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

---Estimates the size of a table on the wire: the sum of `syncStore.recordSize` over its records, the
---tombstones too. It is one pass over the table, for the status output.
---@param tableName string
---@return integer bytes 0 when the table cannot be used
function sync:Size(tableName)
  local tbl = self:GetTable(tableName)
  local bytes = 0
  for key, record in pairs(tbl and tbl.records or {}) do
    bytes = bytes + store.recordSize({ key = key, payload = record.d })
  end
  return bytes
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
