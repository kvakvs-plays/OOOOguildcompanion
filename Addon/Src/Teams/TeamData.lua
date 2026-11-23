local addonName, ns = ...

-- The tables of the teams feature (.agents/user-wishes.md, "Teams"): a character-team is the set of characters
-- of one person, with an alias that chat shows beside the character name.
--
-- - `team`, written by officers, holds three kinds of records:
--   `t:<team id>` the team itself (its aliases), `c:<character name>` the team of a character, and
--   `o:<account id>` the team of an account id. One record per character and per account id means that a
--   character and an account id belong to one team at most, whatever two officers write at the same time.
-- - `team_alias`, written by each character under its own name, holds the alias that the player asks for.
--   An officer's addon copies it into the team record (TeamClerk.lua); members read only the table `team`.
--
-- The account id is the origin of an install (Sync/VersionId.lua): random, one per account, and listed per
-- character in the table `character`.
--
-- This file uses no WoW API, so the host tests load it (Tests/sync_teams.lua).

---@class OOOOTeam Payload of the key `t:<team id>`
---@field a string Alias that an officer gave the team
---@field p string|nil Alias that a player of the team asked for
---@field pv string|nil Version id of the request that `p` was copied from
---@field f true|nil true: the player's alias is denied, and the alias of the officer is shown

---@class OOOOTeamLink Payload of the keys `c:<character name>` and `o:<account id>`
---@field t string Team id

---@class OOOOTeamAliasRequest Payload of a record of the table `team_alias`; the key is the character name
---@field a string The alias that the player asks for

---@class OOOOTeamKey The parts of a parsed key of the table `team`
---@field kind string "team", "character", or "account"
---@field id string|nil Team id; in the kind "team"
---@field name string|nil Character name; in the kind "character"
---@field origin string|nil Account id; in the kind "account"

---@class OOOOTeamData
local data = {}
ns.teamData = data

local base94 = ns.base94
local versionId = ns.versionId

---Name of the table of the teams
data.TABLE = "team"
---Name of the table of the alias requests
data.REQUEST_TABLE = "team_alias"
---Longest alias, in bytes
data.MAX_ALIAS = 24
---Longest character name, in bytes; with it every key fits the 64 bytes of the engine
data.MAX_NAME = 48
---Length of an account id: an origin
data.ORIGIN_LENGTH = 4

---Tells whether a value is an alias: 1 to `MAX_ALIAS` bytes, no `|` (it starts an escape sequence of the
---client), no control character, and no space at either end.
---@param value any
---@return boolean
function data.isAlias(value)
  return type(value) == "string" and #value >= 1 and #value <= data.MAX_ALIAS
    and not value:find("[|%c]") and not value:find("^%s") and not value:find("%s$")
end

---Makes an alias of what a user typed: the spaces at both ends are cut off.
---@param text any
---@return string|nil alias nil when the text cannot be an alias
---@return string|nil reason "empty", "too long", or "bad character"
function data.cleanAlias(text)
  if type(text) ~= "string" then
    return nil, "empty"
  end
  local alias = text:match("^%s*(.-)%s*$")
  if alias == "" then
    return nil, "empty"
  elseif #alias > data.MAX_ALIAS then
    return nil, "too long"
  elseif not data.isAlias(alias) then
    return nil, "bad character"
  end
  return alias
end

---Tells whether a value can be a character name: 1 to `MAX_NAME` bytes, no `:` and no `|`.
---@param value any
---@return boolean
function data.isName(value)
  return type(value) == "string" and #value >= 1 and #value <= data.MAX_NAME and not value:find("[:|]")
end

---Tells whether a value is an account id: 4 base-94 characters.
---@param value any
---@return boolean
function data.isOrigin(value)
  return type(value) == "string" and #value == data.ORIGIN_LENGTH and base94.isValid(value)
end

---Builds the key of a team.
---@param id string Team id: a version id
---@return string
function data.teamKey(id)
  return "t:" .. id
end

---Builds the key of the team of a character.
---@param name string Character name
---@return string
function data.characterKey(name)
  return "c:" .. name
end

---Builds the key of the team of an account id.
---@param origin string
---@return string
function data.accountKey(origin)
  return "o:" .. origin
end

---Reads a key of the table `team`. The rest after the two characters of the kind is taken whole, because a
---team id and an account id can contain `:`.
---@param key any
---@return OOOOTeamKey|nil parts nil for a key of another form
function data.parseKey(key)
  if type(key) ~= "string" then
    return nil
  end
  local prefix, rest = key:sub(1, 2), key:sub(3)
  if prefix == "t:" then
    return versionId.isWellFormed(rest) and { kind = "team", id = rest } or nil
  elseif prefix == "c:" then
    return data.isName(rest) and { kind = "character", name = rest } or nil
  elseif prefix == "o:" then
    return data.isOrigin(rest) and { kind = "account", origin = rest } or nil
  end
  return nil
end

---Tells whether every field of a table is in a list of names.
---@param payload table
---@param allowed table<string, boolean>
---@return boolean
local function onlyFields(payload, allowed)
  for field in pairs(payload) do
    if not allowed[field] then
      return false
    end
  end
  return true
end

local TEAM_FIELDS = { a = true, p = true, pv = true, f = true }
local LINK_FIELDS = { t = true }

---Checks the payload of a team.
---@param team any
---@return boolean
local function isTeam(team)
  if type(team) ~= "table" or not onlyFields(team, TEAM_FIELDS) or not data.isAlias(team.a) then
    return false
  end
  -- The alias of the player and the id of its request come together or not at all
  if (team.p == nil) ~= (team.pv == nil) then
    return false
  end
  if team.p ~= nil and (not data.isAlias(team.p) or not versionId.isWellFormed(team.pv)) then
    return false
  end
  return team.f == nil or team.f == true
end

---Checks a record of the table `team`: the form of the key, and the types and ranges of the payload of its
---kind. Never raises, whatever the input.
---@param key any
---@param payload any
---@return boolean
function data.validateTeam(key, payload)
  local parts = data.parseKey(key)
  if not parts then
    return false
  elseif parts.kind == "team" then
    return isTeam(payload)
  end
  return type(payload) == "table" and onlyFields(payload, LINK_FIELDS) and versionId.isWellFormed(payload.t)
end

---Checks a record of the table `team_alias`. Never raises, whatever the input.
---@param key any
---@param payload any
---@return boolean
function data.validateRequest(key, payload)
  return data.isName(key) and type(payload) == "table" and onlyFields(payload, { a = true })
    and data.isAlias(payload.a)
end

ns.sync:RegisterTable({
  name = data.TABLE,
  schema = 1,
  -- No roster cleanup: an officer decides when a character leaves its team
  keyKind = "free",
  validate = data.validateTeam,
  maxRecordBytes = 300,
  writers = "officer",
  policy = { when = "nocombat", pushDelay = 5, minInterval = 30 },
})

ns.sync:RegisterTable({
  name = data.REQUEST_TABLE,
  schema = 1,
  -- The key is the character name, so the owner rule and the roster cleanup apply
  keyKind = "character",
  validate = data.validateRequest,
  maxRecordBytes = 200,
  writers = "self",
  policy = { when = "nocombat", pushDelay = 5, minInterval = 30 },
})
