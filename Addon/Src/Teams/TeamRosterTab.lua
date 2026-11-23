local addonName, ns = ...

-- The tab "Roster" of the addon window, for officers only (.agents/user-wishes.md, "Roster view"): the guild
-- roster at the left, and at the right the team of the selected character with the controls that make and
-- change teams. AceGUI-3.0 widgets over the models of Teams/Teams.lua and Teams/TeamRoster.lua.
--
-- Grouping: the officer selects a character, clicks "Group with another character", and clicks the other
-- character in the list.
-- - Neither has a team: the officer names a new team for both.
-- - One has a team: the other joins it.
-- - Both have teams: the officer chooses between moving the clicked character and merging the two teams.
--
-- A widget is never released inside its own callback: a button only changes the state and asks for a refresh,
-- which runs a moment later. The detail is not built again while the officer types in one of its boxes.
--
-- Not checked in the client when this was written: the whole tab, and the texture of the crown in its title.

---@class OOOOTeamRosterPending A grouping that waits for an answer of the officer
---@field kind string "create": name a new team for `names`; "choose": move `target` or merge the teams
---@field names string[]|nil The characters of the new team
---@field target string|nil The character that was clicked
---@field fromId string|nil The team of `target`
---@field intoId string|nil The team of the selected character

---@class OOOOTeamRosterTab
---@field model OOOOTeamsModel|nil The model while the tab is shown
---@field list table|nil AceGUI ScrollFrame with one row per member; nil while the tab is not shown
---@field detail table|nil AceGUI ScrollFrame with the team of the selected character
---@field rows table<string, table> Character name -> the AceGUI InteractiveLabel of its row
---@field boxes table[] The AceGUI EditBoxes of the detail
---@field selected string|nil The selected character
---@field picking boolean true while the next click on a row names the character to group with
---@field pending OOOOTeamRosterPending|nil
---@field message string|nil What the last action answered
---@field newAlias string The typed alias of a new team
---@field confirmDisband string|nil Id of the team whose "Disband" was clicked once
---@field token integer Counts the scheduled refreshes, so that only the last one runs
local tab = { rows = {}, boxes = {}, picking = false, newAlias = "", token = 0 }
ns.teamRosterTab = tab

local AceGUI = LibStub("AceGUI-3.0")
local data = ns.teamData

---Id of the tab in the addon window
local TAB_ID = "roster"
---The crown of a group leader, in front of the title
local CROWN = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14:14|t "
---Width of the column with the roster
local LIST_WIDTH = 320
---Width of a button of the detail
local BUTTON_WIDTH = 280
---Seconds for which changes of the tables and of the roster are collected before the tab is built again
local REFRESH_DELAY = 0.3
---Seconds after which a refresh is tried again while the officer types
local BUSY_DELAY = 2
local OFFLINE_COLOR, ONLINE_COLOR, ALIAS_COLOR, MESSAGE_COLOR = "|cff808080", "|cffffffff", "|cffc0c0c0", "|cffffd100"
---Background of the selected row: silver, 25%
local SELECTION_COLOR = { 0.75, 0.75, 0.75, 0.25 }
---Background of a row under the mouse
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

---Refusal of the model -> what the officer reads
---@type table<string, string>
local REFUSALS = {
  ["not an officer"] = "Only an officer changes the teams.",
  ["no team"] = "That team no longer exists.",
  ["bad name"] = "That name cannot be in a team.",
  ["in a team"] = "The character is in a team already.",
  ["account in another team"] = "An account of the character belongs to another team. Merge the teams, or move"
    .. " the character there.",
  ["same team"] = "Both are in the same team.",
  ["empty"] = "Type an alias first.",
  ["too long"] = "The alias is longer than " .. data.MAX_ALIAS .. " bytes.",
  ["bad character"] = "The alias has a character that is not allowed (|).",
  ["not ready"] = "The shared database is not ready.",
}

---Makes a text of another member safe to show: a name or an alias comes from a received record.
---@param text string
---@return string
local function plain(text)
  return (text:gsub("|", "||"))
end

