local addonName, ns = ...

-- The built-in table `character` and alt detection (.agents/00-plan.md, section 5.1).
-- Each character writes its own record at login. The origin in a record's id names the player, so
-- characters whose records come from the same origin are alts of one player.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_alts.lua).

---@class OOOOCharacterPayload Payload of a record in the table `character`; the key is the character name
---@field class string Class token in upper case, as UnitClass returns it: "SHAMAN"
---@field level integer 1 to 60
---@field origins string[] Origins that have written this character, sorted. One player with two installs
---has two origins; the list is what joins them, because the record's id keeps only the last writer.

---@class OOOOSyncCharacter
local character = {}
ns.syncCharacter = character

local versionId = ns.versionId

---Name of the table
character.TABLE = "character"
local MAX_LEVEL = 60
local MAX_CLASS_LENGTH = 20
---Most origins that one record lists; more than a player has installs
local MAX_ORIGINS = 8

---Tells whether a value is an origin: 4 base-94 characters.
---@param value any
---@return boolean
local function isOrigin(value)
  return type(value) == "string" and #value == 4 and ns.base94.isValid(value)
end

---Checks a payload of the table `character`: the types and ranges of its fields, and no other fields.
---@param _key string
---@param payload any
---@return boolean
function character.validate(_key, payload)
  if type(payload) ~= "table" then
    return false
  end
  local class, level, origins = payload.class, payload.level, payload.origins
  if type(class) ~= "string" or #class > MAX_CLASS_LENGTH or not class:find("^%u+$") then
    return false
  end
  if type(level) ~= "number" or level < 1 or level > MAX_LEVEL or level ~= math.floor(level) then
    return false
  end
  if type(origins) ~= "table" or #origins < 1 or #origins > MAX_ORIGINS then
    return false
  end
  local count = 0
  for _ in pairs(origins) do
    count = count + 1
  end
  if count ~= #origins then
    return false
  end
  for index = 1, #origins do
    if not isOrigin(origins[index]) or (index > 1 and origins[index - 1] >= origins[index]) then
      return false
    end
  end
  for field in pairs(payload) do
    if field ~= "class" and field ~= "level" and field ~= "origins" then
      return false
    end
  end
  return true
end

ns.sync:RegisterTable({
  name = character.TABLE,
  schema = 1,
  keyKind = "character",
  validate = character.validate,
  -- A record with the longest key and 8 origins is about 220 bytes
  maxRecordBytes = 300,
  writers = "owner",
  policy = { when = "nocombat", pushDelay = 60, minInterval = 600 },
})

