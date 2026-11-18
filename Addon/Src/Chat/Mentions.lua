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
