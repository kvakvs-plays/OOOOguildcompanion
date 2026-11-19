local addonName, ns = ...

-- The built-in table `addon`: which addon version each character runs, and when its addon was last seen.
-- Each character writes its own record after the guild check and again every `HEARTBEAT` seconds while it is
-- online, so a record that stays old while its member is online tells of an addon that was removed or that
-- has lost the connection. The addon is installed per player, so a reader takes the newest record among a
-- character and its alts (`playerRecord`); the records stay per character, which keeps the owner rule and
-- the roster cleanup of the engine. `/oooo versioncheck` prints the versions of the online members, or of the guild
-- members in the own party or raid.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_inventory.lua).

---@class OOOOAddonPayload Payload of a record in the table `addon`; the key is the character name
---@field v string Addon version: "2026.11.6"
---@field t integer Server time in seconds at which the addon of the character wrote the record

---@class OOOOAddonRow One member in the answer of `inventory.rows`
---@field name string Character name
---@field version string|nil Addon version; nil when the member has no record
---@field seen integer|nil Server time of the record; nil when the member has no record
---@field via string|nil Name of the alt whose record gave the version; nil when it is the own record
---@field stale boolean true when the record is old and the addon of the member does not talk in this session
---@field talks boolean true when the addon of the member has sent a message in this session

---@class OOOOAddonInventoryParts What `inventory.rows` reads from
---@field sync OOOOSync
---@field now integer Server time in seconds
---@field isPeer (fun(name: string): boolean)|nil Tells whether the addon of a member has sent a message in
---this session
---@field alts (fun(name: string): string[])|nil Gives the other characters of the player of a character
---@field playerName string|nil Name of the logged-in character
---@field version string|nil Version of this addon, shown for the logged-in character

---@class OOOOAddonInventory
---@field timer OOOOSyncTimer|nil Runs until the next write of the own record
local inventory = {}
ns.addonInventory = inventory

---Name of the table
inventory.TABLE = "addon"
---Seconds between two writes of the own record while the character is online
inventory.HEARTBEAT = 3600
---Seconds after which the record of an online member counts as old: two missed writes and the time that a
---push can wait
inventory.STALE_SECONDS = 2 * inventory.HEARTBEAT + 900
---Seconds in which the own record is not written again with the same version: a `/reload` sends nothing
inventory.MIN_REWRITE = 600

local MAX_VERSION_LENGTH = 20
---The form `<year>.<month>.<build>` of `VERSION` in scripts/release_tool.py
local VERSION_PATTERN = "^%d+%.%d+%.%d+$"
---Largest time that a record can carry; it keeps the number an integer that every serializer writes exactly
local MAX_TIME = 2 ^ 40

---Checks a payload of the table `addon`: the types and ranges of its fields, and no other fields.
---@param _key string
---@param payload any
---@return boolean
function inventory.validate(_key, payload)
  if type(payload) ~= "table" then
    return false
  end
  local version, time = payload.v, payload.t
  if type(version) ~= "string" or #version > MAX_VERSION_LENGTH or not version:find(VERSION_PATTERN) then
    return false
  end
  if type(time) ~= "number" or time < 0 or time > MAX_TIME or time ~= math.floor(time) then
    return false
  end
  for field in pairs(payload) do
    if field ~= "v" and field ~= "t" then
      return false
    end
  end
  return true
end

ns.sync:RegisterTable({
  name = inventory.TABLE,
  schema = 1,
  keyKind = "character",
  validate = inventory.validate,
  -- A record with the longest key is about 110 bytes
  maxRecordBytes = 200,
  writers = "owner",
  policy = { when = "nocombat", pushDelay = 60, minInterval = 600 },
})

---Tells whether the own record must be written: there is none, it has another version, or it is older than
---`MIN_REWRITE`.
---@param previous any The stored payload of the character
---@param version string Version of this addon
---@param now integer Server time
---@return boolean
function inventory.needsWrite(previous, version, now)
  if type(previous) ~= "table" or previous.v ~= version or type(previous.t) ~= "number" then
    return true
  end
  -- A time in the future is from a wrong clock and is replaced
  return previous.t > now or now - previous.t >= inventory.MIN_REWRITE
end

---Finds the newest record of the player of a character. The addon is installed per player, so the record
---of an alt tells the version as well as the own one; the newest is from the install that ran last.
---@param parts OOOOAddonInventoryParts
---@param name string Character name
---@return OOOOAddonPayload|nil payload nil when neither the character nor an alt has a record
---@return string|nil via Name of the alt that the record belongs to; nil for the record of the character
function inventory.playerRecord(parts, name)
  local best, via = parts.sync:Get(inventory.TABLE, name), nil
  for _, alt in ipairs(parts.alts and parts.alts(name) or {}) do
    local payload = parts.sync:Get(inventory.TABLE, alt)
    if payload and (not best or payload.t > best.t) then
      best, via = payload, alt
    end
  end
  return best, via
end

---Lists members with what the table `addon` knows of their players, sorted by name. The logged-in character
---is listed with the version of this addon, whatever its record says.
---@param parts OOOOAddonInventoryParts
---@param names string[] Character names; a repeated name is listed once
---@return OOOOAddonRow[]
function inventory.rows(parts, names)
  local rows, listed = {}, {}
  for _, name in ipairs(names) do
    if not listed[name] then
      listed[name] = true
      local talks = parts.isPeer ~= nil and parts.isPeer(name) == true
      local row = { name = name, stale = false, talks = talks }
      if name == parts.playerName and parts.version then
        row.version, row.seen, row.talks = parts.version, parts.now, true
      else
        local payload, via = inventory.playerRecord(parts, name)
        if payload then
          row.version, row.seen, row.via = payload.v, payload.t, via
          row.stale = not talks and parts.now - payload.t > inventory.STALE_SECONDS
        end
      end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

