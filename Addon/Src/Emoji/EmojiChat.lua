local addonName, ns = ...

---@class OOOOEmojiPhrase An alias which is not one plain word, like "gz kush"
---@field text string The alias: in lower case, or as written when `caseSensitive` is set
---@field id integer Emoji id
---@field name string Emoji name
---@field caseSensitive boolean true when chat must have the exact letter case

---Shows emoji in the kinds of chat that the user chose (`CHANNELS`). The text is cut into tokens, and a token
---in lower case which is a key of `ns.emojiTriggerStrings` is replaced by the emoji. A token is a word, the
---word with a colon before it, or the word between two colons. The generated trigger strings are the names
---of the guild emoji, and `:name` and `:name:` for the standard emoji of Discord (`:joy:`, `:thumbsup`):
---the names of those are common words, so a bare word never shows one.
---
---The aliases of EmojiAliases.lua are triggers too. The emoji which EmojiOptions.lua marks as case sensitive
---match only in their exact letter case, and an alias of several words is found as a phrase.
---@class OOOOEmojiChat AceAddon-3.0 module
---@field filtersInstalled boolean true while the chat filters are registered
---@field escapes table<integer, string>|nil Emoji id -> texture escape sequence, filled as the emoji are met
---in chat; nil until the lookup tables are built
---@field aliasTriggers table<string, integer> One-word alias in lower case -> emoji id
---@field exactTriggers table<string, integer> Name or one-word alias of a case sensitive emoji -> emoji id
---@field exactIds table<integer, boolean> Emoji id -> true for a case sensitive emoji
---@field phrases table<string, OOOOEmojiPhrase[]> First word of an alias in lower case -> aliases, longest first
local emojiChat = ns.addon:NewModule("EmojiChat")
ns.emojiChat = emojiChat

---Sides of the emoji square in chat that the user can choose, in pixels
emojiChat.SIZES = { 16, 20, 24, 32, 40 }
---Side of the emoji square in chat when the setting is missing or is not one of `SIZES`
emojiChat.DEFAULT_SIZE = 32

---Returns the side of the emoji square in chat, in pixels: the setting `db.profile.general.emojiSize`.
---@return integer
function emojiChat:GetSize()
  local size = ns.db and ns.db.profile.general.emojiSize
  for _, allowed in ipairs(self.SIZES) do
    if size == allowed then
      return allowed
    end
  end
  return self.DEFAULT_SIZE
end

---Stores the side of the emoji square in chat. Lines that the chat frames already show keep their size.
---@param size integer One of `SIZES`
function emojiChat:SetSize(size)
  ns.db.profile.general.emojiSize = size
  -- The texture escapes carry the size: they are built again with the next chat line
  self.escapes = nil
  self:ResetCache()
end

---@class OOOOEmojiChannel A kind of chat in which emoji can be shown
---@field key string Key of the setting in `db.profile.general.emojiChannels`
---@field title string Name in the settings window

---The kinds of chat, in the order of the settings window. The defaults are in Core.lua.
---@type OOOOEmojiChannel[]
emojiChat.CHANNELS = {
  { key = "guild", title = "Guild" },
  { key = "party", title = "Party" },
  { key = "raid", title = "Raid" },
  { key = "officer", title = "Officer" },
  { key = "say", title = "Say" },
  { key = "general", title = "General" },
  { key = "trade", title = "Trade" },
}

---Chat event -> key of the kind of chat. `CHAT_MSG_CHANNEL` is not here: its kind follows the channel.
---@type table<string, string>
local EVENT_CHANNELS = {
  CHAT_MSG_GUILD = "guild",
  CHAT_MSG_PARTY = "party",
  CHAT_MSG_PARTY_LEADER = "party",
  CHAT_MSG_RAID = "raid",
  CHAT_MSG_RAID_LEADER = "raid",
  CHAT_MSG_RAID_WARNING = "raid",
  CHAT_MSG_OFFICER = "officer",
  CHAT_MSG_SAY = "say",
}

---Event of the numbered channels: General, Trade, and the channels that players make
local CHANNEL_EVENT = "CHAT_MSG_CHANNEL"

---Zone channel id (7th argument of `CHAT_MSG_CHANNEL`) -> key of the kind of chat. The ids are those of
---Retail and Classic; that Forever uses them is not checked on the client. A channel of players has 0.
---@type table<integer, string>
local ZONE_CHANNELS = {
  [1] = "general",
  [2] = "trade",
}

