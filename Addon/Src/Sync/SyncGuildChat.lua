local addonName, ns = ...

-- The table `guildchat` of the shared database (.agents/00-plan.md, section 5.3): a copy of the guild chat
-- of the last 14 days, for the member who was offline. One chat line is one record that is written once,
-- under its own version id as key, by the addon of the member who wrote the line, or by one witness when
-- that member has no addon. It is not real time: the lines travel with the push and the pull of the engine.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_guildchat.lua).

---@class OOOOGuildChatPayload Payload of a record in the table `guildchat`; the key is the record's own id
---@field s string Character name of the sender, as the roster shows it
---@field t string Text as the chat event gave it, with item links and other escape sequences

---@class OOOOGuildChatLine One line of the stored guild chat, as `Lines` gives it
---@field id string Key and version id of the record; of the earliest one when several records were joined
---@field time integer Server time of the line: the timestamp of `id`
---@field sender string
---@field text string The original text: untrusted, escape it before it is shown
---@field bySender boolean true when a record of the line was written by the sender's own addon: its origin
---belongs to the sender in the table `character`. false for a line that only a witness wrote; any member
---with a modified addon can write such a line under any sender name.

---@class OOOOGuildChat
---@field playerName (fun(): string|nil)|nil Gives the name of the logged-in character; set by a host test,
---in the game `ns.syncCharacter.playerName` is used
---@field session OOOOSyncSession|nil The session that knows the peers; set by a host test, in the game
---`ns.syncSession.current` is used
---@field keys string[]|nil The keys of the chat lines, sorted; nil until `Lines` builds it, and again after
---a record was removed
---@field frame table|nil The event frame; nil until the character is in the guild
---@field listening boolean|nil true while the frame listens to the guild chat
---@field eventMissing boolean|nil true when the client does not know the chat event
---@field counts OOOOGuildChatCounts What the capture has seen in this session, for `/oooo sync chat`
---@field lastSender string|nil The sender name of the last line that was heard, as the event gave it
---@field warnedAt integer|nil Server time of the last warning about a mention that nobody can copy
local guildChat = {}
ns.guildChat = guildChat

local versionId = ns.versionId

---@class OOOOGuildChatCounts Numbers of chat lines in this session
---@field heard integer Lines that the event gave
---@field secret integer Lines whose sender or text was secret; they are not recorded
---@field written integer Lines that this replica stored: own ones and those that it wrote as witness
guildChat.counts = { heard = 0, secret = 0, written = 0 }

---Name of the table
guildChat.TABLE = "guildchat"
---Days for which every replica keeps the lines. The same for everybody; it is not a setting, because a
---pull request has no lower limit and counts on equal lengths (plan section 5.3).
guildChat.KEEP_DAYS = 14
---Hours for which the replicas compare their lines per hour and fill the holes (plan section 4.5)
guildChat.GAP_CHECK_HOURS = 48
---Seconds within which two records with the same sender and text count as one line. It is wide because an
---id can be minutes ahead of the real time (plan section 3).
guildChat.DUPLICATE_WINDOW = 180
---Seconds in which the warning about a mention that nobody can copy is printed at most once
guildChat.WARNING_INTERVAL = 300
---The warning for the writer of a mention while no other replica is online (plan step 11.5)
guildChat.UNSHARED_WARNING = "No other player with the addon is online. Your @mention is not shared until one "
  .. "comes online."
---Longest sender name in bytes: a first and a last name of 12 UTF-8 letters each fit
local MAX_SENDER = 48
---Longest text in bytes: the limit of a chat message
local MAX_TEXT = 255
---Lines that `/oooo sync chat` prints without a count, and at most
local DEFAULT_PRINT, MAX_PRINT = 10, 100

