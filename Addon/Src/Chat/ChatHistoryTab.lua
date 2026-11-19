local addonName, ns = ...

-- The tab "Guild chat" of the addon window (.agents/00-plan.md, stage 11): the widgets over the model of
-- Chat/ChatHistory.lua, and the lists of mentions beside the lines.
--
-- The lines are in a ScrollingMessageFrame, which AceGUI-3.0 has no widget for: this file registers the
-- widget type "OOOOMessageLog" around one. `/oooo sync probe chatframe` reports what the client has of it.

---@class OOOOMentionList One list of mentions at the right side
---@field heading table AceGUI Heading with the title and the count
---@field scroll table AceGUI ScrollFrame with one InteractiveLabel per mention
---@field titleText string "Unread" or "Read"

---@class OOOOChatHistoryTab
---@field messages table|nil The ScrollingMessageFrame with the lines; nil while the tab is not shown
---@field shownCount integer Number of lines that `messages` holds
---@field maxLines integer Number of lines that `messages` can hold
---@field refreshPending boolean|nil true while a refresh waits for its timer
---@field unreadList OOOOMentionList|nil The list "Unread" at the right side
---@field readList OOOOMentionList|nil The list "Read" below it
---@field mentionsPending boolean|nil true while an update of the two lists waits for its timer
---@field tooltipShown boolean|nil true while the tooltip of a mention is shown
local tab = { shownCount = 0, maxLines = 0 }
ns.chatHistoryTab = tab

local history = ns.chatHistory
local AceGUI = LibStub("AceGUI-3.0")

---Id of the tab in the addon window
local TAB_ID = "chat"
---Width of the column at the right side with the lists of mentions
local SIDE_WIDTH = 210
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
---Lines below a line that the tab scrolls to, so that the line is not at the edge
local LINES_BELOW = 4
---Seconds for which changes of the table are collected before the lines are shown again
local REFRESH_DELAY = 0.2
---Most mentions that one list shows; its title counts all
local LIST_MAX = 100
---Texture under the mouse on a row of a list
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
---Hyperlinks that a click passes to the game: those that open a tooltip. The text of a line is untrusted,
---and a `player` link would open a whisper through a protected function.
local TOOLTIP_LINKS = { item = true, spell = true, enchant = true, quest = true, talent = true }

---Calls a method of a frame when the client has it.
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

--------------------------------------------------------------------------------
-- The widget type "OOOOMessageLog"
--------------------------------------------------------------------------------

local LOG_TYPE, LOG_VERSION = "OOOOMessageLog", 1

---Builds a message log: an AceGUI widget whose frame is a ScrollingMessageFrame. It fires "OnMouseWheel"
---(delta) and "OnHyperlinkClick" (link, text, button); the lines are written to `widget.frame`.
---@return table widget
local function createLog()
  local frame = CreateFrame("ScrollingMessageFrame", nil, UIParent)
  frame:Hide()
  frame:SetFontObject(GameFontHighlight)
  frame:SetJustifyH("LEFT")
  call(frame, "SetFading", false)
  call(frame, "SetIndentedWordWrap", true)
  call(frame, "SetHyperlinksEnabled", true)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(scrolled, delta)
    scrolled.obj:Fire("OnMouseWheel", delta)
  end)
  frame:SetScript("OnHyperlinkClick", function(clicked, link, text, button)
    clicked.obj:Fire("OnHyperlinkClick", link, text, button)
  end)
  local widget = {
    frame = frame,
    type = LOG_TYPE,
    OnAcquire = function(self)
      self.frame:Clear()
    end,
    OnRelease = function(self)
      self.frame:Clear()
    end,
  }
  return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(LOG_TYPE, createLog, LOG_VERSION)

--------------------------------------------------------------------------------
-- The lines
--------------------------------------------------------------------------------

---Handles a click on a hyperlink of a line as a chat frame does: `SetItemRef` shows the tooltip of the
---link, and puts the link into the chat edit box on a shift-click (through `HandleModifiedItemClick`).
---@param link string The link data: "item:4306:..."
---@param text string The link with its text
---@param button string Mouse button
function tab:OnHyperlinkClick(link, text, button)
  local setItemRef = _G.SetItemRef
  local linkType = type(link) == "string" and link:match("^(%a+):")
  if linkType and TOOLTIP_LINKS[linkType] and type(setItemRef) == "function" then
    setItemRef(link, text, button)
  end