---Tells whether emoji are shown in a kind of chat.
---@param key string Key of `CHANNELS`
---@return boolean
function emojiChat:IsChannelEnabled(key)
  return ns.db ~= nil and ns.db.profile.general.emojiChannels[key] == true
end

---Turns the emoji of a kind of chat on or off. Lines that the chat frames already show stay as they are.
---@param key string Key of `CHANNELS`
---@param enabled boolean
function emojiChat:SetChannelEnabled(key, enabled)
  ns.db.profile.general.emojiChannels[key] = enabled and true or false
end

---Tells whether the standard emoji of Discord are shown: the setting `db.profile.general.emojiStandard`.
---@return boolean
function emojiChat:IsStandardEnabled()
  return ns.db ~= nil and ns.db.profile.general.emojiStandard ~= false
end

---Turns the standard emoji of Discord on or off. Lines that the chat frames already show stay as they are.
---@param enabled boolean
function emojiChat:SetStandardEnabled(enabled)
  ns.db.profile.general.emojiStandard = enabled and true or false
  self:ResetCache()
end

---Returns the kind of chat of a chat event.
---@param event string
---@param zoneChannelId any 7th argument of the event
---@return string|nil key Key of `CHANNELS`; nil for chat that never shows emoji
local function channelOf(event, zoneChannelId)
  if event ~= CHANNEL_EVENT then
    return EVENT_CHANNELS[event]
  end
  if issecretvalue(zoneChannelId) or zoneChannelId == nil then
    return nil
  end
  return ZONE_CHANNELS[zoneChannelId]
end

---A word. Bytes above 127 are parts of UTF-8 letters: they belong to the word, which keeps an emoji name
---inside a non-English word from matching.
local WORD_PATTERN = "[%w_\128-\255]+"
local FIRST_WORD_PATTERN = "^[%w_\128-\255]+"
local WORD_CHARACTER_PATTERN = "^[%w_\128-\255]"

---Escape sequences which must pass through unchanged; an emoji name inside a link would break the link.
---Each is tried at the position of a `|` character.
local ESCAPE_PATTERNS = {
  "^|H.-|h.-|h", -- hyperlink with its text
  "^|T.-|t", -- texture
  "^|A.-|a", -- atlas
  "^|K.-|k", -- protected name
  "^|c%x%x%x%x%x%x%x%x", -- colour
  "^|cn.-:", -- named colour
  "^|.", -- |r, |n, || and anything unknown
}

emojiChat.filtersInstalled = false

