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

  -- The game hides and shows the window with the whole interface too, so the model follows the frame
  frame:SetScript("OnShow", function()
    history:Open()
    window:Fill()
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
    report:Add("after 40 messages: GetNumMessages " .. tostring(call(widget, "GetNumMessages")) .. ", offset "
      .. tostring(call(widget, "GetScrollOffset")) .. ", AtBottom " .. tostring(call(widget, "AtBottom")))
    call(widget, "SetScrollOffset", 10)
    report:Add("after SetScrollOffset(10): offset " .. tostring(call(widget, "GetScrollOffset")) .. ", AtTop "
      .. tostring(call(widget, "AtTop")) .. ", AtBottom " .. tostring(call(widget, "AtBottom")))
    call(widget, "SetScrollOffset", 1000)
    report:Add("after SetScrollOffset(1000): offset " .. tostring(call(widget, "GetScrollOffset")) .. ", AtTop "
      .. tostring(call(widget, "AtTop")))
    report:Add("Not covered here: click an item link in /oooo chat, then look for \"Interface action failed\" "
      .. "in the chat frame and in the taint log.")
  end)
