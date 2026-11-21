local addonName, ns = ...

-- The tab "Gambling" of the addon window (.agents/00-plan.md, sections 15.4 and 15.7, step 15.1): AceGUI-3.0
-- widgets over the model of Gamble/Gamble.lua (`ns.gamble.current`). At the left the events in four groups, at
-- the right the detail of the selected event: for an open event a stake box per outcome, "Place bet", "Take
-- back", and the state of the own bet; for a locked event the same rows read-only with the booked sums.
--
-- Refresh: changes of the two gamble tables are collected for `REFRESH_DELAY` seconds, and a slow timer
-- (`TICK`) moves the "in 2 h" text and the events whose close has passed. The list is built again on every
-- refresh. The detail is built again only when what it shows changed (`detailSignature`): the time line and
-- the state of the own bet are updated in place, so a box keeps its focus and its text while the user types,
-- also when the bet is accepted meanwhile. When the detail is built again, the typed texts of the boxes are
-- kept (`typed`) until the bet is placed or taken back, or the tab is closed.
--
-- It calls no protected function and names no frame. Only the AceGUI widgets that the other tabs use.

---@class OOOOGambleTabRow One event of the list
---@field label table AceGUI InteractiveLabel
---@field entry OOOOGambleListEntry
---@field group string Key of its group in `OOOOGambleGroups`

---@class OOOOGambleTabMessage The answer to the last click on "Place bet" or "Take back"
---@field eventId string The event that it belongs to
---@field text string
---@field error boolean|nil true for a refusal

---@class OOOOGambleTab
---@field model OOOOGamble|nil The gambling model; nil while the tab is not shown
---@field list table|nil AceGUI ScrollFrame with the events; nil while the tab is not shown
---@field detail table|nil AceGUI ScrollFrame with the detail of the selected event
---@field selectedId string|nil The event that the detail shows
---@field rows table<string, OOOOGambleTabRow> Event id -> its row in the list
---@field signature string|nil What the built detail shows (`detailSignature`); nil forces a rebuild
---@field boxes table[] Outcome index -> the AceGUI EditBox of the own stake (open event only)
---@field winLabels table[] Outcome index -> the label with the highest possible win under the box
---@field timeLabel table|nil The label with the close of the event, updated in place
---@field stateLabel table|nil The label with the state of the own bet, updated in place
---@field messageLabel table|nil The label with the answer to the last click, updated in place
---@field typed table<string, table<integer, string>> Event id -> outcome index -> text that the user typed
---@field message OOOOGambleTabMessage|nil
---@field token integer Counts the builds and closes, so that a timer of an earlier build does nothing
---@field refreshPending boolean|nil true while a refresh waits for its timer
local tab = { rows = {}, boxes = {}, winLabels = {}, typed = {}, token = 0 }
ns.gambleTab = tab

local AceGUI = LibStub("AceGUI-3.0")

---Id of the tab in the addon window
local TAB_ID = "gamble"
---Width of the list at the left side
local LIST_WIDTH = 260
---Seconds for which changes of the tables are collected before the tab is refreshed
local REFRESH_DELAY = 0.5
---Seconds between two refreshes of the time texts and of the groups while the tab is shown
local TICK = 20
---Width of the text before a stake box, of the box, and of a button
local STAKE_LABEL_WIDTH, BOX_WIDTH, BUTTON_WIDTH = 80, 90, 130
---Most digits that a stake box takes: more than the highest stake (`ns.gambleData.MAX_GOLD`) has
local MAX_DIGITS = 6
---Events closer than this to now show the weekday and the time only
local NEAR_SECONDS = 6 * 86400
---Tolerance that keeps a claim of an exact whole number from falling below it before it is rounded down, as
---in GambleSettle.lua
local EPSILON = 1e-9
---Texture under the mouse on a row
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
---Background of the selected row: silver, with its alpha
local SELECTION_COLOR = { 0.75, 0.75, 0.75, 0.25 }
---Colour codes of the texts
local TITLE_COLOR, GREY, SELECTED_COLOR = "|cffffd100", "|cff808080", "|cff40ff40"
---Colour codes of a good state, of a waiting state, and of a refusal
local GOOD_COLOR, WAIT_COLOR, BAD_COLOR = "|cff40ff40", "|cffffd100", "|cffff6060"

