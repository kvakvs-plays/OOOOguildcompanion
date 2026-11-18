local addonName, ns = ...

-- Mentions in the guild chat (.agents/00-plan.md, stage 11): a word that starts with `@`. The user lists the
-- nicknames and keywords that they watch, and the lines of the table `guildchat` that have `@` before one of
-- them are the mentions of the user.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_mentions.lua).

---@class OOOOMentions
local mentions = {}
ns.mentions = mentions

---A character of a word. Bytes above 127 are parts of UTF-8 letters and belong to the word, as in
---Emoji/EmojiChat.lua.
local WORD_CHARACTER_PATTERN = "^[%w_\128-\255]"
---An `@` with a word character behind it: the start of a mention
local MENTION_PATTERN = "@[%w_\128-\255]"

---Escape sequences in which nothing is searched, as in Emoji/EmojiChat.lua. Each is tried at the position
---of a `|` character.
local ESCAPE_PATTERNS = {
  "^|H.-|h.-|h", -- hyperlink with its text
  "^|T.-|t", -- texture
  "^|A.-|a", -- atlas
  "^|K.-|k", -- protected name
  "^|c%x%x%x%x%x%x%x%x", -- colour
  "^|cn.-:", -- named colour
  "^|.", -- |r, |n, || and anything unknown
}

---Calls `onPlain` for every part of a chat text that is outside an escape sequence.
---@param text string
---@param onPlain fun(from: integer, to: integer): boolean|nil Gets the first and the last position of the
---part; true ends the walk
local function eachPlainPart(text, onPlain)
  local position, length = 1, #text
  while position <= length do
    local bar = text:find("|", position, true)
    if not bar then
      onPlain(position, length)
      return
    end
    if bar > position and onPlain(position, bar - 1) then
      return
    end
    local escapeEnd = bar -- a lone `|` at the end of the text
    for _, pattern in ipairs(ESCAPE_PATTERNS) do
      local _, patternEnd = text:find(pattern, bar)
      if patternEnd then
        escapeEnd = patternEnd
        break
      end
    end
    position = escapeEnd + 1
  end
end

