local addonName, ns = ...

-- The table `guildchat` of the shared database (.agents/00-plan.md, section 5.3): a copy of the guild chat
-- of the last 14 days, for the member who was offline. One chat line is one record that is written once,
-- under its own version id as key, by the addon of the member who wrote the line. It is not real time: the
-- lines travel with the push and the pull of the engine.
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

---@class OOOOGuildChat
---@field playerName (fun(): string|nil)|nil Gives the name of the logged-in character; set by a host test,
---in the game `ns.syncCharacter.playerName` is used
---@field keys string[]|nil The keys of the chat lines, sorted; nil until `Lines` builds it, and again after
---a record was removed
---@field frame table|nil The event frame; nil until the character is in the guild
local guildChat = {}
ns.guildChat = guildChat

local versionId = ns.versionId

---Name of the table
guildChat.TABLE = "guildchat"
---Days for which every replica keeps the lines. The same for everybody; it is not a setting, because a
---pull request has no lower limit and counts on equal lengths (plan section 5.3).
guildChat.KEEP_DAYS = 14
---Seconds within which two records with the same sender and text count as one line. It is wide because an
---id can be minutes ahead of the real time (plan section 3).
guildChat.DUPLICATE_WINDOW = 180
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
  -- An online member reads the chat in the game: the lines of 5 minutes go out in one push
  policy = { when = "nocombat", pushDelay = 300, minInterval = 600 },
})

--------------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------------

---Returns the name of the logged-in character as the roster shows it.
---@return string|nil
local function ownName()
  return (guildChat.playerName or ns.syncCharacter.playerName)()
end

---Tells whether this replica is the one that writes a line of guild chat. Every online member hears the
---line, and the game gives it no id that all clients share, so exactly one replica must store it: the
---addon of the sender.
---@param sender string Character name of the sender
---@param own string Name of the logged-in character
---@return boolean
function guildChat:ShouldWrite(sender, own)
  return sender == own
end

---Takes one line of guild chat, as the event CHAT_MSG_GUILD gives it, and stores it when this replica is
---the one that writes it. A line whose sender or text is secret is not recorded.
---@param text any The message
---@param sender any The name of the sender
---@return string|nil id The id of the new record; nil when nothing was written
function guildChat:OnChatLine(text, sender)
  if issecretvalue(text) or issecretvalue(sender) or type(text) ~= "string" then
    return nil
  end
  local name = ns.guildState.normalizeName(sender)
  local own = ownName()
  if not name or not own or not self:ShouldWrite(name, own) then
    return nil
  end
  -- A text that the table refuses (empty, or over the length of a chat message) is not recorded
  return (ns.sync:Append(guildChat.TABLE, { s = name, t = text }))
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
      local line = shown[mark]
      if not line or time - line.time > guildChat.DUPLICATE_WINDOW then
        line = { id = key, time = time, sender = payload.s, text = payload.t }
        shown[mark] = line
        if time >= since then
          lines[#lines + 1] = line
        end
      end
    end
  end
  return lines
end

---Builds the lines that `/oooo sync chat` prints: the last lines, oldest first, each with its age.
---@param count integer Number of lines
---@param now number Server time
---@return string[] lines Ready for chat: every `|` is doubled, so a link shows as its text
function guildChat:PrintLines(count, now)
  local lines = self:Lines()
  local result = { "guild chat: " .. #lines .. " lines stored, the last " .. math.min(count, #lines) .. ":" }
  for index = math.max(1, #lines - count + 1), #lines do
    local line = lines[index]
    result[#result + 1] = ns.syncCommands.escape("  " .. ns.syncOptions.ago(now - line.time) .. " " .. line.sender
      .. ": " .. line.text)
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
  for event in pairs(handlers) do
    -- Registering an event that the client does not know throws
    if C_EventUtils.IsEventValid(event) then
      if listening then
        self.frame:RegisterEvent(event)
      else
        self.frame:UnregisterEvent(event)
      end
    end
  end
end

ns.guildState.RegisterCallback(guildChat, "OnGuildStateChanged", function(_event, inGuild)
  guildChat:SetListening(inGuild)
end)