---Checks a payload of the table `guildchat`: the key is an id, the sender and the text are strings within
---their lengths, and there are no other fields.
---@param key string
---@param payload any
---@return boolean
function guildChat.validate(key, payload)
  if not versionId.isWellFormed(key) or type(payload) ~= "table" then
    return false
  end
  local sender, text = payload.s, payload.t
  if type(sender) ~= "string" or #sender < 1 or #sender > MAX_SENDER then
    return false
  end
  if type(text) ~= "string" or #text < 1 or #text > MAX_TEXT then
    return false
  end
  for field in pairs(payload) do
    if field ~= "s" and field ~= "t" then
      return false
    end
  end
  return true
end

ns.sync:RegisterTable({
  name = guildChat.TABLE,
  schema = 1,
  keyKind = "free",
  validate = guildChat.validate,
  -- The longest record is about 350 bytes: key and id, a sender of 48 bytes, a text of 255
  maxRecordBytes = 400,
  -- A line can be written by a member who is not its sender (the witness, plan section 5.3)
  writers = "anyone",
  maxAge = guildChat.KEEP_DAYS * 86400,
  -- A line is written once, so two replicas hold the same lines of an hour or one of them has a hole
  gapCheckHours = guildChat.GAP_CHECK_HOURS,
  -- An online member reads the chat in the game, so the table need not follow it closely: the lines of a
  -- minute go out in one push. A longer wait saved little traffic and made a line that its writer could
  -- see in `/oooo sync chat` look lost on the other accounts (client check of step 10.2).
  policy = { when = "nocombat", pushDelay = 60, minInterval = 60 },
})

--------------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------------

---Returns the name of the logged-in character as the roster shows it.
---@return string|nil
local function ownName()
  return (guildChat.playerName or ns.syncCharacter.playerName)()
end

---Returns the session of the shared database, which knows the peers; nil when there is none.
---@return OOOOSyncSession|nil
local function currentSession()
  return guildChat.session or (ns.syncSession and ns.syncSession.current)
end

---Tells whether this replica is the witness: the one that writes the lines of members without the addon.
---It is the replica whose character name is the first in byte order among itself and its online peers.
---Before the first discovery is complete it knows no peers and would take every line, so it is no witness.
---
---The peer list can lack a peer, mostly after a login whose hello nobody had to answer. Two replicas can
---then both write a line; `Lines` joins the two records.
---@param own string Name of the logged-in character
---@return boolean
function guildChat:IsWitness(own)
  local session = currentSession()
  if not session or not session.discovered then
    return false
  end
  for name in pairs(session.peers) do
    if name < own then
      return false
    end
  end
  return true
end

---Tells whether this replica is the one that writes a line of guild chat. Every online member hears the
---line, and the game gives it no id that all clients share, so exactly one replica must store it: the
---addon of the sender, or the witness when the sender is no peer.
---@param sender string Character name of the sender
---@param own string Name of the logged-in character
---@return boolean
function guildChat:ShouldWrite(sender, own)
  if sender == own then
    return true
  end
  local session = currentSession()
  if not session or session.peers[sender] then
    return false
  end
  return self:IsWitness(own)
end

---Warns the writer of an own line with an `@` word when no other replica is online to copy it: the member
---who is meant gets the line only after a replica has met this one. Before the discovery has ended the peers
---are not known, and nothing is printed.
---@param text string The text of an own guild chat line; not a secret value
---@return boolean warned
function guildChat:WarnIfUnshared(text)
  local session = currentSession()
  if not session or not session.discovered or next(session.peers) ~= nil then
    return false
  end
  if not ns.mentions or not ns.mentions.hasMention(text) or not ns.sync.timeFn then
    return false
  end
  local now = ns.sync.timeFn()
  if self.warnedAt and now - self.warnedAt < guildChat.WARNING_INTERVAL then
    return false
  end
  self.warnedAt = now
  ns.print(guildChat.UNSHARED_WARNING)
  return true
end