---The groups of the list in their order, with their headings
---@type { key: string, title: string }[]
local GROUPS = {
  { key = "open", title = "Open" },
  { key = "waiting", title = "Waiting for the result" },
  { key = "toPay", title = "To pay" },
  { key = "done", title = "Done" },
}

---Why bets count only when an officer is online (15.4)
local OFFICER_NOTE = "A bet counts only when an officer with the addon is online and receives it before the "
  .. "close. Place your bet early."
---Shown in the list when no event is held
local LIST_HINT = "No event yet. An officer opens one."
---Shown in the detail part when no event is selected
local DETAIL_HINT = "Click an event to see it."
---Shown in place of the tab when `ns.gamble.current` does not exist yet
local NOT_READY = "The gambling data is not loaded yet. Open the tab again in a few seconds."

---Refusal reasons of the model and of the engine -> the line that the tab shows. `%d` is the highest stake.
---@type table<string, string>
local REFUSALS = {
  ["not ready"] = "Your character is not known yet. Try again in a few seconds.",
  ["unknown event"] = "This event is not known any more.",
  closed = "The event is closed. Bets are no longer taken.",
  resolved = "The event is resolved. Bets are no longer taken.",
  cancelled = "The event is cancelled. Bets are no longer taken.",
  ["bad stakes"] = "The stakes could not be read.",
  ["bad outcome"] = "A stake names an outcome that the event does not have.",
  ["bad stake"] = "Every stake must be a whole number of gold.",
  ["stake too high"] = "A stake is over the highest stake of %d gold.",
  ["no bet"] = "You have no bet on this event.",
  ["unknown table"] = "The gambling data is not loaded yet. Try again in a few seconds.",
  ["bad key"] = "Your character name does not fit the shared database.",
  ["not the owner"] = "The bet could not be saved under your character.",
  ["bad payload"] = "The bet does not fit the rules of the shared database.",
  ["too large"] = "The bet is too large for the shared database.",
}

--------------------------------------------------------------------------------
-- Texts
--------------------------------------------------------------------------------

---Formats a server time as a day and a time: "Fri 20:00", with the date when it is not near.
---@param time integer Server time
---@param now integer Server time
---@return string
local function dayTime(time, now)
  -- The game has the global `date` (AGENTS.md); it is looked up, as in ChatHistory.lua
  local format = _G.date
  if type(format) ~= "function" then
    return "?"
  end
  if math.abs(time - now) < NEAR_SECONDS then
    return format("%a %H:%M", time)
  end
  return format("%a %d.%m %H:%M", time)
end

---Formats a span of time: "45 min", "2 h 10 min", "3 days 4 h".
---@param seconds number
---@return string
local function duration(seconds)
  if seconds < 60 then
    return "less than a minute"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. " min"
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    local rest = minutes % 60
    return hours .. " h" .. (rest > 0 and (" " .. rest .. " min") or "")
  end
  local days = math.floor(hours / 24)
  local rest = hours % 24
  return days .. (days == 1 and " day" or " days") .. (rest > 0 and (" " .. rest .. " h") or "")
end

---Builds the line with the close of an event and who opened it.
---@param detail OOOOGambleDetail
---@param now integer Server time
---@return string
local function timeText(detail, now)
  local by = "Opened by " .. detail.by .. "."
  if detail.state == "open" then
    return "Open until " .. dayTime(detail.close, now) .. " (in " .. duration(detail.close - now) .. "). " .. by
  end
  return "Closed " .. dayTime(detail.close, now) .. ". " .. by
end

---Builds the line of the second row of an event in the list.
---@param entry OOOOGambleListEntry
---@param group string Key of its group
---@param now integer Server time
---@return string
local function subline(entry, group, now)
  if group == "open" then
    return "until " .. dayTime(entry.event.c, now)
  elseif group == "waiting" then
    return "closed " .. dayTime(entry.event.c, now)
  elseif group == "toPay" then
    return "resolved, not all paid"
  elseif entry.event.s == ns.gambleData.STATE_CANCELLED then
    return "cancelled"
  end
  return "resolved, all paid"
end

---Builds the text of a row of the list: the title of the event and below it its state.
---@param model OOOOGamble
---@param row OOOOGambleTabRow
---@param selected boolean true for the event that the detail shows
---@param now integer Server time
---@return string
local function rowText(model, row, selected, now)
  return (selected and SELECTED_COLOR or TITLE_COLOR) .. model.sanitize(row.entry.event.n) .. "|r\n" .. GREY
    .. subline(row.entry, row.group, now) .. "|r"
