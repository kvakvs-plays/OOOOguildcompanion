local addonName, ns = ...

-- The window "Guild chat history" (.agents/00-plan.md, stage 11): the frames over the model of
-- Chat/ChatHistory.lua. `/oooo chat` opens and closes it.
--
-- The frame is not protected, so it may be shown, hidden, and moved in combat.
--
-- Not checked on Forever when this was written: the widget ScrollingMessageFrame with its methods, and the
-- globals SetItemRef and UISpecialFrames. Each is looked up before it is used, and `/oooo sync probe
-- chatframe` reports what the client has.

---@class OOOOChatHistorySettings `db.profile.chatHistory`: where the user left the window
---@field point string|nil Anchor point of the window; nil until the window was moved
---@field relativePoint string|nil Anchor point of the screen
---@field x number|nil
---@field y number|nil

---@class OOOOChatHistoryWindow
---@field frame table|nil The window; nil until it is first opened
---@field messages table|nil The ScrollingMessageFrame with the lines
---@field shownCount integer Number of lines that `messages` holds
---@field maxLines integer Number of lines that `messages` can hold
---@field refreshPending boolean|nil true while a refresh waits for its timer
---@field unreadList OOOOMentionListWidget The list "Unread" at the right side
---@field readList OOOOMentionListWidget The list "Read" below it
---@field mentionsPending boolean|nil true while an update of the two lists waits for its timer
local window = { shownCount = 0 }
ns.chatHistoryWindow = window

local history = ns.chatHistory

---Global name of the frame: the game closes the frames of `UISpecialFrames` with Escape, by name
local FRAME_NAME = "OOOOChatHistoryFrame"
local WINDOW_TITLE = "Guild chat history"
local WIDTH, HEIGHT = 760, 440
---Space at the right side for the lists of mentions
local SIDE_WIDTH = 180
local PADDING = 10
local HEADER_HEIGHT = 30
---Colour of a line: the green of the guild chat
local LINE_COLOR = { 0.25, 1, 0.25 }
---Colour of the highlighted line
local HIGHLIGHT_COLOR = { 1, 0.82, 0 }
---Mark before the highlighted line
local HIGHLIGHT_MARK = ">> "
---Messages that one step of the mouse wheel scrolls
local WHEEL_STEP = 3
---Lines that the widget keeps at least; it is raised when more are loaded
local MIN_MAX_LINES = 500
---Lines below a line that the window scrolls to, so that the line is not at the edge
local LINES_BELOW = 4
---Seconds for which changes of the table are collected before the lines are shown again
local REFRESH_DELAY = 0.2
---Height of the title of a list of mentions, and of one of its rows
local LIST_TITLE_HEIGHT, ROW_HEIGHT = 18, 16
---Anchor points that a saved position may name
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }
---Hyperlinks that a click passes to the game: those that open a tooltip. The text of a line is untrusted,
---and a `player` link would open a whisper through a protected function.
local TOOLTIP_LINKS = { item = true, spell = true, enchant = true, quest = true, talent = true }

---Calls a method of a widget when the client has it.
---@param widget table
---@param method string
---@param ... any Arguments of the method
---@return any ... What the method returned; nothing when it is missing
local function call(widget, method, ...)
  local fn = widget[method]
  if type(fn) == "function" then
    return fn(widget, ...)
  end
end

---Stores where the user left the window.
---@param frame table
local function savePosition(frame)
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  local settings = ns.db.profile.chatHistory
  settings.point, settings.relativePoint, settings.x, settings.y = point, relativePoint, x, y
end

---Puts the window where the user left it, or in the middle of the screen.
---@param frame table
local function restorePosition(frame)
  local settings = ns.db.profile.chatHistory
  frame:ClearAllPoints()
  if POINTS[settings.point] and POINTS[settings.relativePoint] and type(settings.x) == "number"
    and type(settings.y) == "number" then
    frame:SetPoint(settings.point, UIParent, settings.relativePoint, settings.x, settings.y)
  else
    frame:SetPoint("CENTER")
  end
end