---Takes one line of guild chat, as the event CHAT_MSG_GUILD gives it, and stores it when this replica is
---the one that writes it. A line whose sender or text is secret is not recorded.
---@param text any The message
---@param sender any The name of the sender
---@return string|nil id The id of the new record; nil when nothing was written
function guildChat:OnChatLine(text, sender)
  local counts = self.counts
  counts.heard = counts.heard + 1
  if issecretvalue(text) or issecretvalue(sender) then
    counts.secret = counts.secret + 1
    return nil
  end
  if type(text) ~= "string" then
    return nil
  end
  self.lastSender = type(sender) == "string" and sender or nil
  local name = ns.guildState.normalizeName(sender)
  local own = ownName()
  if name and name == own then
    self:WarnIfUnshared(text)
  end
  if not name or not own or not self:ShouldWrite(name, own) then
    return nil
  end
  -- A text that the table refuses (empty, or over the length of a chat message) is not recorded
  local id = ns.sync:Append(guildChat.TABLE, { s = name, t = text })
  if id then
    counts.written = counts.written + 1
  end
  return id
end

---Builds the line about the capture for `/oooo sync chat`: whether the replica listens, what it has heard
---in this session, and the names that decide whether a line is an own one. It is what the client check of
---the table reads when no line is stored.
---@return string line Ready for chat: every `|` is doubled
function guildChat:CaptureStatus()
  local counts = self.counts
  local state = self.eventMissing and "the client has no event CHAT_MSG_GUILD"
    or (self.listening and "listening" or "not listening (not in the guild)")
  local session = currentSession()
  local own = ownName()
  return ns.syncCommands.escape("capture: " .. state .. "; this session " .. counts.heard .. " lines heard, "
    .. counts.secret .. " secret, " .. counts.written .. " written; own name '" .. tostring(own)
    .. "', last sender '" .. tostring(self.lastSender) .. "'; "
    .. (own and session and self:IsWitness(own) and "witness" or "not the witness"))
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

---Returns the first index of a sorted list whose entry is not below `value`; the length plus 1 when all
---entries are below it.
---@param list string[]
---@param value string
---@return integer
local function lowerBound(list, value)
  local low, high = 1, #list + 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if list[middle] < value then
      low = middle + 1
    else
      high = middle
    end
  end
  return low
end

---Returns the payload of a stored record when it is a chat line: not deleted, stored under its own id, and
---with a sender and a text. A record under another key is not one: a modified addon could give it any
---place in time.
---@param tbl OOOOSyncTable
---@param key string
---@return OOOOGuildChatPayload|nil
local function lineOf(tbl, key)
  local record = tbl.records[key]
  if not record or record.x or record.v ~= key then
    return nil
  end
  local payload = record.d
  if type(payload) ~= "table" or type(payload.s) ~= "string" or type(payload.t) ~= "string" then
    return nil
  end
  return payload
end

---Returns the payload of the stored chat line with an id; nil when no line is stored under it. The table
---that is returned is the stored one: do not change it.
---@param id string
---@return OOOOGuildChatPayload|nil
function guildChat:Payload(id)
  local tbl = ns.sync:GetTable(guildChat.TABLE)
  return tbl and lineOf(tbl, id) or nil
end

---Returns the keys of the chat lines in id order, which is the order of time. The list is built once, with
---one pass over the table, and then kept current by `OnRecordChanged`. Do not change it.
---@return string[] keys Empty while the database is not ready
function guildChat:Keys()
  local keys = self.keys
  if keys then
    return keys
  end
  local tbl = ns.sync:GetTable(guildChat.TABLE)
  keys = {}
  if not tbl then
    return keys
  end
  for key in pairs(tbl.records) do
    if lineOf(tbl, key) then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  self.keys = keys
  return keys
end

---Follows the table: a new line gets its place in the sorted keys. Lines arrive in id order in nearly all
---cases, so the place is the end. After a removal the list is built again by the next reader: the hourly
---expiry removes many records at once, and nobody may read before the next one.
ns.sync.RegisterCallback(guildChat, "OnRecordChanged", function(_event, tableName, key, payload)
  local keys = guildChat.keys
  if tableName ~= guildChat.TABLE or not keys then
    return
  end
  if payload == nil then
    guildChat.keys = nil
    return
  end
  local tbl = ns.sync:GetTable(guildChat.TABLE)
  if not tbl or not lineOf(tbl, key) then
    return
  end
  local index = lowerBound(keys, key)
  if keys[index] ~= key then
    table.insert(keys, index, key)
  end
end)