end

---Builds the first line of an outcome: its name, its chance, the booked sum after the close, and the cap.
---@param outcome OOOOGambleDetailOutcome
---@return string
local function outcomeText(outcome)
  local text = TITLE_COLOR .. outcome.n .. "|r   " .. outcome.p .. "%"
  if outcome.booked then
    text = text .. "   booked " .. outcome.booked
  end
  if outcome.x then
    text = text .. "   " .. GREY .. "payout capped at " .. outcome.x .. " times the stake|r"
  end
  return text
end

---Lists stakes by the names of their outcomes: "30 on Nota, 10 on Other".
---@param stakes table<integer, integer>
---@param outcomes OOOOGambleDetailOutcome[]
---@return string
local function stakesText(stakes, outcomes)
  local parts = {}
  for index, outcome in ipairs(outcomes) do
    if stakes[index] then
      parts[#parts + 1] = stakes[index] .. " on " .. outcome.n
    end
  end
  return table.concat(parts, ", ")
end

---Builds the line with the state of the own bet (15.4).
---@param detail OOOOGambleDetail
---@return string
local function betStateText(detail)
  local state = detail.betState
  if state == "accepted" then
    return GOOD_COLOR .. "Accepted: an officer has booked your bet.|r"
  elseif state == "waiting" then
    return WAIT_COLOR .. "Waiting for an officer: your bet counts once an officer's addon has received it.|r"
  elseif state == "late" then
    return BAD_COLOR .. "Too late: no officer received your bet before the close, so it does not count.|r"
  elseif state == "outdated" then
    local stakes = detail.betInfo and detail.betInfo.stakes or {}
    return WAIT_COLOR .. "Your last change came too late and does not count. Your earlier accepted bet stays in "
      .. "force: " .. stakesText(stakes, detail.outcomes) .. ".|r"
  elseif state == "none" then
    return detail.state == "open" and "You have no bet on this event." or "You placed no bet on this event."
  end
  return ""
end

---Reads the text of a stake box.
---@param text string
---@param maxStake integer Highest stake of the event
---@return integer|nil stake Whole gold, 0 for an empty box; nil when the text is refused
---@return "number"|"limit"|nil problem Why the text is refused
local function parseStake(text, maxStake)
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return 0
  end
  if not trimmed:match("^%d+$") then
    return nil, "number"
  end
  local stake = tonumber(trimmed)
  if stake > maxStake then
    return nil, "limit"
  end
  return stake
end

---Builds the line under a stake box: the highest possible win of the typed stake, or why it is refused.
---@param text string Text of the box
---@param outcome OOOOGambleDetailOutcome
---@param maxStake integer
---@return string
local function winText(text, outcome, maxStake)
  local stake, problem = parseStake(text, maxStake)
  if problem == "number" then
    return BAD_COLOR .. "not a whole number of gold|r"
  elseif problem == "limit" then
    return BAD_COLOR .. "over the highest stake of " .. maxStake .. " gold|r"
  elseif not stake or stake == 0 then
    return ""
  end
  local win = math.floor(ns.gambleSettle.claim(stake, outcome) + EPSILON)
  return GREY .. "you can win up to " .. win .. " gold|r"
end

---Turns a refusal reason of the model or of the engine into a line.
---@param reason string|nil
---@param maxStake integer
---@return string
local function refusalText(reason, maxStake)
  local text = reason and REFUSALS[reason]
  if text then
    return (text:gsub("%%d", tostring(maxStake)))
  end
  return "The bet was refused (" .. tostring(reason or "unknown reason"):gsub("|", "||") .. ")."
end

---Reads the result per outcome of a resolved event, when the stored event has a valid one.
---@param model OOOOGamble
---@param eventId string
---@return boolean[]|nil
local function resultsOf(model, eventId)
  local event = model:Event(eventId)
  local results = event and event.r
  if type(results) ~= "table" then
    return nil
  end
  for index = 1, #event.o do
    if type(results[index]) ~= "boolean" then
      return nil
    end
  end
  return results
end

---Joins everything that the built detail shows, except the time line and the state of the own bet, which are
---updated in place. The detail is built again only when this changes.
---@param detail OOOOGambleDetail
---@param results boolean[]|nil Result per outcome of a resolved event
---@return string
local function detailSignature(detail, results)
  local parts = { detail.id, detail.state, detail.title, detail.by, detail.maxStake }
  for index, outcome in ipairs(detail.outcomes) do
    parts[#parts + 1] = table.concat({ outcome.n, outcome.p, outcome.x or "", outcome.booked or "",
      outcome.own or "", results and tostring(results[index]) or "" }, ",")
  end
  return table.concat(parts, "\031")
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