end

---Scrolls the lines so that the message with an index, counted from the oldest, is the lowest visible one.
---@param index integer
function tab:ScrollToIndex(index)
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
function tab:Fill(offset)
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
function tab:ScrollOffset()
  local offset = call(self.messages, "GetScrollOffset")
  return type(offset) == "number" and offset or 0
end

---Loads the page before the first line and keeps the visible lines where they are.
function tab:LoadOlder()
  local offset = self:ScrollOffset()
  if history:LoadOlder() > 0 then
    -- The offset counts from the newest line, so it names the same line after older ones were added
    self:Fill(math.max(offset, 1))
  end
end

---Shows the lines again after the table changed. A reader who has scrolled up keeps their place.
function tab:Refresh()
  self.refreshPending = false
  if not self.messages then
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
function tab:ScheduleRefresh()
  if self.refreshPending then
    return
  end
  self.refreshPending = true
  C_Timer.After(REFRESH_DELAY, function()
    tab:Refresh()
  end)
end

---Scrolls to the line of a chat record and highlights it; older lines are loaded when the line is before
---the loaded ones.
---@param id string Id of a `guildchat` record
---@return boolean found false when the table does not hold the line
function tab:ShowLine(id)
  local index = history:Highlight(id)
  self:Fill()
  if index then
    self:ScrollToIndex(math.min(#history.lines, index + LINES_BELOW))
  end
  return index ~= nil
end

---Handles the mouse wheel over the lines. At the top, a step up loads the page before.
---@param delta number Positive: up
function tab:OnMouseWheel(delta)
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

---Hides the tooltip of a mention, when one is shown: its row is about to be released.
function tab:HideTooltip()
  if self.tooltipShown then
    self.tooltipShown = false
    GameTooltip:Hide()
  end
end

---Shows the tooltip of a mention: the sender, the time, and the line.
---@param owner table The frame of the row
---@param entry OOOOMention
function tab:ShowTooltip(owner, entry)
  local now = ns.sync.timeFn and ns.sync.timeFn() or 0
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:AddLine((entry.sender:gsub("|", "||")))
  GameTooltip:AddLine(history.formatTime(entry.time, now), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(ns.mentions.sanitize(entry.text), 1, 1, 1, true)
  GameTooltip:Show()
  self.tooltipShown = true
end

---Builds one list of mentions in the side column: a heading and a scrolling list that shares the height.
---@param side table The AceGUI group of the side column
---@param titleText string
---@return OOOOMentionList
local function createList(side, titleText)
  local heading = AceGUI:Create("Heading")
  heading:SetText(titleText)
  side:AddChild(heading)
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("List")
  scroll:SetUserData("fill", true)
  side:AddChild(scroll)
  return { heading = heading, scroll = scroll, titleText = titleText }
end

---Shows mentions in a list, newest first.
---@param list OOOOMentionList
---@param entries OOOOMention[]
local function fillList(list, entries)
  list.heading:SetText(list.titleText .. " (" .. #entries .. ")")
  local scroll = list.scroll
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  for index = 1, math.min(#entries, LIST_MAX) do
    local entry = entries[index]
    local row = AceGUI:Create("InteractiveLabel")
    row:SetFullWidth(true)
    -- The fragments are parts of the text outside its escape sequences, so they have no `|`
    row:SetText(table.concat(entry.fragments, " "))
    row:SetHighlight(ROW_HIGHLIGHT)
    row:SetCallback("OnClick", function()
      tab:OnMentionClick(entry)
    end)
    row:SetCallback("OnEnter", function(widget)
      tab:ShowTooltip(widget.frame, entry)
    end)
    row:SetCallback("OnLeave", function()
      tab:HideTooltip()
    end)
    scroll:AddChild(row)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

---Fills the two lists from the mentions of the user.
function tab:UpdateMentions()
  self.mentionsPending = false
  if not self.messages then
    return
  end
  self:HideTooltip()
  local unread, read = {}, {}
  for _, entry in ipairs(ns.mentions:List()) do
    local target = entry.isRead and read or unread
    target[#target + 1] = entry
  end
  fillList(self.unreadList, unread)
  fillList(self.readList, read)
end

---Asks for `UpdateMentions` after `REFRESH_DELAY`, so that a pull with many mentions fills the lists once.
function tab:ScheduleMentions()
  if self.mentionsPending or not self.messages then
    return
  end
  self.mentionsPending = true
  C_Timer.After(REFRESH_DELAY, function()
    tab:UpdateMentions()
  end)
end

---Handles a click on a mention: the history scrolls to its line and highlights it, and an unread mention
---becomes read. Nothing else makes a mention read.
---@param entry OOOOMention
function tab:OnMentionClick(entry)
  if not self:ShowLine(entry.id) then
    ns.print("The line of this mention is no longer stored.")
  end
  if not entry.isRead then
    -- The callback of the mention list fills the two lists again, after a delay: the clicked row is
    -- released then, not inside its own click
    ns.mentions:MarkRead(entry.id)
  end
end

ns.mentions.RegisterCallback(tab, "OnMentionsChanged", function()
  tab:ScheduleMentions()
end)

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

---Builds the content of the tab: the lines at the left, the two lists of mentions at the right.
---@param container table The AceGUI tab group
function tab:Build(container)
  history:Open()

  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOOColumns")
  root:SetAutoAdjustHeight(false)

  local log = AceGUI:Create(LOG_TYPE)
  log:SetCallback("OnMouseWheel", function(_widget, _event, delta)
    tab:OnMouseWheel(delta)
  end)
  log:SetCallback("OnHyperlinkClick", function(_widget, _event, link, text, button)
    tab:OnHyperlinkClick(link, text, button)
  end)
  root:AddChild(log)

  local side = AceGUI:Create("SimpleGroup")
  side:SetLayout("OOOORows")
  side:SetAutoAdjustHeight(false)
  side:SetUserData("width", SIDE_WIDTH)
  self.unreadList = createList(side, "Unread")
  self.readList = createList(side, "Read")
  root:AddChild(side)

  container:AddChild(root)
  root:DoLayout()

  self.messages = log.frame
  self.maxLines = MIN_MAX_LINES
  call(self.messages, "SetMaxLines", self.maxLines)
  self:Fill()
  self:UpdateMentions()
end

---Forgets the widgets, which the window releases, and the loaded lines.
function tab:Close()
  self:HideTooltip()
  self.messages, self.unreadList, self.readList = nil, nil, nil
  self.shownCount = 0
  history:Close()
end

---Shows the addon window with this tab.
---@return boolean opened false when the shared database is not ready
function tab:Open()
  return ns.mainWindow:Open(TAB_ID)
end

history.onChanged = function()
  if tab.messages then
    tab:ScheduleRefresh()
  end
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = "Guild chat",
  order = 10,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
})

--------------------------------------------------------------------------------
-- Probe
--------------------------------------------------------------------------------

---Methods of the ScrollingMessageFrame that the tab uses; the first five are needed, the others have a
---fallback
local WIDGET_METHODS = { "AddMessage", "Clear", "SetFontObject", "SetJustifyH", "EnableMouseWheel", "SetMaxLines",
  "SetFading", "SetIndentedWordWrap", "SetHyperlinksEnabled", "SetScrollOffset", "GetScrollOffset", "ScrollUp",
  "ScrollDown", "ScrollToBottom", "AtTop", "AtBottom", "GetNumMessages" }
---Globals that the tab and the notice look up
local PROBED_GLOBALS = { "SetItemRef", "HandleModifiedItemClick", "ItemRefTooltip", "UISpecialFrames", "date",
  "EventRegistry" }

ns.syncProbe.Register("chatframe", "chatframe - the widget and the globals of the chat history",
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
    report:Add("Not covered here: click an item link in the tab \"Guild chat\" of /oooo, then look for "
      .. "\"Interface action failed\" in the chat frame and in the taint log.")
  end)

---The data of the hyperlink that the probe `chatlink` prints
local PROBE_LINK = "addon:" .. addonName .. ":probe"
---true once the probe listens for its link
local probeLinkRegistered = false

ns.syncProbe.Register("chatlink", "chatlink - whether a click on an addon: hyperlink reaches the addon",
  function(report)
    local registry = ns.syncProbe.lookup("EventRegistry")
    if type(registry) ~= "table" or type(registry.RegisterCallback) ~= "function" then
      report:Add("EventRegistry.RegisterCallback is missing: the notice about mentions names /oooo")
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