---Builds the payload of a character: its class and level, and the origins of the previous record joined
---with the origin of this install.
---@param class string Class token
---@param level integer
---@param origin string Origin of this install
---@param previous OOOOCharacterPayload|nil The stored payload of the character
---@return OOOOCharacterPayload
function character.buildPayload(class, level, origin, previous)
  local seen, origins = { [origin] = true }, { origin }
  for _, other in ipairs(previous and type(previous.origins) == "table" and previous.origins or {}) do
    -- Own origin first, so that it stays when the list is full
    if isOrigin(other) and not seen[other] and #origins < MAX_ORIGINS then
      seen[other] = true
      origins[#origins + 1] = other
    end
  end
  table.sort(origins)
  return { class = class, level = level, origins = origins }
end

---Lists the origins of one record: the writer of the record and the origins in its payload.
---@param record OOOOSyncRecord
---@return table<string, boolean> origins Set of origins
local function originsOf(record)
  local origins = { [versionId.originOf(record.v)] = true }
  local listed = type(record.d) == "table" and record.d.origins
  if type(listed) == "table" then
    for _, origin in ipairs(listed) do
      if isOrigin(origin) then
        origins[origin] = true
      end
    end
  end
  return origins
end

---Lists the origins of a character in a stored `character` table: the writer of its record and the origins in
---its payload. The teams feature takes them as the account ids of the character (Teams/Teams.lua).
---@param tbl OOOOSyncTable
---@param name string Character name
---@return string[] origins Sorted; empty for a character without a record
function character.origins(tbl, name)
  local record = tbl.records[name]
  local list = {}
  if record and not record.x then
    for origin in pairs(originsOf(record)) do
      list[#list + 1] = origin
    end
    table.sort(list)
  end
  return list
end

---Finds the alts of a character in a stored `character` table: the characters that share an origin with
---it, directly or through other characters. A deleted character has no alts and is nobody's alt.
---@param tbl OOOOSyncTable
---@param name string Character name
---@return string[] alts Names of the other characters of the same player, sorted; empty when unknown
function character.alts(tbl, name)
  ---Origin -> names of the characters with that origin
  local byOrigin = {}
  ---Name -> set of origins
  local originsByName = {}
  for key, record in pairs(tbl.records) do
    if not record.x then
      local origins = originsOf(record)
      originsByName[key] = origins
      for origin in pairs(origins) do
        byOrigin[origin] = byOrigin[origin] or {}
        byOrigin[origin][#byOrigin[origin] + 1] = key
      end
    end
  end
  if not originsByName[name] then
    return {}
  end
  -- Walk from the character over shared origins until no new character appears
  local found, queue, alts = { [name] = true }, { name }, {}
  local position = 1
  while position <= #queue do
    for origin in pairs(originsByName[queue[position]]) do
      for _, other in ipairs(byOrigin[origin]) do
        if not found[other] then
          found[other] = true
          queue[#queue + 1] = other
          alts[#alts + 1] = other
        end
      end
    end
    position = position + 1
  end
  table.sort(alts)
  return alts
end

---Returns the other characters of the player who owns `name`, from the table `character`.
---@param name string Character name, as the roster shows it
---@return string[] alts Sorted; empty when the character is unknown or the database is not ready
function ns.sync:GetAlts(name)
  local tbl = self:GetTable(character.TABLE)
  return tbl and character.alts(tbl, name) or {}
end

---Tells whether two characters have records in a stored `character` table that share an origin: the
---writer of the record or an origin in its payload. Unlike `alts` it follows no chain over a third character.
---@param tbl OOOOSyncTable
---@param name string Character name
---@param other string Character name
---@return boolean
function character.shareOrigin(tbl, name, other)
  local first, second = tbl.records[name], tbl.records[other]
  if not first or first.x or not second or second.x then
    return false
  end
  local origins = originsOf(second)
  for origin in pairs(originsOf(first)) do
    if origins[origin] then
      return true
    end
  end
  return false
end

---Tells whether the table `character` lists `name` under an origin of the record of `other`. The owner
---rule of `ns.sync:MayWrite` asks this for the keys of a received push.
---@param name string Character name
---@param other string Character name
---@return boolean
function ns.sync:IsAltOf(name, other)
  local tbl = self:GetTable(character.TABLE)
  return tbl ~= nil and character.shareOrigin(tbl, name, other)
end

---Tells whether an origin has written a character, by a stored `character` table: it is the writer of the
---character's record or listed in its payload. It makes no table, so it can be asked for many records.
---@param tbl OOOOSyncTable
---@param name string Character name
---@param origin string
---@return boolean
function character.hasOrigin(tbl, name, origin)
  local record = tbl.records[name]
  if not record or record.x then
    return false
  end
  if versionId.originOf(record.v) == origin then
    return true
  end
  local listed = type(record.d) == "table" and record.d.origins
  if type(listed) == "table" then
    for _, other in ipairs(listed) do
      if other == origin then
        return true
      end
    end
  end
  return false
end

---Tells whether an origin belongs to the player of a character, from the table `character`. A reader of the
---table `guildchat` asks this to tell a line that the sender's addon wrote from one of a witness.
---@param name string Character name
---@param origin string
---@return boolean
function ns.sync:IsOriginOf(name, origin)
  local tbl = self:GetTable(character.TABLE)
  return tbl ~= nil and character.hasOrigin(tbl, name, origin)
end

---Name of the logged-in character as the roster and message senders give it; nil when it is hidden.
---`UnitName("player")` returns the first and the last name as two values on Forever.
---@return string|nil
function character.playerName()
  local first, last = UnitName("player")
  if issecretvalue(first) or issecretvalue(last) or type(first) ~= "string" then
    return nil
  end
  if type(last) == "string" and last ~= "" then
    return first .. " " .. last
  end
  return first
end

---true once the record of this character was written or found current in this session
local writtenThisSession = false

---Writes the record of the logged-in character when its payload has changed. It runs once per session,
---when the guild check has passed: a character outside the guild writes nothing.
---@return boolean|nil written As `ns.sync:Put`; nil when the character data is not readable
---@return string|nil reason
function character.WriteOwn()
  if writtenThisSession then
    return false
  end
  local name = character.playerName()
  local _, class = UnitClass("player")
  local level = UnitLevel("player")
  if not name or issecretvalue(class) or issecretvalue(level) then
    return nil, "character data is not readable"
  end
  local origin = ns.sync:GetOrigin()
  if not origin then
    return nil, "not ready"
  end
  local written, reason = ns.sync:Put(character.TABLE, name,
    character.buildPayload(class, level, origin, ns.sync:Get(character.TABLE, name)))
  writtenThisSession = written ~= nil
  return written, reason
end

ns.guildState.RegisterCallback(character, "OnGuildStateChanged", function(_event, inGuild)
  if inGuild then
    character.WriteOwn()
  end
end)
