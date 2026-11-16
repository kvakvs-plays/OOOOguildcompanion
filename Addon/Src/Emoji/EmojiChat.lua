local addonName, ns = ...

---Shows emoji in guild, party, and raid chat: a word which is exactly an emoji name (case sensitive) is
---replaced by the texture of that emoji.
---@class OOOOEmojiChat AceAddon-3.0 module with AceEvent-3.0 mixed in
---@field RegisterEvent fun(self: OOOOEmojiChat, event: string, handler: string|function)
---@field filtersInstalled boolean true while the chat filters are registered
---@field escapes table<string, string>|nil Emoji name -> texture escape sequence; built on first use
local emojiChat = ns.addon:NewModule("EmojiChat", "AceEvent-3.0")
ns.emojiChat = emojiChat

local GUILD_NAME = "OO OO"

---Side of the emoji square in chat, in pixels
local CHAT_EMOJI_SIZE = 32

local CHAT_EVENTS = {
  "CHAT_MSG_GUILD",
  "CHAT_MSG_PARTY",
  "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID",
  "CHAT_MSG_RAID_LEADER",
}

---A word with an optional colon on each side, so that both `Kek` and `:Kek:` show the emoji. Bytes above 127
---are parts of UTF-8 letters: they belong to the word, which keeps an emoji name inside a non-English word
---from matching.
local WORD_PATTERN = "(:?)([%w_\128-\255]+)(:?)"

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

---@return table<string, string> escapes Emoji name -> texture escape sequence
function emojiChat:GetEscapes()
  if not self.escapes then
    local escapes = {} ---@type table<string, string>
    for _, emoji in ipairs(ns.emoji:GetAll()) do
      escapes[emoji.name] = "|T" .. emoji.texture .. ":" .. CHAT_EMOJI_SIZE .. ":" .. CHAT_EMOJI_SIZE .. "|t"
    end
    self.escapes = escapes
  end
  return self.escapes
end

---Replaces the emoji names in text which has no escape sequences.
---@param text string
---@return string
function emojiChat:ReplaceInPlainText(text)
  local escapes = self:GetEscapes()
  local replaced = text:gsub(WORD_PATTERN, function(before, word, after)
    local escape = escapes[word]
    if not escape or not ns.emoji:IsEnabled(word) then
      return nil -- gsub keeps the original text
    end
    if before == ":" and after == ":" then
      return escape
    end
    -- A single colon is punctuation ("Kek: nice"), not a part of the trigger
    return before .. escape .. after
  end)
  return replaced
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

---Turns the emoji on when the character is in the guild and off when it is not.
function emojiChat:UpdateGuildState()
  local guildName = IsInGuild() and GetGuildInfo("player")
  if guildName and issecretvalue(guildName) then
    return
  end
  -- The name is nil for some seconds after login; the filters then wait for the next guild event
  self:SetFiltersInstalled(guildName == GUILD_NAME)
end

---AceEvent handler of PLAYER_GUILD_UPDATE.
---@param _event string
---@param unit string|nil
function emojiChat:OnPlayerGuildUpdate(_event, unit)
  if unit == nil or unit == "player" then
    self:UpdateGuildState()
  end
end

---Called by AceAddon on PLAYER_LOGIN.
function emojiChat:OnEnable()
  self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnPlayerGuildUpdate")
  self:RegisterEvent("GUILD_ROSTER_UPDATE", "UpdateGuildState")
  self:UpdateGuildState()
end
