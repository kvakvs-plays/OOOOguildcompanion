local addonName, ns = ...

-- The model of the chat history window (.agents/00-plan.md, stage 11): which lines of the stored guild chat
-- are loaded, which one is highlighted, and the text of a line. It has no frames; the window is
-- Chat/ChatHistoryWindow.lua.
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_chathistory.lua).

---@class OOOOChatHistory
---@field lines OOOOGuildChatLine[] The loaded lines, oldest first; empty while the window is closed
---@field hasOlder boolean true when the table holds lines before the first loaded one
---@field isOpen boolean true while the window shows the history
---@field highlightId string|nil Id of the loaded line that is highlighted
---@field isDirty boolean|nil true when the table changed in a way that `Refresh` must read again
---@field onChanged (fun())|nil Called when the loaded lines may have changed; set by the window
local chatHistory = { lines = {}, hasOlder = false, isOpen = false }
ns.chatHistory = chatHistory

---Lines that the window opens with, and that one step back in time adds
chatHistory.PAGE = 100

---Colour of the time before a line
local TIME_COLOR = "|cff9d9d9d"

---Starts the history with the newest lines.
function chatHistory:Open()
  self.isOpen, self.isDirty, self.highlightId = true, false, nil
  self.lines, self.hasOlder = ns.guildChat:Page(nil, self.PAGE)
end

---Forgets the loaded lines.
function chatHistory:Close()
  self.isOpen, self.isDirty, self.highlightId = false, false, nil
  self.lines, self.hasOlder = {}, false
end

---Loads the page before the first loaded line.
---@return integer added Number of lines that were added at the start; 0 when the table has no more
function chatHistory:LoadOlder()
  if not self.isOpen or not self.hasOlder then
    return 0
  end
  local first = self.lines[1]
  local older, hasOlder = ns.guildChat:Page(first and first.id, self.PAGE)
  self.hasOlder = hasOlder
  local lines = older
  for _, line in ipairs(self.lines) do
    lines[#lines + 1] = line
  end
  local added = #lines - #self.lines
  self.lines = lines
  return added
end

---Finds the loaded line of a chat record. The record of a line that was written twice
---(`ns.guildChat.DUPLICATE_WINDOW`) is found at the line that is shown for both.
---@param id string Id of a `guildchat` record
---@return integer|nil index Position in `lines`; nil when the line is not loaded
function chatHistory:IndexOf(id)
  local lines = self.lines
  -- The last line whose id is not above `id`
  local low, high = 1, #lines + 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if lines[middle].id <= id then
      low = middle + 1
    else
      high = middle
    end
  end
  local index = low - 1
  if index < 1 then
    return nil
  end
  if lines[index].id == id then
    return index
  end
  local payload = ns.guildChat:Payload(id)
  local time = ns.versionId.parse(id)
  if not payload or not time then
    return nil
  end
  for position = index, 1, -1 do
    local line = lines[position]
    if time - line.time > ns.guildChat.DUPLICATE_WINDOW then
      break
    end
    if line.sender == payload.s and line.text == payload.t then
      return position
    end
  end
  return nil
end

---Loads older pages until the line of a chat record is loaded.
---@param id string Id of a `guildchat` record
---@return integer|nil index Position of its line in `lines`; nil when the table does not hold it
function chatHistory:LoadBackTo(id)
  while self.hasOlder and (not self.lines[1] or self.lines[1].id > id) do
    if self:LoadOlder() == 0 then
      break
    end
  end
  return self:IndexOf(id)
end

---Highlights the line of a chat record, and loads the history back to it first when it is older than the
---loaded lines.
---@param id string Id of a `guildchat` record
---@return integer|nil index Position of the line in `lines`; nil when the table does not hold it
function chatHistory:Highlight(id)
  local index = self:LoadBackTo(id)
  self.highlightId = index and self.lines[index].id or nil
  return index
end

---Follows the table while the window is open. A line that is newer than all loaded ones is added at the
---end. Every other change (a pull brings older lines of another origin, the expiry removes lines) is left
---to `Refresh`, because it can touch any place of the loaded lines.
---@param key string
---@param payload any nil when the record was removed
function chatHistory:OnRecordChanged(key, payload)
  if not self.isOpen then
    return
  end
  local lines = self.lines
  local last = lines[#lines]
  if payload ~= nil and not self.isDirty and (not last or key > last.id) then
    if ns.guildChat:Payload(key) ~= payload then
      return
    end
    local time = ns.versionId.parse(key) --[[@as integer]]
    local bySender = ns.sync.IsOriginOf ~= nil and ns.sync:IsOriginOf(payload.s, ns.versionId.originOf(key))
    for position = #lines, 1, -1 do
      local line = lines[position]
      if time - line.time > ns.guildChat.DUPLICATE_WINDOW then
        break
      end
      if line.sender == payload.s and line.text == payload.t then
        -- A second record of a line that is shown already
        line.bySender = line.bySender or bySender
        return
      end
    end
    lines[#lines + 1] = { id = key, time = time, sender = payload.s, text = payload.t, bySender = bySender }
  else
    self.isDirty = true
  end
  if self.onChanged then
    self.onChanged()
  end
end

---Reads the loaded lines again after a change that `OnRecordChanged` could not place: the newest lines, as
---many as were loaded.
---@return boolean reloaded false when nothing had to be read
function chatHistory:Refresh()
  if not self.isOpen or not self.isDirty then
    return false
  end
  self.isDirty = false
  self.lines, self.hasOlder = ns.guildChat:Page(nil, math.max(self.PAGE, #self.lines))
  if self.highlightId and not self:IndexOf(self.highlightId) then
    self.highlightId = nil
  end
  return true
end

---Formats the time of a line: hour and minute, and the day before them when the line is not of today.
---The game has the global `date`; the host has `os.date`.
---@param time integer Server time of the line
---@param now integer Server time
---@return string
function chatHistory.formatTime(time, now)
  local format = _G.date or (_G.os and _G.os.date)
  if not format then
    return "?"
  end
  if format("%Y%m%d", time) == format("%Y%m%d", now) then
    return format("%H:%M", time)
  end
  return format("%d.%m %H:%M", time)
end

---Builds the text of a line for the window: the time, the sender, and the text. The sender and the text
---are untrusted: in the sender every `|` is doubled, and the text keeps only its hyperlinks and colour codes
---(`ns.mentions.sanitize`). Emoji names are replaced like in chat.
---@param line OOOOGuildChatLine
---@param now integer Server time, for the form of the time
---@return string
function chatHistory:LineText(line, now)
  local text = ns.mentions.sanitize(line.text)
  -- EmojiChat.lua is not loaded on the host
  if ns.emojiChat then
    text = ns.emojiChat:ReplaceEmoji(text)
  end
  return TIME_COLOR .. "[" .. self.formatTime(line.time, now) .. "]|r " .. line.sender:gsub("|", "||") .. ": "
    .. text
end

ns.sync.RegisterCallback(chatHistory, "OnRecordChanged", function(_event, tableName, key, payload)
  if tableName == ns.guildChat.TABLE then
    chatHistory:OnRecordChanged(key, payload)
  end
end)