---Sets the text of a label when it differs from the shown one.
---@param label table|nil AceGUI Label
---@param text string
---@return boolean changed
local function setText(label, text)
  if not label or label:GetUserData("text") == text then
    return false
  end
  label:SetUserData("text", text)
  label:SetText(text)
  return true
end

---Adds a label as wide as its container.
---@param container table AceGUI container
---@param text string
---@param grey boolean|nil true for a hint
---@return table label
local function addLabel(container, text, grey)
  local label = AceGUI:Create("Label")
  label:SetFullWidth(true)
  label:SetFontObject(grey and GameFontDisable or GameFontHighlight)
  setText(label, text)
  container:AddChild(label)
  return label
end

---Makes a label for a line of the layout "OOOOLine".
---@param text string
---@param width number|nil Fixed width; nil takes what the line leaves
---@return table label
local function lineLabel(text, width)
  local label = AceGUI:Create("Label")
  label:SetFontObject(GameFontHighlight)
  if width then
    label:SetUserData("width", width)
  end
  setText(label, text)
  return label
end

---Adds a line whose children stand side by side (layout "OOOOLine" of MainWindow.lua).
---@param container table
---@return table line AceGUI SimpleGroup
local function addLine(container)
  local line = AceGUI:Create("SimpleGroup")
  line:SetFullWidth(true)
  line:SetLayout("OOOOLine")
  container:AddChild(line)
  return line
end

---Hides the background of a row when AceGUI takes the row back.
---@param label table AceGUI InteractiveLabel
local function hideSelection(label)
  label.frame.ooooSelection:Hide()
end

---Shows or hides the silver background of a row. AceGUI keeps the frame of a released label for the next
---label of any window, so the texture is made once per frame and hidden when the row is released.
---@param label table AceGUI InteractiveLabel
---@param selected boolean
local function setSelection(label, selected)
  local frame = label.frame
  local selection = frame.ooooSelection
  if not selection then
    if not selected then
      return
    end
    selection = frame:CreateTexture(nil, "BACKGROUND")
    selection:SetAllPoints(frame)
    selection:SetColorTexture(SELECTION_COLOR[1], SELECTION_COLOR[2], SELECTION_COLOR[3], SELECTION_COLOR[4])
    frame.ooooSelection = selection
  end
  selection:SetShown(selected)
  label:SetCallback("OnRelease", hideSelection)
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

---Selects the newest open event, or else the newest one waiting for the result, when no held event is
---selected.
---@param groups OOOOGambleGroups
function tab:EnsureSelection(groups)
  if self.selectedId and self.model:Event(self.selectedId) then
    return
  end
  local first = groups.open[1] or groups.waiting[1]
  self.selectedId = first and first.id or nil
  self.message = nil
end