---Builds the lookup tables of the aliases and of the case sensitive emoji. The names themselves are in the
---generated `ns.emojiTriggerStrings`.
function emojiChat:BuildLookup()
  local aliasTriggers = {} ---@type table<string, integer>
  local exactTriggers = {} ---@type table<string, integer>
  local exactIds = {} ---@type table<integer, boolean>
  local phrases = {} ---@type table<string, OOOOEmojiPhrase[]>
  local all = ns.emoji:GetAll()

  -- All names go in before any alias, so an alias can never take over the name of another emoji
  for _, emoji in ipairs(all) do
    if emoji.caseSensitive then
      exactTriggers[emoji.name] = emoji.id
      exactIds[emoji.id] = true
    end
  end
  for _, emoji in ipairs(all) do
    for _, originalAlias in ipairs(emoji.aliases) do
      local alias = emoji.caseSensitive and originalAlias or originalAlias:lower()
      local firstWord = alias:match(FIRST_WORD_PATTERN)
      if firstWord == alias then
        local target = emoji.caseSensitive and exactTriggers or aliasTriggers
        target[alias] = target[alias] or emoji.id
      elseif firstWord then
        local key = firstWord:lower()
        local list = phrases[key] or {}
        phrases[key] = list
        list[#list + 1] = { text = alias, id = emoji.id, name = emoji.name, caseSensitive = emoji.caseSensitive }
      end
      -- An alias which does not start with a word character can never be found and is skipped
    end
  end
  for _, list in pairs(phrases) do
    table.sort(list, function(a, b)
      return #a.text > #b.text
    end)
  end

  self.aliasTriggers, self.exactTriggers, self.exactIds, self.phrases = aliasTriggers, exactTriggers, exactIds, phrases
  self.escapes = {}
end

---Looks a token up in the trigger strings.
---@param token string Token in lower case
---@param standard boolean true when the standard emoji of Discord are shown
---@return integer|nil id Emoji id; nil when the token shows no emoji
function emojiChat:FindTrigger(token, standard)
  -- A generated trigger goes before an alias, so an alias can never take over the name of another emoji
  local id = ns.emojiTriggerStrings[token] or self.aliasTriggers[token]
  if not id then
    return nil
  end
  local sprite = ns.emojiSprites[id]
  if sprite.standard then
    return standard and id or nil
  end
  -- A case sensitive emoji is found through `exactTriggers` only
  if self.exactIds[id] or not ns.emoji:IsEnabled(sprite.name) then
    return nil
  end
  return id
end

---Finds the emoji written at a word of the text. In this order: an alias of several words, a case sensitive
---name or alias, the word as a token, the word between two colons as a token (`:joy:`), and the word with the
---colon before it as a token (`:joy`). The last needs a colon which does not follow a word, which keeps
---"12:100" and "note:fire" as they are.
---@param text string
---@param lowerText string The text in lower case
---@param wordStart integer Position of the first character of the word
---@param wordEnd integer Position of the last character of the word
---@param position integer The text before this position is used up: a colon before it belongs to the emoji
---before
---@param standard boolean true when the standard emoji of Discord are shown
---@return integer|nil id Emoji id; nil when there is no emoji here
---@return integer|nil from Position of the first character of the match
---@return integer|nil to Position of the last character of the match
function emojiChat:MatchAt(text, lowerText, wordStart, wordEnd, position, standard)
  local colonBefore = wordStart > position and text:sub(wordStart - 1, wordStart - 1) == ":"
  local id, matchEnd ---@type integer|nil, integer

  local lowerWord = lowerText:sub(wordStart, wordEnd)
  local list = self.phrases[lowerWord]
  if list then
    for _, phrase in ipairs(list) do
      local source = phrase.caseSensitive and text or lowerText
      local phraseEnd = wordStart + #phrase.text - 1
      -- The phrase must end at the end of a word: "gz kush" is not a part of "gz kushy"
      if source:sub(wordStart, phraseEnd) == phrase.text
        and not text:find(WORD_CHARACTER_PATTERN, phraseEnd + 1)
        and ns.emoji:IsEnabled(phrase.name) then
        id, matchEnd = phrase.id, phraseEnd
        break
      end
    end
  end
  if not id then
    matchEnd = wordEnd
    id = self.exactTriggers[text:sub(wordStart, wordEnd)]
    if id and not ns.emoji:IsEnabled(ns.emojiSprites[id].name) then
      id = nil
    end
    id = id or self:FindTrigger(lowerWord, standard)
  end
  if id then
    -- Colons on both sides belong to the emoji (":Kek:"); a single colon is punctuation ("Kek: nice")
    if colonBefore and text:sub(matchEnd + 1, matchEnd + 1) == ":" then
      return id, wordStart - 1, matchEnd + 1
    end
    return id, wordStart, matchEnd
  end

  if colonBefore then
    if text:sub(wordEnd + 1, wordEnd + 1) == ":" then
      id = self:FindTrigger(lowerText:sub(wordStart - 1, wordEnd + 1), standard)
      if id then
        return id, wordStart - 1, wordEnd + 1
      end
    end
    if wordStart <= 2 or not text:find(WORD_CHARACTER_PATTERN, wordStart - 2) then
      id = self:FindTrigger(lowerText:sub(wordStart - 1, wordEnd), standard)
      if id then
        return id, wordStart - 1, wordEnd
      end
    end
  end
  return nil, nil, nil
end

---Replaces the emoji triggers in text which has no escape sequences.
---@param text string
---@return string
function emojiChat:ReplaceInPlainText(text)
  if not self.escapes then
    self:BuildLookup()
  end

  -- string.lower changes only ASCII letters, so the positions in `lowerText` and `text` are the same
  local lowerText = text:lower()
  local standard = self:IsStandardEnabled()
  local parts ---@type string[]|nil
  local position = 1 -- the text before it is already in `parts`
  local searchFrom = 1
  while true do
    local wordStart, wordEnd = text:find(WORD_PATTERN, searchFrom)
    if not wordStart then
      break
    end
    local id, from, to = self:MatchAt(text, lowerText, wordStart, wordEnd, position, standard)
    if id then
      local escape = self.escapes[id]
      if not escape then
        escape = ns.emoji:GetEscape(id, self:GetSize())
        self.escapes[id] = escape
      end
      parts = parts or {}
      parts[#parts + 1] = text:sub(position, from - 1)
      parts[#parts + 1] = escape
      position = to + 1
      searchFrom = position
    else
      searchFrom = wordEnd + 1
    end
  end

  if not parts then
    return text
  end
  parts[#parts + 1] = text:sub(position)
  return table.concat(parts)
end

---Replaces every emoji trigger with the texture of the emoji. Hyperlinks, textures,
---and colour codes of the message are kept as they are.
---@param message string Chat message text
---@return string
function emojiChat:ReplaceEmoji(message)
  if not message:find("|", 1, true) then
    return self:ReplaceInPlainText(message)
  end

  local parts = {} ---@type string[]
  local position = 1
  local length = #message
  while position <= length do
    local bar = message:find("|", position, true)
    if not bar then
      parts[#parts + 1] = self:ReplaceInPlainText(message:sub(position))
      break
    end
    if bar > position then
      parts[#parts + 1] = self:ReplaceInPlainText(message:sub(position, bar - 1))
    end

    local escapeEnd = bar -- a lone `|` at the end of the message
    for _, pattern in ipairs(ESCAPE_PATTERNS) do
      local _, patternEnd = message:find(pattern, bar)
      if patternEnd then
        escapeEnd = patternEnd
        break
      end
    end
    parts[#parts + 1] = message:sub(bar, escapeEnd)
    position = escapeEnd + 1
  end
  return table.concat(parts)
end

-- The client runs the filter once per chat frame which shows the message, so the last result is kept
local lastMessage, lastResult ---@type string|nil, string|nil

---Forgets the remembered result; called when an emoji is turned on or off, which changes the result.
function emojiChat:ResetCache()
  lastMessage, lastResult = nil, nil
end

---Event -> outcome -> number of filter calls, while the probe `emoji` runs; nil otherwise
---@type table<string, table<string, integer>>|nil
local probeCounts

---Counts one call of the chat filter for the probe `emoji`. It does nothing while no probe runs.
---@param event string
---@param outcome string "unreadable", "off", "unchanged", or "replaced"
local function note(event, outcome)
  if probeCounts then
    local counts = probeCounts[event] or {}
    probeCounts[event] = counts
    counts[outcome] = (counts[outcome] or 0) + 1
  end
end

---Chat message filter, see ChatFrameUtil.AddMessageEventFilter.
---@param _chatFrame table
---@param event string
---@param message string
---@param ... any Remaining arguments of the chat event
---@return boolean discard Always false: the message is shown
---@return string|nil message New text; nothing when the text is unchanged
---@return any ... Remaining arguments of the chat event, after a new text
local function chatFilter(_chatFrame, event, message, ...)
  -- A secret string cannot be searched or compared; it is shown as it came
  if issecretvalue(message) or type(message) ~= "string" then
    note(event, "unreadable")
    return false
  end
  -- `...` starts at the 2nd argument of the event, so its 6th value is the zone channel id
  local channel = channelOf(event, (select(6, ...)))
  if not channel or not emojiChat:IsChannelEnabled(channel) then
    note(event, "off")
    return false
  end
  if message ~= lastMessage then
    lastMessage = message
    lastResult = emojiChat:ReplaceEmoji(message)
  end
  if lastResult == message then
    note(event, "unchanged")
    return false
  end
  note(event, "replaced")
  return false, lastResult, ...
end

---The filter functions moved into ChatFrameUtil in the Mainline UI; the old globals are the fallback.
---Which of them Forever has is not verified, so both are probed.
---@param name string "AddMessageEventFilter" or "RemoveMessageEventFilter"
---@return function|nil
local function getFilterFunction(name)
  local util = _G.ChatFrameUtil
  return (util and util[name]) or _G["ChatFrame_" .. name]
end

---Adds or removes the chat filters. They are on every event of `CHANNELS`; the filter itself asks the
---setting of the kind of chat, so a changed setting needs no change here.
---@param wanted boolean
function emojiChat:SetFiltersInstalled(wanted)
  if wanted == self.filtersInstalled then
    return
  end
  local change = getFilterFunction(wanted and "AddMessageEventFilter" or "RemoveMessageEventFilter")
  if not change then
    return
  end
  for event in pairs(EVENT_CHANNELS) do
    change(event, chatFilter)
  end
  change(CHANNEL_EVENT, chatFilter)
  self.filtersInstalled = wanted
end

-- The emoji are on while the character is in the guild, and off outside it and while the guild is unknown
ns.guildState.RegisterCallback(emojiChat, "OnGuildStateChanged", function(_event, inGuild)
  emojiChat:SetFiltersInstalled(inGuild)
end)

--------------------------------------------------------------------------------
-- Probe: why a kind of chat shows no emoji
--------------------------------------------------------------------------------

---Seconds for which the probe `emoji` listens
local PROBE_SECONDS = 60
---Events that the probe watches beside those of `EVENT_CHANNELS`: a guild or officer line could also arrive
---as a message of the guild's community stream. Each is registered only when the client knows it.
local PROBE_EXTRA_EVENTS = { "CHAT_MSG_COMMUNITIES_CHANNEL", "CHAT_MSG_GUILD_ACHIEVEMENT" }

---Runs the probe `emoji` (`/oooo sync probe emoji`): for `PROBE_SECONDS` it counts the chat events that the
---client fires and what the emoji filter did with each, then reports both per event. A kind of chat whose
---lines arrive but never reach the filter, or reach it unreadable, shows in the difference. Reported by
---the user on 2026-11-21: officer chat shows no emoji although its setting is on.
---@param report OOOOProbeReport
function emojiChat:Probe(report)
  if probeCounts then
    report:Add("the probe runs already")
    return
  end
  local util = _G.ChatFrameUtil
  report:Add("filters installed: " .. tostring(self.filtersInstalled) .. "; ChatFrameUtil.AddMessageEventFilter: "
    .. type(util and util.AddMessageEventFilter) .. "; ChatFrame_AddMessageEventFilter: "
    .. type(_G.ChatFrame_AddMessageEventFilter))
  local settings = {}
  for _, channel in ipairs(self.CHANNELS) do
    settings[#settings + 1] = channel.key .. "=" .. tostring(self:IsChannelEnabled(channel.key))
  end
  report:Add("settings: " .. table.concat(settings, ", "))

  ---Event -> { lines, unreadable texts } as the client fired them
  local fired = {}
  local events = {}
  for event in pairs(EVENT_CHANNELS) do
    events[#events + 1] = event
  end
  for _, event in ipairs(PROBE_EXTRA_EVENTS) do
    events[#events + 1] = event
  end
  table.sort(events)
  local frame = CreateFrame("Frame")
  local invalid = {}
  for _, event in ipairs(events) do
    if C_EventUtils.IsEventValid(event) then
      frame:RegisterEvent(event)
    else
      invalid[#invalid + 1] = event
    end
  end
  if #invalid > 0 then
    report:Add("events that the client does not know: " .. table.concat(invalid, ", "))
  end
  frame:SetScript("OnEvent", function(_frame, event, message)
    local counts = fired[event] or { lines = 0, unreadable = 0 }
    fired[event] = counts
    counts.lines = counts.lines + 1
    if issecretvalue(message) or type(message) ~= "string" then
      counts.unreadable = counts.unreadable + 1
    end
  end)
  probeCounts = {}
  report:Add("listening for " .. PROBE_SECONDS .. " s: write a line with an emoji name in officer chat and one"
    .. " in guild chat now")
  C_Timer.After(PROBE_SECONDS, function()
    frame:UnregisterAllEvents()
    frame:SetScript("OnEvent", nil)
    local counted = probeCounts or {}
    probeCounts = nil
    for _, event in ipairs(events) do
      local lines, filter = fired[event], counted[event]
      if lines or filter then
        local outcomes = {}
        for _, outcome in ipairs({ "replaced", "unchanged", "off", "unreadable" }) do
          if filter and filter[outcome] then
            outcomes[#outcomes + 1] = outcome .. " " .. filter[outcome]
          end
        end
        -- The client calls the filter once per chat frame that shows the line, so the calls can be more
        report:Add(event .. ": fired " .. (lines and lines.lines or 0) .. " (unreadable text "
          .. (lines and lines.unreadable or 0) .. "); filter calls: "
          .. (#outcomes > 0 and table.concat(outcomes, ", ") or "none"))
      end
    end
    report:Add("RESULT: done; an event that fired with no filter call never reached the emoji filter")
  end)
end