---Returns the stored lines of guild chat in the order of time. Records with the same sender and the same
---text whose ids are within `DUPLICATE_WINDOW` of the first of them are one line: two replicas can write
---one line when they disagree for a moment about who writes it. A member who repeats a text within that
---time is therefore shown once.
---@param sinceTime integer? Server time; only lines from that time on. Without it, all lines
---@return OOOOGuildChatLine[] lines New tables; the caller may keep and change them
function guildChat:Lines(sinceTime)
  local lines = {}
  local tbl = ns.sync:GetTable(guildChat.TABLE)
  if not tbl then
    return lines
  end
  local keys = self:Keys()
  local since = sinceTime or 0
  -- The scan starts one window earlier: a record after `since` can repeat a line from before it
  local first = since > 0 and lowerBound(keys, versionId.timePrefix(since - guildChat.DUPLICATE_WINDOW)) or 1
  ---Sender and text -> the last line with them
  ---@type table<string, OOOOGuildChatLine>
  local shown = {}
  for index = first, #keys do
    local key = keys[index]
    -- A record can have been replaced since the list was built
    local payload = lineOf(tbl, key)
    if payload then
      local time = versionId.parse(key) --[[@as integer]]
      local mark = payload.s .. "\0" .. payload.t
      local bySender = ns.sync.IsOriginOf ~= nil and ns.sync:IsOriginOf(payload.s, versionId.originOf(key))
      local line = shown[mark]
      if line and time - line.time <= guildChat.DUPLICATE_WINDOW then
        -- The sender's own record vouches for the line, also when a witness wrote it a moment earlier
        line.bySender = line.bySender or bySender
      else
        line = { id = key, time = time, sender = payload.s, text = payload.t, bySender = bySender }
        shown[mark] = line
        if time >= since then
          lines[#lines + 1] = line
        end
      end
    end
  end
  return lines
end

---Returns one page of the stored guild chat for a reader that goes back in time: up to `count` lines older
---than `beforeId`, in the order of time, with double records joined as in `Lines`. It reads only the end of
---the sorted keys that it needs, so its cost does not grow with the table.
---@param beforeId string|nil Id of the oldest line that the reader holds; nil gives the newest lines
---@param count integer
---@return OOOOGuildChatLine[] lines New tables, oldest first
---@return boolean hasOlder true when the table holds lines before the first one of the page
function guildChat:Page(beforeId, count)
  local lines = {} ---@type OOOOGuildChatLine[]
  local tbl = ns.sync:GetTable(guildChat.TABLE)
  if not tbl then
    return lines, false
  end
  local keys = self:Keys()
  local window = guildChat.DUPLICATE_WINDOW
  ---Index of a key -> whether its record repeats an earlier line, or is no line
  ---@type table<integer, boolean>
  local repeats = {}

  ---Tells whether the record at an index is not a line of its own: a line with its sender and text is
  ---shown at most `DUPLICATE_WINDOW` before it. This is the rule of `Lines`, read backwards.
  ---@param index integer
  ---@return boolean
  local function isRepeat(index)
    local known = repeats[index]
    if known ~= nil then
      return known
    end
    local payload = lineOf(tbl, keys[index])
    local result = payload == nil
    if payload then
      local time = versionId.parse(keys[index])
      for other = index - 1, 1, -1 do
        if time - versionId.parse(keys[other]) > window then
          break
        end
        local earlier = lineOf(tbl, keys[other])
        if earlier and earlier.s == payload.s and earlier.t == payload.t and not isRepeat(other) then
          result = true
          break
        end
      end
    end
    repeats[index] = result
    return result
  end

  local index = beforeId and lowerBound(keys, beforeId) - 1 or #keys
  while index >= 1 and #lines < count do
    if not isRepeat(index) then
      local key = keys[index]
      local payload = lineOf(tbl, key) --[[@as OOOOGuildChatPayload]]
      local time = versionId.parse(key) --[[@as integer]]
      local hasOrigins = ns.sync.IsOriginOf ~= nil
      local bySender = hasOrigins and ns.sync:IsOriginOf(payload.s, versionId.originOf(key))
      -- The sender's own record vouches for the line, also when a witness wrote it a moment earlier
      for later = index + 1, #keys do
        if bySender or not hasOrigins or versionId.parse(keys[later]) - time > window then
          break
        end
        local other = lineOf(tbl, keys[later])
        if other and other.s == payload.s and other.t == payload.t then
          bySender = ns.sync:IsOriginOf(payload.s, versionId.originOf(keys[later]))
        end
      end
      lines[#lines + 1] = { id = key, time = time, sender = payload.s, text = payload.t, bySender = bySender }
    end
    index = index - 1
  end
  -- Collected newest first
  for position = 1, math.floor(#lines / 2) do
    lines[position], lines[#lines + 1 - position] = lines[#lines + 1 - position], lines[position]
  end
  -- The earliest record of the table is never a repeat, so any line that is left is an older one
  local hasOlder = false
  while index >= 1 and not hasOlder do
    hasOlder = lineOf(tbl, keys[index]) ~= nil
    index = index - 1
  end
  return lines, hasOlder
end

---Builds the lines that `/oooo sync chat` prints: the last lines, oldest first, each with its age. A line
---that the sender's own addon did not write is marked.
---@param count integer Number of lines
---@param now number Server time
---@return string[] lines Ready for chat: every `|` is doubled, so a link shows as its text
function guildChat:PrintLines(count, now)
  local lines = self:Lines()
  local result = { "guild chat: " .. #lines .. " lines stored, the last " .. math.min(count, #lines) .. ":" }
  for index = math.max(1, #lines - count + 1), #lines do
    local line = lines[index]
    result[#result + 1] = ns.syncCommands.escape("  " .. ns.syncOptions.ago(now - line.time) .. " " .. line.sender
      .. (line.bySender and "" or " (witness)") .. ": " .. line.text)
  end
  return result
end

ns.syncSlash:Register("chat", "chat [count] - the last lines of the stored guild chat", function(rest)
  local count = tonumber(rest:match("^(%d+)$"))
  if rest ~= "" and not count then
    ns.print("Usage: /oooo sync chat [count]")
    return
  end
  if not ns.sync.timeFn then
    ns.print("The shared database is not ready.")
    return
  end
  for _, line in ipairs(guildChat:PrintLines(math.min(count or DEFAULT_PRINT, MAX_PRINT), ns.sync.timeFn())) do
    ns.print(line)
  end
  ns.print(guildChat:CaptureStatus())
end)

--------------------------------------------------------------------------------
-- The event frame
--------------------------------------------------------------------------------

---Event name -> handler. The arguments are those of the event.
---@type table<string, fun(...: any)>
local handlers = {
  CHAT_MSG_GUILD = function(text, sender)
    guildChat:OnChatLine(text, sender)
  end,
}
guildChat.handlers = handlers

---Starts or stops listening to the guild chat. The lines are recorded only while the character is in the
---guild: in another guild the same event carries the chat of that guild.
---@param listening boolean
function guildChat:SetListening(listening)
  if not self.frame then
    if not listening then
      return
    end
    self.frame = CreateFrame("Frame")
    self.frame:SetScript("OnEvent", function(_frame, event, ...)
      handlers[event](...)
    end)
  end
  self.listening = listening
  for event in pairs(handlers) do
    -- Registering an event that the client does not know throws
    if C_EventUtils.IsEventValid(event) then
      if listening then
        self.frame:RegisterEvent(event)
      else
        self.frame:UnregisterEvent(event)
      end
    else
      self.eventMissing = true
    end
  end
end

ns.guildState.RegisterCallback(guildChat, "OnGuildStateChanged", function(_event, inGuild)
  guildChat:SetListening(inGuild)
end)