---Builds the list of events again.
---@param groups OOOOGambleGroups
---@param now integer Server time
function tab:UpdateList(groups, now)
  local scroll = self.list
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.rows = {}
  local count = 0
  for _, group in ipairs(GROUPS) do
    local entries = groups[group.key]
    if #entries > 0 then
      local heading = AceGUI:Create("Heading")
      heading:SetText(group.title)
      heading:SetFullWidth(true)
      scroll:AddChild(heading)
      for _, entry in ipairs(entries) do
        local selected = entry.id == self.selectedId
        local label = AceGUI:Create("InteractiveLabel")
        label:SetFullWidth(true)
        label:SetFontObject(GameFontHighlight)
        local row = { label = label, entry = entry, group = group.key }
        label:SetText(rowText(self.model, row, selected, now))
        label:SetHighlight(ROW_HIGHLIGHT)
        setSelection(label, selected)
        local id = entry.id
        label:SetCallback("OnClick", function()
          tab:OnRowClick(id)
        end)
        self.rows[id] = row
        scroll:AddChild(label)
        count = count + 1
      end
    end
  end
  if count == 0 then
    addLabel(scroll, LIST_HINT, true)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
  ns.mainWindow:SetStatus(#groups.open .. " open, " .. #groups.waiting .. " waiting for the result, "
    .. #groups.toPay .. " to pay.")
end

---Handles a click on a row: selects its event. Only the texts of the rows change, because the clicked row is
---not released inside its own click.
---@param id string Event id
function tab:OnRowClick(id)
  if not self.list or id == self.selectedId then
    return
  end
  local previous = self.selectedId
  self.selectedId = id
  self.message = nil
  local now = self.model.now()
  for rowId, row in pairs(self.rows) do
    if rowId == previous or rowId == id then
      row.label:SetText(rowText(self.model, row, rowId == id, now))
      setSelection(row.label, rowId == id)
    end
  end
  self:UpdateDetail(true)
end

--------------------------------------------------------------------------------
-- The detail part
--------------------------------------------------------------------------------

---Builds the line of the last answer to a click, when it belongs to an event.
---@param eventId string
---@return string
function tab:MessageText(eventId)
  local message = self.message
  if not message or message.eventId ~= eventId then
    return ""
  end
  return (message.error and BAD_COLOR or GOOD_COLOR) .. message.text .. "|r"
end

---Shows the answer to a click in the detail part.
---@param eventId string
---@param text string
---@param isError boolean
function tab:ShowMessage(eventId, text, isError)
  self.message = { eventId = eventId, text = text, error = isError }
  if setText(self.messageLabel, self:MessageText(eventId)) and self.detail then
    self.detail:DoLayout()
  end
end

---Adds the title and the time line of an event.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:AddHeader(scroll, detail)
  addLabel(scroll, TITLE_COLOR .. detail.title .. "|r")
  self.timeLabel = addLabel(scroll, timeText(detail, self.model.now()))
end

---Adds the state of the own bet and the line of the last answer.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:AddStateLines(scroll, detail)
  self.stateLabel = addLabel(scroll, betStateText(detail))
  self.messageLabel = addLabel(scroll, self:MessageText(detail.id))
end

---Adds the rows of an open event: per outcome its line, a box with the own stake, and the highest possible
---win of the typed stake; then the buttons and the state of the own bet.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildOpen(scroll, detail)
  addLabel(scroll, "Highest stake: " .. detail.maxStake .. " gold on each outcome. " .. OFFICER_NOTE, true)
  local typed = self.typed[detail.id]
  for index, outcome in ipairs(detail.outcomes) do
    addLabel(scroll, outcomeText(outcome))
    local line = addLine(scroll)
    line:AddChild(lineLabel("Your stake", STAKE_LABEL_WIDTH))
    local text = typed and typed[index] or (outcome.own and tostring(outcome.own)) or ""
    local box = AceGUI:Create("EditBox")
    box:SetUserData("width", BOX_WIDTH)
    -- The buttons below place the bet, so the box needs no button of its own
    box:DisableButton(true)
    box:SetMaxLetters(MAX_DIGITS)
    box:SetText(text)
    local win = lineLabel(winText(text, outcome, detail.maxStake))
    local eventId, maxStake = detail.id, detail.maxStake
    box:SetCallback("OnTextChanged", function(_widget, _event, value)
      tab.typed[eventId] = tab.typed[eventId] or {}
      tab.typed[eventId][index] = value
      setText(win, winText(value, outcome, maxStake))
    end)
    box:SetCallback("OnEnterPressed", function(widget)
      widget:ClearFocus()
    end)
    line:AddChild(box)
    line:AddChild(win)
    self.boxes[index], self.winLabels[index] = box, win
  end

  local buttons = addLine(scroll)
  local place = AceGUI:Create("Button")
  place:SetText("Place bet")
  place:SetUserData("width", BUTTON_WIDTH)
  place:SetCallback("OnClick", function()
    tab:PlaceBet()
  end)
  buttons:AddChild(place)
  local takeBack = AceGUI:Create("Button")
  takeBack:SetText("Take back")
  takeBack:SetUserData("width", BUTTON_WIDTH)
  takeBack:SetCallback("OnClick", function()
    tab:TakeBack()
  end)
  buttons:AddChild(takeBack)
  self:AddStateLines(scroll, detail)
end

---Adds the rows of a locked event, read-only: per outcome its line with the booked sum and the own stake; then
---the state of the own bet.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildLocked(scroll, detail)
  for _, outcome in ipairs(detail.outcomes) do
    addLabel(scroll, outcomeText(outcome) .. (outcome.own and ("   your stake " .. outcome.own) or ""))
  end
  addLabel(scroll, WAIT_COLOR .. "Waiting for the result.|r")
  self:AddStateLines(scroll, detail)
end

---Adds the rows of a resolved or cancelled event, read-only: per outcome its line with the booked sum, the
---own stake, and whether it came true; then the state of the event. Step 15.3 replaces this with the own net,
---the dues, and "Received"; it then also has to add what it shows to `detailSignature`.
---@param container table The AceGUI ScrollFrame of the detail part
---@param detail OOOOGambleDetail
function tab:BuildResolved(container, detail)
  local results = detail.state == "resolved" and resultsOf(self.model, detail.id) or nil
  for index, outcome in ipairs(detail.outcomes) do
    local text = outcomeText(outcome) .. (outcome.own and ("   your stake " .. outcome.own) or "")
    if results then
      text = text .. "   " .. (results[index] and (GOOD_COLOR .. "came true|r") or (BAD_COLOR .. "did not come true|r"))
    end
    addLabel(container, text)
  end
  if detail.state == "cancelled" then
    addLabel(container, "Cancelled: the bets do not count, and nobody owes anything.")
  else
    addLabel(container, "Resolved.")
  end
end

---Updates the texts of the built detail that change without a rebuild: the time line, the state of the own
---bet, and the answer to the last click.
---@param detail OOOOGambleDetail
function tab:UpdateDetailTexts(detail)
  local changed = setText(self.timeLabel, timeText(detail, self.model.now()))
  changed = setText(self.stateLabel, betStateText(detail)) or changed
  changed = setText(self.messageLabel, self:MessageText(detail.id)) or changed
  if changed then
    self.detail:DoLayout()
  end
end

---Shows the detail of the selected event. It is built again only when `force` is true or what it shows has
---changed; otherwise only its changing texts are updated, so that a stake box keeps its focus.
---@param force boolean|nil
function tab:UpdateDetail(force)
  local scroll = self.detail
  if not scroll then
    return
  end
  local detail = self.selectedId and self.model:Detail(self.selectedId) or nil
  local results = detail and detail.state == "resolved" and resultsOf(self.model, detail.id) or nil
  local signature = detail and detailSignature(detail, results) or ""
  if not force and signature == self.signature then
    if detail then
      self:UpdateDetailTexts(detail)
    end
    return
  end
  self.signature = signature
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.boxes, self.winLabels = {}, {}
  self.timeLabel, self.stateLabel, self.messageLabel = nil, nil, nil
  if not detail then
    addLabel(scroll, DETAIL_HINT, true)
  else
    self:AddHeader(scroll, detail)
    if detail.state == "open" then
      self:BuildOpen(scroll, detail)
    elseif detail.state == "locked" then
      self:BuildLocked(scroll, detail)
    else
      self:BuildResolved(scroll, detail)
    end
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

--------------------------------------------------------------------------------
-- Betting
--------------------------------------------------------------------------------

---Builds the detail again after a successful click, in the next frame: the clicked button is not released
---inside its own click.
function tab:RefreshSoon()
  local token = self.token
  C_Timer.After(0, function()
    if token == tab.token then
      tab:Refresh()
    end
  end)
end

---Reads every stake box and places the own bet: an empty box or 0 removes the outcome. A box that does not
---hold a whole number, or a stake over the highest stake, refuses the whole bet with a line and writes nothing.
function tab:PlaceBet()
  local eventId = self.selectedId
  local detail = eventId and self.model and self.model:Detail(eventId)
  if not detail then
    return
  end
  ---@cast eventId string
  local stakes, any, held = {}, false, false
  for index, outcome in ipairs(detail.outcomes) do
    local box = self.boxes[index]
    local stake, problem = parseStake(box and box:GetText() or "", detail.maxStake)
    if problem == "number" then
      self:ShowMessage(eventId, "The stake on " .. outcome.n .. " is not a whole number of gold.", true)
      return
    elseif problem == "limit" then
      self:ShowMessage(eventId, "The stake on " .. outcome.n .. " is over the highest stake of " .. detail.maxStake
        .. " gold.", true)
      return
    end
    ---@cast stake integer
    stakes[index] = stake
    any = any or stake > 0
    held = held or outcome.own ~= nil
  end
  if not any and not held then
    self:ShowMessage(eventId, "Type a stake for at least one outcome.", true)
    return
  end
  local placed, reason = self.model:PlaceBet(eventId, stakes)
  if not placed then
    self:ShowMessage(eventId, refusalText(reason, detail.maxStake), true)
    return
  end
  self.typed[eventId] = nil
  self:ShowMessage(eventId, any and "Your bet is saved. It counts when an officer has accepted it."
    or "Your bet is taken back.", false)
  self:RefreshSoon()
end

---Takes the own bet back.
function tab:TakeBack()
  local eventId = self.selectedId
  local detail = eventId and self.model and self.model:Detail(eventId)
  if not detail then
    return
  end
  ---@cast eventId string
  local taken, reason = self.model:TakeBack(eventId)
  if not taken then
    self:ShowMessage(eventId, refusalText(reason, detail.maxStake), true)
    return
  end
  self.typed[eventId] = nil
  self:ShowMessage(eventId, "Your bet is taken back.", false)
  self:RefreshSoon()
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

---Builds the list again and updates the detail.
function tab:Refresh()
  if not self.list then
    return
  end
  local groups = self.model:Events()
  self:EnsureSelection(groups)
  self:UpdateList(groups, self.model.now())
  self:UpdateDetail(false)
end

---Asks for `Refresh` after `REFRESH_DELAY`; the changes until then are refreshed together.
function tab:ScheduleRefresh()
  if self.refreshPending then
    return
  end
  self.refreshPending = true
  local token = self.token
  C_Timer.After(REFRESH_DELAY, function()
    if token == tab.token then
      tab.refreshPending = false
      tab:Refresh()
    end
  end)
end

---Refreshes the tab every `TICK` seconds while it is shown: the "in 2 h" texts, and the events whose close
---has passed move from "Open" to "Waiting for the result". A timer, not an OnUpdate poll.
function tab:ScheduleTick()
  local token = self.token
  C_Timer.After(TICK, function()
    if token == tab.token then
      tab:Refresh()
      tab:ScheduleTick()
    end
  end)
end

---Builds the content of the tab: at the left the list of events, at the right the detail.
---@param container table The AceGUI tab group
function tab:Build(container)
  self.token = self.token + 1
  self.refreshPending = false
  local model = ns.gamble and ns.gamble.current
  if not model then
    addLabel(container, NOT_READY, true)
    return
  end
  self.model = model

  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOOColumns")
  root:SetAutoAdjustHeight(false)

  local left = AceGUI:Create("InlineGroup")
  left:SetTitle("Events")
  left:SetLayout("Fill")
  left:SetAutoAdjustHeight(false)
  left:SetUserData("width", LIST_WIDTH)
  local list = AceGUI:Create("ScrollFrame")
  list:SetLayout("List")
  left:AddChild(list)
  root:AddChild(left)

  local right = AceGUI:Create("InlineGroup")
  right:SetTitle("Event")
  right:SetLayout("Fill")
  right:SetAutoAdjustHeight(false)
  local detail = AceGUI:Create("ScrollFrame")
  detail:SetLayout("List")
  right:AddChild(detail)
  root:AddChild(right)

  container:AddChild(root)
  root:DoLayout()

  self.list, self.detail, self.signature = list, detail, nil
  local data = ns.gambleData
  ns.sync.RegisterCallback(tab, "OnRecordChanged", function(_event, tableName)
    if tableName == data.TABLE or tableName == data.PLAYER_TABLE then
      tab:ScheduleRefresh()
    end
  end)
  self:Refresh()
  self:ScheduleTick()
end

---Forgets the widgets, which the window releases, stops the timers, and drops the typed texts. The selected
---event stays.
function tab:Close()
  self.token = self.token + 1
  self.refreshPending = false
  if self.model then
    ns.sync.UnregisterCallback(tab, "OnRecordChanged")
  end
  self.model, self.list, self.detail, self.signature = nil, nil, nil, nil
  self.rows, self.boxes, self.winLabels, self.typed = {}, {}, {}, {}
  self.timeLabel, self.stateLabel, self.messageLabel, self.message = nil, nil, nil, nil
end

---Shows the addon window with this tab.
---@return boolean opened false when the shared database is not ready
function tab:Open()
  return ns.mainWindow:Open(TAB_ID)
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = "Gambling",
  order = 40,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
})

ns.slash:Register("bet", "bet - open the gambling tab", function()
  tab:Open()
end)