---Handles a click on a hyperlink of a line as a chat frame does: `SetItemRef` shows the tooltip of the
---link, and puts the link into the chat edit box on a shift-click (through `HandleModifiedItemClick`).
---@param link string The link data: "item:4306:..."
---@param text string The link with its text
---@param button string Mouse button
function window:OnHyperlinkClick(link, text, button)
  local setItemRef = _G.SetItemRef
  local linkType = type(link) == "string" and link:match("^(%a+):")
  if linkType and TOOLTIP_LINKS[linkType] and type(setItemRef) == "function" then
    setItemRef(link, text, button)
  end
end

---Scrolls the lines so that the message with an index, counted from the oldest, is the lowest visible one.
---@param index integer
function window:ScrollToIndex(index)
  local messages = self.messages
  local offset = math.max(0, self.shownCount - index)
  if type(messages.SetScrollOffset) == "function" then
    messages:SetScrollOffset(offset)
  else
    -- Without it: from the bottom, one message up per step
    call(messages, "ScrollToBottom")
    for _ = 1, offset do
      call(messages, "ScrollUp")
    end
  end
end

---Shows the loaded lines of the model again.
---@param offset integer|nil Messages between the lowest visible one and the newest one, as
---`GetScrollOffset` counts; nil or 0 scrolls to the bottom
function window:Fill(offset)
  local messages = self.messages
  local lines = history.lines
  local now = ns.sync.timeFn and ns.sync.timeFn() or 0
  if #lines + 100 > self.maxLines then
    self.maxLines = #lines + MIN_MAX_LINES
    call(messages, "SetMaxLines", self.maxLines)
  end
  messages:Clear()
  for _, line in ipairs(lines) do
    local text = history:LineText(line, now)
    if line.id == history.highlightId then
      messages:AddMessage(HIGHLIGHT_MARK .. text, HIGHLIGHT_COLOR[1], HIGHLIGHT_COLOR[2], HIGHLIGHT_COLOR[3])
    else
      messages:AddMessage(text, LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3])
    end
  end
  self.shownCount = #lines
  if offset and offset > 0 then
    self:ScrollToIndex(#lines - offset)
  else
    call(messages, "ScrollToBottom")
  end
end

---Returns how far the lines are scrolled up, in messages; 0 at the bottom.
---@return integer
function window:ScrollOffset()
  local offset = call(self.messages, "GetScrollOffset")
  return type(offset) == "number" and offset or 0
end

---Loads the page before the first line and keeps the visible lines where they are.
function window:LoadOlder()
  local offset = self:ScrollOffset()
  if history:LoadOlder() > 0 then
    -- The offset counts from the newest line, so it names the same line after older ones were added
    self:Fill(math.max(offset, 1))
  end
end

---Shows the lines again after the table changed. A reader who has scrolled up keeps their place.
function window:Refresh()
  self.refreshPending = false
  if not self.frame or not self.frame:IsShown() then
    return
  end
  local before = self.shownCount
  history:Refresh()
  local offset = self:ScrollOffset()
  if offset > 0 then
    offset = offset + math.max(0, #history.lines - before)
  end
  self:Fill(offset)
end

---Asks for a refresh after `REFRESH_DELAY`, so that a pull of many records shows the lines once.
function window:ScheduleRefresh()
  if self.refreshPending then
    return
  end
  self.refreshPending = true
  C_Timer.After(REFRESH_DELAY, function()
    window:Refresh()
  end)
end

---Scrolls to the line of a chat record and highlights it; older lines are loaded when the line is before
---the loaded ones.
---@param id string Id of a `guildchat` record
---@return boolean found false when the table does not hold the line
function window:ShowLine(id)
  local index = history:Highlight(id)
  self:Fill()
  if index then
    self:ScrollToIndex(math.min(#history.lines, index + LINES_BELOW))
  end
  return index ~= nil
end

---Handles the mouse wheel over the lines. At the top, a step up loads the page before.
---@param delta number Positive: up
function window:OnMouseWheel(delta)
  local messages = self.messages
  if delta > 0 then
    if history.hasOlder and call(messages, "AtTop") then
      self:LoadOlder()
    end
    for _ = 1, WHEEL_STEP do
      call(messages, "ScrollUp")
    end
  else
    for _ = 1, WHEEL_STEP do
      call(messages, "ScrollDown")
    end
  end
end

--------------------------------------------------------------------------------
-- The lists of mentions (plan step 11.4)
--------------------------------------------------------------------------------

---@class OOOOMentionListWidget One list of mentions at the right side: a title and rows that the mouse
---wheel scrolls
---@field frame table
---@field title table FontString
---@field titleText string "Unread" or "Read"
---@field rows table[] The row buttons, top first; each has `label` and, while it shows one, `entry`
---@field entries OOOOMention[] What the list holds, newest first
---@field offset integer Number of entries above the first row

---Shows the entries of a list from its scroll offset on.
---@param list OOOOMentionListWidget
local function updateList(list)
  local entries = list.entries
  list.offset = math.max(0, math.min(list.offset, #entries - #list.rows))
  list.title:SetText(list.titleText .. " (" .. #entries .. ")")
  for index, row in ipairs(list.rows) do
    local entry = entries[list.offset + index]
    row.entry = entry
    if entry then
      -- The fragments are parts of the text outside its escape sequences, so they have no `|`
      row.label:SetText(table.concat(entry.fragments, " "))
      row:Show()
    else
      row:Hide()
    end
  end
end

---Shows the tooltip of a mention: the sender, the time, and the line.
---@param row table A row button with `entry`
local function showMentionTooltip(row)
  local entry = row.entry ---@type OOOOMention|nil
  if not entry then
    return
  end
  local now = ns.sync.timeFn and ns.sync.timeFn() or 0
  GameTooltip:SetOwner(row, "ANCHOR_LEFT")
  GameTooltip:AddLine((entry.sender:gsub("|", "||")))
  GameTooltip:AddLine(history.formatTime(entry.time, now), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(ns.mentions.sanitize(entry.text), 1, 1, 1, true)
  GameTooltip:Show()
end

---Builds one list of mentions.
---@param parent table The window
---@param titleText string
---@param height number
---@return OOOOMentionListWidget
local function createList(parent, titleText, height)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(SIDE_WIDTH, height)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT")
  ---@type OOOOMentionListWidget
  local list = { frame = frame, title = title, titleText = titleText, rows = {}, entries = {}, offset = 0 }
  for index = 1, math.floor((height - LIST_TITLE_HEIGHT) / ROW_HEIGHT) do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(SIDE_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(LIST_TITLE_HEIGHT + (index - 1) * ROW_HEIGHT))
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 6, 0)
    label:SetPoint("RIGHT", -2, 0)
    label:SetJustifyH("LEFT")
    call(label, "SetWordWrap", false)
    row.label = label
    row:SetScript("OnClick", function(clicked)
      if clicked.entry then
        window:OnMentionClick(clicked.entry)
      end
    end)
    row:SetScript("OnEnter", showMentionTooltip)
    row:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    list.rows[index] = row
  end
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_frame, delta)
    list.offset = list.offset - delta
    updateList(list)
  end)
  return list
end

---Fills the two lists from the mentions of the user.
function window:UpdateMentions()
  self.mentionsPending = false
  if not self.frame or not self.frame:IsShown() then
    return
  end
  local unread, read = {}, {}
  for _, entry in ipairs(ns.mentions:List()) do
    local target = entry.isRead and read or unread
    target[#target + 1] = entry
  end
  self.unreadList.entries, self.readList.entries = unread, read
  updateList(self.unreadList)
  updateList(self.readList)
end

---Asks for `UpdateMentions` after `REFRESH_DELAY`, so that a pull with many mentions fills the lists once.
function window:ScheduleMentions()
  if self.mentionsPending or not self.frame or not self.frame:IsShown() then
    return
  end
  self.mentionsPending = true
  C_Timer.After(REFRESH_DELAY, function()
    window:UpdateMentions()
  end)
end

---Handles a click on a mention: the history scrolls to its line and highlights it, and an unread mention
---becomes read. Nothing else makes a mention read.
---@param entry OOOOMention
function window:OnMentionClick(entry)
  if not self:ShowLine(entry.id) then
    ns.print("The line of this mention is no longer stored.")
  end
  if not entry.isRead then
    -- The callback of the mention list fills the two lists again
    ns.mentions:MarkRead(entry.id)
  end
end

ns.mentions.RegisterCallback(window, "OnMentionsChanged", function()
  window:ScheduleMentions()
end)

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---Builds the frames of the window.
---@return table frame
function window:Create()
  local frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
  self.frame = frame
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  frame:SetBackdropColor(0, 0, 0, 0.9)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(moved)
    moved:StopMovingOrSizing()
    savePosition(moved)
  end)
  frame:Hide()
  restorePosition(frame)

  local logo = frame:CreateTexture(nil, "ARTWORK")
  logo:SetSize(20, 20)
  logo:SetPoint("TOPLEFT", PADDING, -6)
  logo:SetTexture("Interface\\AddOns\\" .. addonName .. "\\Icons\\Logo64.png")
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", logo, "RIGHT", 6, 0)
  title:SetText(WINDOW_TITLE)

  local close = CreateFrame("Button", nil, frame)
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", -6, -6)
  local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  closeText:SetAllPoints()
  closeText:SetText("X")
  close:SetScript("OnClick", function()
    frame:Hide()
  end)

  local messages = CreateFrame("ScrollingMessageFrame", nil, frame)
  self.messages = messages
  messages:SetPoint("TOPLEFT", PADDING, -HEADER_HEIGHT)
  messages:SetPoint("BOTTOMRIGHT", -(SIDE_WIDTH + 2 * PADDING), PADDING)
  messages:SetFontObject(GameFontHighlight)
  messages:SetJustifyH("LEFT")
  call(messages, "SetFading", false)
  call(messages, "SetIndentedWordWrap", true)
  call(messages, "SetHyperlinksEnabled", true)
  self.maxLines = MIN_MAX_LINES
  call(messages, "SetMaxLines", self.maxLines)
  messages:EnableMouseWheel(true)
  messages:SetScript("OnMouseWheel", function(_messages, delta)
    window:OnMouseWheel(delta)
  end)
  messages:SetScript("OnHyperlinkClick", function(_messages, link, text, button)
    window:OnHyperlinkClick(link, text, button)
  end)

  local listHeight = (HEIGHT - HEADER_HEIGHT - 2 * PADDING) / 2
  self.unreadList = createList(frame, "Unread", listHeight)
  self.unreadList.frame:SetPoint("TOPRIGHT", -PADDING, -HEADER_HEIGHT)
  self.readList = createList(frame, "Read", listHeight)
  self.readList.frame:SetPoint("TOPRIGHT", self.unreadList.frame, "BOTTOMRIGHT", 0, -PADDING)

  -- The game hides and shows the window with the whole interface too, so the model follows the frame
  frame:SetScript("OnShow", function()
    history:Open()
    window:Fill()
    window:UpdateMentions()
  end)
  frame:SetScript("OnHide", function()
    history:Close()
  end)

  -- Escape closes the frames that this list names
  local special = _G.UISpecialFrames
  if type(special) == "table" then
    special[#special + 1] = FRAME_NAME
  end
  return frame
end

---Shows the window with the newest lines of the stored guild chat.
---@return boolean opened false when the shared database is not ready
function window:Open()
  if not ns.sync.data then
    ns.print("The shared database is not ready.")
    return false
  end
  local frame = self.frame or self:Create()
  frame:Show()
  return true
end

---Opens the window, or closes it when it is open.
function window:Toggle()
  if self.frame and self.frame:IsShown() then
    self.frame:Hide()
  else
    self:Open()
  end
end

history.onChanged = function()
  window:ScheduleRefresh()
end

ns.slash:Register("chat", "chat - open or close the guild chat history", function()
  window:Toggle()
end)

--------------------------------------------------------------------------------
-- Probe
--------------------------------------------------------------------------------

---Methods of the ScrollingMessageFrame that the window uses; the first five are needed, the others have a
---fallback
local WIDGET_METHODS = { "AddMessage", "Clear", "SetFontObject", "SetJustifyH", "EnableMouseWheel", "SetMaxLines",
  "SetFading", "SetIndentedWordWrap", "SetHyperlinksEnabled", "SetScrollOffset", "GetScrollOffset", "ScrollUp",
  "ScrollDown", "ScrollToBottom", "AtTop", "AtBottom", "GetNumMessages" }
---Globals that the window and the notice look up
local PROBED_GLOBALS = { "SetItemRef", "HandleModifiedItemClick", "ItemRefTooltip", "UISpecialFrames", "date",
  "EventRegistry" }

ns.syncProbe.Register("chatframe", "chatframe - the widget and the globals of the chat history window",
  function(report)
    local lookup = ns.syncProbe.lookup
    for _, name in ipairs(PROBED_GLOBALS) do
      report:Add("global " .. name .. ": " .. type(lookup(name)))
    end
    local created, widget = pcall(CreateFrame, "ScrollingMessageFrame", nil, UIParent)
    if not created then
      report:Add("CreateFrame(\"ScrollingMessageFrame\") failed: " .. tostring(widget))
      return
    end
    widget:Hide()
    local missing = {}
    for _, method in ipairs(WIDGET_METHODS) do
      if type(widget[method]) ~= "function" then
        missing[#missing + 1] = method
      end
    end
    report:Add("ScrollingMessageFrame created; missing methods: " .. (#missing > 0 and table.concat(missing, ", ")
      or "none"))
    widget:SetSize(300, 60)
    widget:SetFontObject(GameFontHighlight)
    call(widget, "SetMaxLines", 100)
    for index = 1, 40 do
      widget:AddMessage("probe line " .. index)
    end
    report:Add("after 40 messages: GetNumMessages " .. tostring((call(widget, "GetNumMessages"))) .. ", offset "
      .. tostring((call(widget, "GetScrollOffset"))) .. ", AtBottom " .. tostring((call(widget, "AtBottom"))))
    call(widget, "SetScrollOffset", 10)
    report:Add("after SetScrollOffset(10): offset " .. tostring((call(widget, "GetScrollOffset"))) .. ", AtTop "
      .. tostring((call(widget, "AtTop"))) .. ", AtBottom " .. tostring((call(widget, "AtBottom"))))
    call(widget, "SetScrollOffset", 1000)
    report:Add("after SetScrollOffset(1000): offset " .. tostring((call(widget, "GetScrollOffset"))) .. ", AtTop "
      .. tostring((call(widget, "AtTop"))))
    report:Add("Not covered here: click an item link in /oooo chat, then look for \"Interface action failed\" "
      .. "in the chat frame and in the taint log.")
  end)

---The data of the hyperlink that the probe `chatlink` prints
local PROBE_LINK = "addon:" .. addonName .. ":probe"
---true once the probe listens for its link
local probeLinkRegistered = false

ns.syncProbe.Register("chatlink", "chatlink - whether a click on an addon: hyperlink reaches the addon",
  function(report)
    local registry = ns.syncProbe.lookup("EventRegistry")
    if type(registry) ~= "table" or type(registry.RegisterCallback) ~= "function" then
      report:Add("EventRegistry.RegisterCallback is missing: the notice about mentions names /oooo chat")
      return
    end
    if not probeLinkRegistered then
      probeLinkRegistered = true
      registry:RegisterCallback("SetItemRef", function(...)
        local values = {}
        local isProbe = false
        for index = 1, select("#", ...) do
          local value = select(index, ...)
          local secret = issecretvalue(value)
          isProbe = isProbe or (not secret and value == PROBE_LINK)
          values[index] = secret and "<secret>" or type(value) .. " " .. tostring(value)
        end
        if isProbe then
          report:Add("the click arrived; arguments of the callback: " .. table.concat(values, " | "))
        end
      end, PROBE_LINK)
    end
    report:Add("EventRegistry is present and the callback is registered. Click the link in the next line; "
      .. "a result line follows when the click reaches the addon.")
    -- Printed without the probe prefix, which doubles every `|`
    ns.print("|cff71d5ff|H" .. PROBE_LINK .. "|h[Click this probe link]|h|r")
  end)
