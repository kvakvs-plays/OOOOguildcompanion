local addonName, ns = ...

---@class OOOOEmojiPhrase An alias which is not one plain word, like "gz kush"
---@field text string The alias: in lower case, or as written when `caseSensitive` is set
---@field name string Emoji name
---@field caseSensitive boolean true when chat must have the exact letter case

---Shows emoji in guild, party, and raid chat: a word which is exactly an emoji name or one of its aliases
---is replaced by the texture of that emoji. The letter case matters only for the emoji which
---EmojiOptions.lua marks as case sensitive.
---@class OOOOEmojiChat AceAddon-3.0 module
---@field filtersInstalled boolean true while the chat filters are registered
---@field escapes table<string, string>|nil Emoji name -> texture escape sequence; built on first use
---@field words table<string, string> Name or one-word alias in lower case -> emoji name; built together with `escapes`
---@field exactWords table<string, string> Name or one-word alias of a case sensitive emoji -> emoji name
---@field phrases table<string, OOOOEmojiPhrase[]> First word of an alias in lower case -> aliases, longest first
local emojiChat = ns.addon:NewModule("EmojiChat")
ns.emojiChat = emojiChat

---Side of the emoji square in chat, in pixels
local CHAT_EMOJI_SIZE = 32

local CHAT_EVENTS = {
  "CHAT_MSG_GUILD",
  "CHAT_MSG_PARTY",
  "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID",
  "CHAT_MSG_RAID_LEADER",
}

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

---Builds the lookup tables of the names and aliases.
function emojiChat:BuildLookup()
  local escapes = {} ---@type table<string, string>
  local words = {} ---@type table<string, string>
  local exactWords = {} ---@type table<string, string>
  local phrases = {} ---@type table<string, OOOOEmojiPhrase[]>
  local all = ns.emoji:GetAll()

  -- All names go in before any alias, so an alias can never take over the name of another emoji
  for _, emoji in ipairs(all) do
    escapes[emoji.name] = "|T" .. emoji.texture .. ":" .. CHAT_EMOJI_SIZE .. ":" .. CHAT_EMOJI_SIZE .. "|t"
    if emoji.caseSensitive then
      exactWords[emoji.name] = emoji.name
    else
      -- Of two names which differ only in case, the first in the list is the one that chat shows
      local key = emoji.name:lower()
      words[key] = words[key] or emoji.name
    end
  end
  for _, emoji in ipairs(all) do
    for _, originalAlias in ipairs(emoji.aliases) do
      local alias = emoji.caseSensitive and originalAlias or originalAlias:lower()
      local firstWord = alias:match(FIRST_WORD_PATTERN)
      if firstWord == alias then
        local target = emoji.caseSensitive and exactWords or words
        target[alias] = target[alias] or emoji.name
      elseif firstWord then
        local key = firstWord:lower()
        local list = phrases[key] or {}
        phrases[key] = list
        list[#list + 1] = { text = alias, name = emoji.name, caseSensitive = emoji.caseSensitive }
      end
      -- An alias which does not start with a word character can never be found and is skipped
    end
  end
  for _, list in pairs(phrases) do
    table.sort(list, function(a, b)
      return #a.text > #b.text
    end)
  end

  self.escapes, self.words, self.exactWords, self.phrases = escapes, words, exactWords, phrases
end

---Finds the emoji written at a word of the text: an alias of several words first, then a name or an alias
---of one word.
---@param text string
---@param lowerText string The text in lower case, for the emoji which match in any letter case
---@param wordStart integer Position of the first character of the word
---@param wordEnd integer Position of the last character of the word
---@return string|nil name Emoji name; nil when the word is not an emoji or the emoji is turned off
---@return integer|nil matchEnd Position of the last character of the match
function emojiChat:MatchAt(text, lowerText, wordStart, wordEnd)
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
        return phrase.name, phraseEnd
      end
    end
  end

  local name = self.exactWords[text:sub(wordStart, wordEnd)]
  if name and ns.emoji:IsEnabled(name) then
    return name, wordEnd
  end
  name = self.words[lowerWord]
  if name and ns.emoji:IsEnabled(name) then
    return name, wordEnd
  end
  return nil, nil
end

---Replaces the emoji names and aliases in text which has no escape sequences.
---@param text string
---@return string
function emojiChat:ReplaceInPlainText(text)
  if not self.escapes then
    self:BuildLookup()
  end

  -- string.lower changes only ASCII letters, so the positions in `lowerText` and `text` are the same
  local lowerText = text:lower()
  local parts ---@type string[]|nil
  local position = 1 -- the text before it is already in `parts`
  local searchFrom = 1
  while true do
    local wordStart, wordEnd = text:find(WORD_PATTERN, searchFrom)
    if not wordStart then
      break
    end
    local name, matchEnd = self:MatchAt(text, lowerText, wordStart, wordEnd)
    if name then
      local from, to = wordStart, matchEnd
      -- Colons on both sides belong to the emoji (":Kek:"); a single colon is punctuation ("Kek: nice")
      if from > position and text:sub(from - 1, from - 1) == ":" and text:sub(to + 1, to + 1) == ":" then
        from, to = from - 1, to + 1
      end
      parts = parts or {}
      parts[#parts + 1] = text:sub(position, from - 1)
      parts[#parts + 1] = self.escapes[name]
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

---Replaces every word which is an enabled emoji name with the texture of the emoji. Hyperlinks, textures,
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

---Chat message filter, see ChatFrameUtil.AddMessageEventFilter.
---@param _chatFrame table
---@param _event string
---@param message string
---@param ... any Remaining arguments of the chat event
---@return boolean discard Always false: the message is shown
---@return string|nil message New text; nothing when the text is unchanged
---@return any ... Remaining arguments of the chat event, after a new text
local function chatFilter(_chatFrame, _event, message, ...)
  -- A secret string cannot be searched or compared; it is shown as it came
  if issecretvalue(message) or type(message) ~= "string" then
    return false
  end
  if message ~= lastMessage then
    lastMessage = message
    lastResult = emojiChat:ReplaceEmoji(message)
  end
  if lastResult == message then
    return false
  end
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

---Adds or removes the chat filters.
---@param wanted boolean
function emojiChat:SetFiltersInstalled(wanted)
  if wanted == self.filtersInstalled then
    return
  end
  local change = getFilterFunction(wanted and "AddMessageEventFilter" or "RemoveMessageEventFilter")
  if not change then
    return
  end
  for _, event in ipairs(CHAT_EVENTS) do
    change(event, chatFilter)
  end
  self.filtersInstalled = wanted
end

-- The emoji are on while the character is in the guild, and off outside it and while the guild is unknown
ns.guildState.RegisterCallback(emojiChat, "OnGuildStateChanged", function(_event, inGuild)
  emojiChat:SetFiltersInstalled(inGuild)
end)