---Returns the colour code of a character name: grey for an offline member, the class colour for an online one.
---@param online boolean
---@param class string|nil Class token
---@return string
local function nameColor(online, class)
  if not online then
    return OFFLINE_COLOR
  end
  -- The class token can come from a received record, so it is only looked up
  local color = class and RAID_CLASS_COLORS[class]
  if type(color) == "table" and type(color.r) == "number" and type(color.g) == "number"
      and type(color.b) == "number" then
    return ("|cff%02x%02x%02x"):format(color.r * 255, color.g * 255, color.b * 255)
  end
  return ONLINE_COLOR
end

---Returns a character name in its colour, by the guild roster and the table `character`.
---@param name string
---@return string
local function coloredName(name)
  local member = ns.guildState:GetMember(name)
  local character = ns.sync:Get(ns.syncCharacter.TABLE, name)
  local class = (member and member.class) or (type(character) == "table" and character.class) or nil
  return nameColor(member ~= nil and member.online, class) .. plain(name) .. "|r"
end

---Hides the background of a row when AceGUI takes the row back.
---@param label table AceGUI InteractiveLabel
local function hideSelection(label)
  label.frame.ooooSelection:Hide()
end

---Shows or hides the silver background of a row. AceGUI keeps the frame of a released label for the next
---label of any window, so the texture is made once per frame, coloured at every use (another tab has its own
---colour), and hidden when the row is released.
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
    frame.ooooSelection = selection
  end
  selection:SetColorTexture(SELECTION_COLOR[1], SELECTION_COLOR[2], SELECTION_COLOR[3], SELECTION_COLOR[4])
  selection:SetShown(selected)
  label:SetCallback("OnRelease", hideSelection)
end

---Adds a text as wide as its container.
---@param container table
---@param text string
---@param disabled boolean? true for the grey font
---@return table label AceGUI Label
local function addLabel(container, text, disabled)
  local label = AceGUI:Create("Label")
  label:SetFullWidth(true)
  label:SetFontObject(disabled and GameFontDisable or GameFontHighlight)
  label:SetText(text)
  container:AddChild(label)
  return label
end

---Adds a heading as wide as its container.
---@param container table
---@param text string
local function addHeading(container, text)
  local heading = AceGUI:Create("Heading")
  heading:SetText(text)
  heading:SetFullWidth(true)
  container:AddChild(heading)
end

---Adds a button. Its click changes the state of the tab; the tab is built again a moment later.
---@param container table
---@param text string
---@param onClick fun()
local function addButton(container, text, onClick)
  local button = AceGUI:Create("Button")
  button:SetText(text)
  button:SetWidth(BUTTON_WIDTH)
  button:SetCallback("OnClick", function()
    onClick()
    tab:ScheduleRefresh(0)
  end)
  container:AddChild(button)
end

---Returns the text of a refusal.
---@param reason string|nil
---@return string
local function refusalText(reason)
  return REFUSALS[reason or ""] or ("Refused: " .. tostring(reason) .. ".")
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

---Returns the text of a row: the name in its colour, and the alias of the team in silver.
---@param row OOOOTeamRosterRow
---@return string
local function rowText(row)
  local text = nameColor(row.online, row.class) .. plain(row.name) .. "|r"
  if row.alias then
    -- A detected character is not assigned yet: the question mark asks the officer to look
    text = text .. "  " .. (row.online and ALIAS_COLOR or OFFLINE_COLOR) .. plain(row.alias)
      .. (row.detected and " ?" or "") .. "|r"
  end
  return text
end