---Turns the text of the setting into the watch list: the entries between the commas, trimmed and in lower
---case, each once. An entry keeps its inner spaces (`nota tall`); an `@` before it is dropped.
---
---`string.lower` changes only ASCII letters, so an entry with another letter matches only in the letter
---case in which it was typed.
---@param text any The setting, as the user typed it
---@return string[] watchList In the order of the setting
function mentions.parseWatchList(text)
  local list = {}
  if type(text) ~= "string" then
    return list
  end
  local seen = {} ---@type table<string, boolean>
  for piece in text:gmatch("[^,]+") do
    local entry = piece:match("^%s*@*(.-)%s*$"):lower()
    if entry ~= "" and not seen[entry] then
      seen[entry] = true
      list[#list + 1] = entry
    end
  end
  return list
end

---Tells whether a chat text has a word that starts with `@`, whoever is meant. An e-mail form (`a@b`)
---counts; a lone `@` and an `@` inside a hyperlink or another escape sequence do not.
---@param text string
---@return boolean
function mentions.hasMention(text)
  if not text:find("@", 1, true) then
    return false
  end
  local found = false
  eachPlainPart(text, function(from, to)
    local at = text:find(MENTION_PATTERN, from)
    -- The word character must be inside the part too
    found = at ~= nil and at < to
    return found
  end)
  return found
end

---Returns the watched mentions of a chat text: every `@` that is directly followed by an entry of the watch
---list, in any letter case, where the entry ends at the end of a word (`@kv` is not a part of `@kvakvs`).
---@param text string
---@param watchList string[] From `parseWatchList`
---@return string[] fragments The mentions as they were written (`@Tall`), in their order; empty when the
---line does not concern the user
function mentions.fragments(text, watchList)
  local found = {}
  if #watchList == 0 or not text:find("@", 1, true) then
    return found
  end
  -- string.lower changes only ASCII letters, so the positions in `lowerText` and `text` are the same
  local lowerText = text:lower()
  eachPlainPart(text, function(from, to)
    local position = from
    while true do
      local at = text:find("@", position, true)
      if not at or at >= to then
        return
      end
      local matchEnd ---@type integer|nil
      for _, entry in ipairs(watchList) do
        local entryEnd = at + #entry
        -- Of two entries that match here, the longer one is meant ("nota" and "nota tall")
        if entryEnd <= to and (not matchEnd or entryEnd > matchEnd) and lowerText:sub(at + 1, entryEnd) == entry
          and not text:find(WORD_CHARACTER_PATTERN, entryEnd + 1) then
          matchEnd = entryEnd
        end
      end
      if matchEnd then
        found[#found + 1] = text:sub(at, matchEnd)
      end
      position = (matchEnd or at) + 1
    end
  end)
  return found
end

---Copies a chat text into `parts` with only the harmless escape sequences kept; see `sanitize`.
---@param parts string[]
---@param text string
---@param state { open: integer } Counts the colour codes that are not closed
local function sanitizeInto(parts, text, state)
  local position, length = 1, #text
  while position <= length do
    local bar = text:find("|", position, true)
    if not bar then
      parts[#parts + 1] = text:sub(position)
      return
    end
    if bar > position then
      parts[#parts + 1] = text:sub(position, bar - 1)
    end
    local _, linkEnd, linkData, linkText = text:find("^|H([^|]*)|h(.-)|h", bar)
    local _, colourEnd = text:find("^|c%x%x%x%x%x%x%x%x", bar)
    if not colourEnd then
      _, colourEnd = text:find("^|cn[^|:]*:", bar)
    end
    if linkEnd then
      parts[#parts + 1] = "|H" .. linkData .. "|h"
      -- The text of a link can carry escape sequences of its own
      sanitizeInto(parts, linkText, state)
      parts[#parts + 1] = "|h"
      position = linkEnd + 1
    elseif colourEnd then
      state.open = state.open + 1
      parts[#parts + 1] = text:sub(bar, colourEnd)
      position = colourEnd + 1
    elseif text:find("^|r", bar) then
      state.open = math.max(0, state.open - 1)
      parts[#parts + 1] = "|r"
      position = bar + 2
    elseif text:find("^||", bar) then
      parts[#parts + 1] = "||"
      position = bar + 2
    else
      parts[#parts + 1] = "||"
      position = bar + 1
    end
  end
end

---Makes the text of a stored chat line safe to show. The text is untrusted: any member can write a record
---of the table `guildchat`. Hyperlinks with their text, colour codes, `|r`, and `||` stay; every other `|`
---is doubled, so a texture, an atlas, or a line break shows as its text. A colour that the text leaves open
---is closed at the end.
---@param text string
---@return string
function mentions.sanitize(text)
  if not text:find("|", 1, true) then
    return text
  end
  local parts = {} ---@type string[]
  local state = { open = 0 }
  sanitizeInto(parts, text, state)
  for _ = 1, state.open do
    parts[#parts + 1] = "|r"
  end
  return table.concat(parts)
end

--------------------------------------------------------------------------------
-- The mention list (plan step 11.2)
--------------------------------------------------------------------------------

---@class OOOOMentionStore The mention list of this account, `db.global.mentions`. It is local: no replica
---sends it.
---@field lines table<string, boolean> Id of a `guildchat` record whose text has an `@` word, whoever is
---meant -> true when the user has read it
---@field lastOnline integer|nil Server time at which the account was last seen online

---@class OOOOMentionParts What the mention list needs from the game; a host test passes its own
---@field store OOOOMentionStore
---@field watch fun(): any Gives the setting with the watched nicknames, as typed
---@field now fun(): integer Server time in seconds
---@field playerName fun(): string|nil Name of the logged-in character, as the roster shows it
---@field loginTime integer|nil Server time of the login of this session; without it, the time of the call

---@class OOOOMention One mention of the user, as `List` gives it
---@field id string Id of the `guildchat` record; of the earliest one when two records are one line
---@field ids string[] The ids of all records of the line
---@field time integer Server time of the line
---@field sender string
---@field text string The original text: untrusted, pass it through `sanitize` before it is shown
---@field fragments string[] The watched `@text` parts of the line, as written
---@field isRead boolean

---@class OOOOMentions
---@field parts OOOOMentionParts|nil nil until `Attach`
---@field loginTime integer Server time of the login of this session
---@field onlineUntil integer|nil `lastOnline` as the session before left it
---@field list OOOOMention[]|nil The result of `List`, kept until the entries or the setting change
---@field listWatch any The setting for which `list` was built
---@field callbacks table CallbackHandler registry; fires "OnMentionsChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)

---Event for the notice and the window, in the CallbackHandler form:
---`ns.mentions.RegisterCallback(owner, "OnMentionsChanged", function(event, newId) end)`. It fires when an
---entry was added, removed, or read, and when the watch list changed. `newId` is the id of an entry that a
---record brought which arrived or was written in this session; nil otherwise.
mentions.callbacks = LibStub("CallbackHandler-1.0"):New(mentions)

---Seconds between two writes of `lastOnline`: a crash writes nothing, so the logout alone is not enough
mentions.ONLINE_INTERVAL = 300

---Decides whether a new entry starts as read. It is unread when the user cannot have seen the line in the
---game: the line is not an own one, and its time is after the account was last online and before the login
---of this session.
---@param id string
---@param sender string
---@return boolean isRead
function mentions:StartsRead(id, sender)
  if sender == self.parts.playerName() then
    return true
  end
  local time = ns.versionId.parse(id)
  if not time or time >= self.loginTime then
    return true
  end
  return self.onlineUntil ~= nil and time <= self.onlineUntil
end

---Adds the entry of a chat record when its text has an `@` word and it has none yet.
---@param id string
---@param payload OOOOGuildChatPayload
---@return boolean added
function mentions:AddEntry(id, payload)
  local lines = self.parts.store.lines
  if lines[id] ~= nil or not mentions.hasMention(payload.t) then
    return false
  end
  lines[id] = self:StartsRead(id, payload.s)
  self.list = nil
  return true
end

---Makes the list equal to the table: an entry whose record is gone is dropped, and a record with an `@`
---word and no entry gets one. Called at login; later the list follows `OnRecordChanged`.
function mentions:Reconcile()
  local lines = self.parts.store.lines
  local chat = ns.guildChat
  for id, isRead in pairs(lines) do
    if type(id) ~= "string" or type(isRead) ~= "boolean" or not chat:Payload(id) then
      lines[id] = nil
    end
  end
  for key, payload in ns.sync:Iterate(chat.TABLE) do
    if lines[key] == nil and chat:Payload(key) == payload then
      self:AddEntry(key, payload)
    end
  end
  self.list = nil
end

---Connects the mention list to its storage and to the table `guildchat`, at login.
---@param parts OOOOMentionParts
function mentions:Attach(parts)
  local store = parts.store
  if type(store.lines) ~= "table" then
    store.lines = {}
  end
  self.parts = parts
  self.loginTime = parts.loginTime or parts.now()
  self.onlineUntil = type(store.lastOnline) == "number" and store.lastOnline or nil
  self:Reconcile()
  self:NoteOnline()
  ns.sync.RegisterCallback(mentions, "OnRecordChanged", function(_event, tableName, key, payload)
    mentions:OnRecordChanged(tableName, key, payload)
  end)
  self.callbacks:Fire("OnMentionsChanged")
end

---Follows the table `guildchat`: a record with an `@` word gets an entry, and the entry of a record that
---is gone (the expiry, the reset of a stale table) is removed.
---@param tableName string
---@param key string
---@param payload any nil when the record was removed
function mentions:OnRecordChanged(tableName, key, payload)
  if tableName ~= ns.guildChat.TABLE or not self.parts then
    return
  end
  if payload == nil then
    local lines = self.parts.store.lines
    if lines[key] ~= nil then
      lines[key] = nil
      self.list = nil
      self.callbacks:Fire("OnMentionsChanged")
    end
  elseif ns.guildChat:Payload(key) == payload and self:AddEntry(key, payload) then
    self.callbacks:Fire("OnMentionsChanged", key)
  end
end

---Writes down that the account is online now. Called at login, at logout, and every `ONLINE_INTERVAL`.
function mentions:NoteOnline()
  if self.parts then
    self.parts.store.lastOnline = self.parts.now()
  end
end

---Returns the mentions of the user: the entries whose line has a watched `@text` part, by the watch list
---of this moment, so a nickname that the user adds later also finds older lines. Two records of one line
---(`ns.guildChat.DUPLICATE_WINDOW`) are one mention.
---@return OOOOMention[] list Newest first. Do not change it: it is kept until the entries change
function mentions:List()
  if not self.parts then
    return {}
  end
  local watchText = self.parts.watch()
  if self.list and self.listWatch == watchText then
    return self.list
  end
  local list = {} ---@type OOOOMention[]
  self.list, self.listWatch = list, watchText
  local watchList = mentions.parseWatchList(watchText)
  if #watchList == 0 then
    return list
  end
  local lines = self.parts.store.lines
  local ids = {} ---@type string[]
  for id in pairs(lines) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local chat = ns.guildChat
  ---Sender and text -> the last mention with them
  ---@type table<string, OOOOMention>
  local shown = {}
  for _, id in ipairs(ids) do
    local payload = chat:Payload(id)
    local found = payload and mentions.fragments(payload.t, watchList)
    if payload and #found > 0 then
      local time = ns.versionId.parse(id) --[[@as integer]]
      local mark = payload.s .. "\0" .. payload.t
      local entry = shown[mark]
      if entry and time - entry.time <= chat.DUPLICATE_WINDOW then
        entry.ids[#entry.ids + 1] = id
        entry.isRead = entry.isRead or lines[id]
      else
        entry = { id = id, ids = { id }, time = time, sender = payload.s, text = payload.t, fragments = found,
          isRead = lines[id] }
        shown[mark] = entry
        list[#list + 1] = entry
      end
    end
  end
  -- Newest first
  for index = 1, math.floor(#list / 2) do
    list[index], list[#list + 1 - index] = list[#list + 1 - index], list[index]
  end
  return list
end

---Counts the mentions of the user that are unread.
---@return integer
function mentions:UnreadCount()
  local count = 0
  for _, entry in ipairs(self:List()) do
    if not entry.isRead then
      count = count + 1
    end
  end
  return count
end

---Marks a mention as read, with every record of its line.
---@param id string Id of an entry
---@return boolean changed false when there is no such entry or it was read already
function mentions:MarkRead(id)
  local lines = self.parts and self.parts.store.lines
  if not lines or lines[id] == nil then
    return false
  end
  local ids = { id }
  for _, entry in ipairs(self:List()) do
    for _, other in ipairs(entry.ids) do
      if other == id then
        ids = entry.ids
      end
    end
  end
  local changed = false
  for _, other in ipairs(ids) do
    if lines[other] == false then
      lines[other] = true
      changed = true
    end
  end
  if changed then
    self.list = nil
    self.callbacks:Fire("OnMentionsChanged")
  end
  return changed
end

---Tells the listeners that the setting with the watched nicknames has changed.
function mentions:WatchChanged()
  self.callbacks:Fire("OnMentionsChanged")
end

--------------------------------------------------------------------------------
-- In the game
--------------------------------------------------------------------------------

---Event name -> handler
---@type table<string, fun()>
local handlers = {
  PLAYER_LOGOUT = function()
    mentions:NoteOnline()
  end,
}

---Writes `lastOnline` and waits for the next turn.
local function onlineTick()
  mentions:NoteOnline()
  C_Timer.After(mentions.ONLINE_INTERVAL, onlineTick)
end

---Connects the mention list to the saved variables of the game. Core.lua calls it on PLAYER_LOGIN, before
---the session of the shared database starts.
function mentions.Start()
  if mentions.parts then
    return
  end
  mentions:Attach({
    store = ns.db.global.mentions,
    watch = function()
      return ns.db.profile.mentions.watch
    end,
    now = GetServerTime,
    playerName = ns.syncCharacter.playerName,
  })
  local frame = CreateFrame("Frame")
  frame:SetScript("OnEvent", function(_frame, event)
    handlers[event]()
  end)
  for event in pairs(handlers) do
    -- Registering an event that the client does not know throws
    if C_EventUtils.IsEventValid(event) then
      frame:RegisterEvent(event)
    end
  end
  C_Timer.After(mentions.ONLINE_INTERVAL, onlineTick)
end
