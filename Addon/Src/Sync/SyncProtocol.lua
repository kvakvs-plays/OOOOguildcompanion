local addonName, ns = ...

-- The messages of the shared database: how they are written, read, and checked
-- (.agents/00-plan.md, sections 6 and 8).
--
-- A message from another member is untrusted input. `decode` hands out only fields that it has checked, in
-- new tables, and it never raises. Received text goes to the serializer and nowhere else: it is never run.
--
-- This file uses no WoW API. The serializer is passed in, so the host tests run it with a stub
-- (Tests/sync_protocol.lua).

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

---Message type -> the channel on which it travels. A type that arrives on the other channel is dropped.
---@type table<string, "GUILD"|"WHISPER">
protocol.CHANNELS = {
  H = "GUILD", -- hello: sent once after login, asks peers to answer
  S = "GUILD", -- summary: answer to a hello, and notice after a merge
}

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