---Builds the list of members again.
function tab:UpdateList()
  local scroll = self.list
  local rows = ns.teamRoster.rows({ roster = ns.guildState.roster, model = self.model, sync = ns.sync })
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.rows = {}
  local online, grouped = 0, 0
  for _, row in ipairs(rows) do
    local label = AceGUI:Create("InteractiveLabel")
    label:SetFullWidth(true)
    label:SetFontObject(GameFontHighlight)
    label:SetText(rowText(row))
    label:SetHighlight(ROW_HIGHLIGHT)
    setSelection(label, row.name == self.selected)
    local name = row.name
    label:SetCallback("OnClick", function()
      tab:OnRowClick(name)
    end)
    self.rows[name] = label
    scroll:AddChild(label)
    online = online + (row.online and 1 or 0)
    grouped = grouped + (row.teamId and 1 or 0)
  end
  if #rows == 0 then
    addLabel(scroll, "The guild roster is not read yet.", true)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
  ns.mainWindow:SetStatus(#rows .. " members, " .. online .. " online, " .. grouped .. " in a team.")
end

---Handles a click on a row. While the officer picks a character to group with, the click names it; otherwise
---it selects the character. No row is released here, because the clicked row runs this.
---@param name string Character name
function tab:OnRowClick(name)
  if not self.list then
    return
  end
  if self.picking and self.selected and name ~= self.selected then
    self:Pick(name)
  elseif name ~= self.selected then
    local previous = self.selected and self.rows[self.selected]
    if previous then
      setSelection(previous, false)
    end
    self.selected = name
    setSelection(self.rows[name], true)
    self.picking, self.pending, self.message, self.confirmDisband = false, nil, nil, nil
  else
    return
  end
  self:UpdateDetail()
end

---Groups the selected character with the one that the officer clicked.
---@param target string Character name
function tab:Pick(target)
  local model, selected = self.model, self.selected
  local index = model:Index()
  local own, other = index.ofName[selected], index.ofName[target]
  self.picking = false
  if not own and not other then
    self.pending = { kind = "create", names = { selected, target } }
    self.message = nil
  elseif own and other and own == other then
    self.message = REFUSALS["same team"]
  elseif own and other then
    self.pending = { kind = "choose", target = target, fromId = other, intoId = own }
    self.message = nil
  else
    local id, joiner = own or other, own and target or selected
    local ok, reason = model:Add(id, joiner)
    self.message = ok and (plain(joiner) .. " joined the team \"" .. plain(model:Alias(id) or "") .. "\".")
      or refusalText(reason)
  end
end

--------------------------------------------------------------------------------
-- The detail
--------------------------------------------------------------------------------

---Tells whether the officer types in a box of the detail.
---@return boolean
function tab:IsTyping()
  for _, box in ipairs(self.boxes) do
    if box.editbox and box.editbox:HasFocus() then
      return true
    end
  end
  return false
end

---Adds an edit box as wide as its container and remembers it for `IsTyping`.
---@param container table
---@param title string
---@param text string
---@return table box AceGUI EditBox
function tab:AddBox(container, title, text)
  local box = AceGUI:Create("EditBox")
  box:SetLabel(title)
  box:SetFullWidth(true)
  box:SetMaxLetters(data.MAX_ALIAS)
  box:SetText(text)
  container:AddChild(box)
  self.boxes[#self.boxes + 1] = box
  return box
end

---Adds the box with the alias of a new team and the button that makes the team.
---@param container table
---@param names string[] The characters of the new team
---@param buttonText string
function tab:AddCreateForm(container, names, buttonText)
  local box = self:AddBox(container, "Alias of the new team", self.newAlias)
  box:DisableButton(true)
  box:SetCallback("OnTextChanged", function(_widget, _event, value)
    tab.newAlias = value
  end)
  local function create()
    local id, reason = tab.model:Create(tab.newAlias, names)
    if id then
      tab.message = "Made the team \"" .. plain(tab.model:Alias(id) or "") .. "\"."
      tab.newAlias, tab.pending = "", nil
    else
      tab.message = refusalText(reason)
    end
  end
  box:SetCallback("OnEnterPressed", function(widget)
    widget:ClearFocus()
    create()
    tab:ScheduleRefresh(0)
  end)
  addButton(container, buttonText, create)
end

---Adds the question of a grouping that waits for the officer.
---@param container table
---@param pending OOOOTeamRosterPending
function tab:AddPending(container, pending)
  local model = self.model
  if pending.kind == "create" then
    addLabel(container, "A new team for " .. coloredName(pending.names[1]) .. " and "
      .. coloredName(pending.names[2]) .. ". Give it an alias: the name that chat shows for the player.")
    self:AddCreateForm(container, pending.names, "Create the team")
  else
    local target, fromId, intoId = pending.target, pending.fromId, pending.intoId
    local from, into = plain(model:Alias(fromId) or "?"), plain(model:Alias(intoId) or "?")
    addLabel(container, coloredName(target) .. " is in the team \"" .. from .. "\", and "
      .. coloredName(self.selected) .. " is in the team \"" .. into .. "\".")
    addButton(container, "Move " .. target .. " into \"" .. into .. "\"", function()
      local ok, reason, moved = model:Move(target, intoId)
      if ok then
        tab.message = "Moved " .. plain(table.concat(moved or {}, ", ")) .. " into \"" .. into .. "\"."
          .. (moved and #moved > 1 and " Characters of the same account move together." or "")
      else
        tab.message = refusalText(reason)
      end
      tab.pending = nil
    end)
    addButton(container, "Merge both teams as \"" .. into .. "\"", function()
      local ok, reason = model:Merge(fromId, intoId)
      tab.message = ok and ("Merged \"" .. from .. "\" into \"" .. into .. "\".") or refusalText(reason)
      tab.pending = nil
    end)
  end
  addButton(container, "Cancel", function()
    tab.pending, tab.message = nil, nil
  end)
end

---Adds what the tab shows of a team: its aliases, the deny checkbox, its characters, and its account ids.
---@param container table
---@param detail OOOOTeamDetail
function tab:AddTeam(container, detail)
  local model, id = self.model, detail.id
  addHeading(container, "Team")
  addLabel(container, "Shown in chat as: " .. ALIAS_COLOR .. plain(detail.alias) .. "|r")
  local box = self:AddBox(container, "Alias given by the officers", detail.officerAlias)
  box:SetCallback("OnEnterPressed", function(widget, _event, value)
    widget:ClearFocus()
    local ok, reason = model:SetOfficerAlias(id, value)
    tab.message = ok and "Changed the alias." or refusalText(reason)
    tab:ScheduleRefresh(0)
  end)
  addLabel(container, "Alias that the player asked for: "
    .. (detail.playerAlias and (ALIAS_COLOR .. plain(detail.playerAlias) .. "|r") or "none"))
  local deny = AceGUI:Create("CheckBox")
  deny:SetFullWidth(true)
  deny:SetLabel("Deny the player's alias: show the alias of the officers")
  deny:SetValue(detail.denied)
  deny:SetCallback("OnValueChanged", function(_widget, _event, value)
    local ok, reason = model:SetDenied(id, value == true)
    tab.message = (not ok) and refusalText(reason) or nil
    tab:ScheduleRefresh(0)
  end)
  container:AddChild(deny)

  addHeading(container, "Characters")
  for _, name in ipairs(detail.members) do
    addLabel(container, coloredName(name))
  end
  for _, name in ipairs(detail.detected) do
    addLabel(container, coloredName(name) .. " |cff808080(same account, not assigned)|r")
  end
  if #detail.origins > 0 then
    addLabel(container, "Account ids: " .. plain(table.concat(detail.origins, "  ")), true)
  else
    addLabel(container, "No account id: no character of the team uses the addon.", true)
  end
end

---Builds the detail of the selected character again.
function tab:UpdateDetail()
  local scroll = self.detail
  if not scroll then
    return
  end
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.boxes = {}
  local model, name = self.model, self.selected
  if not name then
    addLabel(scroll, "Select a character in the list.", true)
  else
    local id, detected = model:TeamOf(name)
    local detail = id and model:Detail(id)
    local origins = model:OriginsOf(name)
    addLabel(scroll, coloredName(name)):SetFontObject(GameFontNormalLarge)
    addLabel(scroll, #origins > 0 and ("Uses the addon. Account id: " .. plain(table.concat(origins, "  ")))
      or "Does not use the addon: it joins a team by its name only.", true)
    if self.message then
      addLabel(scroll, MESSAGE_COLOR .. self.message .. "|r")
    end

    if self.picking then
      addHeading(scroll, "Group")
      addLabel(scroll, "Click the character in the list that belongs to the same player as "
        .. coloredName(name) .. ".")
      addButton(scroll, "Cancel", function()
        tab.picking = false
      end)
    elseif self.pending then
      addHeading(scroll, "Group")
      self:AddPending(scroll, self.pending)
    else
      if detail then
        self:AddTeam(scroll, detail)
      else
        addHeading(scroll, "Team")
        addLabel(scroll, "No team.", true)
      end
      addHeading(scroll, "Actions")
      addButton(scroll, "Group with another character", function()
        tab.picking, tab.message, tab.confirmDisband = true, nil, nil
      end)
      if detail and detected then
        addButton(scroll, "Assign to the team \"" .. detail.alias .. "\"", function()
          local ok, reason = model:Add(id, name)
          tab.message = ok and (plain(name) .. " is assigned.") or refusalText(reason)
        end)
      elseif detail then
        addButton(scroll, "Remove " .. name .. " from the team", function()
          local ok, reason = model:Remove(name)
          tab.message = ok and (plain(name) .. " left the team.") or refusalText(reason)
          tab.confirmDisband = nil
        end)
        addButton(scroll, self.confirmDisband == id and "Really disband? Click again" or "Disband the team",
          function()
            if tab.confirmDisband ~= id then
              tab.confirmDisband = id
              return
            end
            local ok, reason = model:Disband(id)
            tab.message = ok and "The team is disbanded." or refusalText(reason)
            tab.confirmDisband = nil
          end)
      else
        self:AddCreateForm(scroll, { name }, "Create a team for this character alone")
      end
    end
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

---Builds the list and the detail again. While the officer types in a box of the detail, only the list is
---built, and the refresh is tried again later.
function tab:Refresh()
  if not self.list then
    return
  end
  if self.selected and not ns.guildState:GetMember(self.selected) then
    -- The selected character left the guild
    self.selected, self.picking, self.pending, self.message = nil, false, nil, nil
  end
  self:UpdateList()
  if self:IsTyping() then
    self:ScheduleRefresh(BUSY_DELAY)
  else
    self:UpdateDetail()
  end
end

---Asks for `Refresh` after a delay. A later call replaces an earlier one that has not run yet.
---@param delay number? Seconds; `REFRESH_DELAY` when omitted
function tab:ScheduleRefresh(delay)
  self.token = self.token + 1
  local token = self.token
  C_Timer.After(delay or REFRESH_DELAY, function()
    if token == tab.token then
      tab:Refresh()
    end
  end)
end

---Builds the content of the tab: the roster at the left, the team of the selected character at the right.
---@param container table The AceGUI tab group
function tab:Build(container)
  self.token = self.token + 1
  local model = ns.teams.current
  if not model or not ns.sync:IsOfficer() then
    addLabel(container, model and "This tab is for officers." or "The shared database is not ready.", true)
    return
  end
  self.model = model

  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOOColumns")
  root:SetAutoAdjustHeight(false)

  local left = AceGUI:Create("InlineGroup")
  left:SetTitle("Guild roster")
  left:SetLayout("Fill")
  left:SetAutoAdjustHeight(false)
  left:SetUserData("width", LIST_WIDTH)
  local list = AceGUI:Create("ScrollFrame")
  list:SetLayout("List")
  left:AddChild(list)
  root:AddChild(left)

  local right = AceGUI:Create("InlineGroup")
  right:SetTitle("Character and team")
  right:SetLayout("Fill")
  right:SetAutoAdjustHeight(false)
  local detail = AceGUI:Create("ScrollFrame")
  detail:SetLayout("List")
  right:AddChild(detail)
  root:AddChild(right)

  container:AddChild(root)
  root:DoLayout()

  self.list, self.detail = list, detail
  self.picking, self.pending, self.message, self.confirmDisband = false, nil, nil, nil
  ns.sync.RegisterCallback(tab, "OnRecordChanged", function(_event, tableName)
    if tableName == data.TABLE or tableName == ns.syncCharacter.TABLE then
      tab:ScheduleRefresh()
    end
  end)
  ns.guildState.RegisterCallback(tab, "OnRosterChanged", function()
    tab:ScheduleRefresh()
  end)
  self:Refresh()
end

---Forgets the widgets, which the window releases. The selection stays.
function tab:Close()
  self.token = self.token + 1
  if self.list then
    ns.sync.UnregisterCallback(tab, "OnRecordChanged")
    ns.guildState.UnregisterCallback(tab, "OnRosterChanged")
  end
  self.list, self.detail, self.model = nil, nil, nil
  self.rows, self.boxes = {}, {}
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = CROWN .. "Roster",
  order = 90,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
  -- The rank comes with the roster, some seconds after the login
  IsVisible = function()
    return ns.sync:IsOfficer()
  end,
})