---Builds the text of one member for `/oooo versioncheck`.
---@param row OOOOAddonRow
---@param now integer Server time
---@return string
function inventory.rowText(row, now)
  if row.version then
    local text = row.name .. ": " .. row.version
    if row.stale then
      text = text .. ", last seen " .. ns.syncOptions.ago(now - row.seen)
    end
    return text .. (row.via and (" (as " .. row.via .. ")") or "")
  elseif row.talks then
    -- The addon answers, but it has no table `addon`
    return row.name .. ": an older version, which does not tell its number"
  end
  return row.name .. ": no addon seen"
end

---Builds the lines of `/oooo versioncheck`.
---@param rows OOOOAddonRow[]
---@param now integer Server time
---@param inGroup boolean true when the rows are the guild members of the own party or raid
---@param version string|nil Version of this addon
---@return string[] lines Plain text
function inventory.lines(rows, now, inGroup, version)
  local lines = { "Addon versions of the " .. #rows .. " "
    .. (inGroup and "guild members in your group" or "online guild members")
    .. (version and (" (yours: " .. version .. ")") or "") .. ":" }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = "  " .. inventory.rowText(row, now)
  end
  return lines
end

--------------------------------------------------------------------------------
-- The game
--------------------------------------------------------------------------------

---Writes the record of the logged-in character with the version of this addon and the server time.
---@return boolean|nil written As `ns.sync:Put`; false also when the record is recent enough
---@return string|nil reason
function inventory.WriteOwn()
  local name = ns.syncCharacter.playerName()
  if not ns.version or not name or not ns.sync.timeFn then
    return nil, "not ready"
  end
  local now = ns.sync.timeFn()
  if not inventory.needsWrite(ns.sync:Get(inventory.TABLE, name), ns.version, now) then
    return false
  end
  return ns.sync:Put(inventory.TABLE, name, { v = ns.version, t = now })
end

---Writes the own record and starts the timer of the next write.
local function beat()
  inventory.WriteOwn()
  inventory.timer = C_Timer.NewTimer(inventory.HEARTBEAT, beat)
end

ns.guildState.RegisterCallback(inventory, "OnGuildStateChanged", function(_event, inGuild)
  if inventory.timer then
    inventory.timer:Cancel()
    inventory.timer = nil
  end
  -- A character outside the guild writes nothing; with saved data of a newer addon the database is off
  if inGuild and not ns.dbIsNewer then
    beat()
  end
end)

---Reads the name of a unit as the roster gives it: the first and the last name with a space.
---@param unit string Unit token
---@return string|nil name nil when there is no such unit or its name is hidden
---@return boolean hidden true when the name is a secret value
local function unitName(unit)
  local first, last = UnitName(unit)
  if issecretvalue(first) or issecretvalue(last) then
    return nil, true
  end
  if type(first) ~= "string" or first == "" then
    return nil, false
  end
  if type(last) == "string" and last ~= "" then
    return first .. " " .. last, false
  end
  return first, false
end

---Lists the characters of the own party or raid, the own one too.
---@return string[]|nil names nil when the character is in no group
---@return integer hidden Number of members whose name is a secret value
function inventory.groupNames()
  local inRaid = IsInRaid()
  local prefix, size = "party", 4
  if not issecretvalue(inRaid) and inRaid == true then
    prefix, size = "raid", 40
  end
  local names, hidden = {}, 0
  for index = 1, size do
    local name, isHidden = unitName(prefix .. index)
    if name then
      names[#names + 1] = name
    elseif isHidden then
      hidden = hidden + 1
    end
  end
  if #names == 0 and hidden == 0 then
    return nil, 0
  end
  -- The raid units include the own character, the party units do not; `rows` lists a name once
  names[#names + 1] = ns.syncCharacter.playerName()
  return names, hidden
end

---Prints the addon versions for `/oooo versioncheck`: of the guild members in the own party or raid, or
---without a group of all online guild members.
function inventory.PrintVersions()
  local guild = ns.guildState
  if not guild:IsInGuild() then
    ns.print("The version check works only in the guild " .. guild.GUILD_NAME .. ".")
    return
  end
  if not ns.sync.timeFn then
    ns.print("The shared database is not ready.")
    return
  end
  local names, outside = {}, 0
  local group, hidden = inventory.groupNames()
  if group then
    for _, name in ipairs(group) do
      if guild:GetMember(name) then
        names[#names + 1] = name
      else
        outside = outside + 1
      end
    end
  else
    for name, member in pairs(guild.roster) do
      if member.online then
        names[#names + 1] = name
      end
    end
  end
  local session = ns.syncSession.current
  local now = ns.sync.timeFn()
  local rows = inventory.rows({
    sync = ns.sync,
    now = now,
    isPeer = function(name)
      return session ~= nil and session.peers[name] ~= nil
    end,
    alts = function(name)
      return ns.sync:GetAlts(name)
    end,
    playerName = ns.syncCharacter.playerName(),
    version = ns.version,
  }, names)
  for _, line in ipairs(inventory.lines(rows, now, group ~= nil, ns.version)) do
    ns.print(line)
  end
  if outside > 0 then
    ns.print("  Not in the guild and not listed: " .. outside)
  end
  if hidden > 0 then
    ns.print("  Names that the game hides now: " .. hidden)
  end
end

ns.slash:Register("versioncheck", "versioncheck - addon versions of your group, or of the online members",
  inventory.PrintVersions)
