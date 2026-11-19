local addonName, ns = ...

-- The tab "Members" of the addon window: every member who shares professions, with each profession and its
-- skill level. AceGUI-3.0 widgets over the model of Professions/ProfessionRoster.lua.
--
-- It lists the members with a record in the table `profession`: those who use the addon. A member of the
-- guild roster without the addon is not listed, because nothing is known about their professions.

---@class OOOOProfessionRosterTab
---@field list table|nil AceGUI ScrollFrame with one line per member; nil while the tab is not shown
---@field dropdown table|nil AceGUI Dropdown with the profession filter
---@field filter integer|nil Skill line id that the list is narrowed to; nil shows all members
---@field listedIds string|nil The profession ids that the dropdown lists, joined: tells when to fill it again
---@field updateToken integer Counts the scheduled updates, so that only the last one runs
local tab = { updateToken = 0 }
ns.professionRosterTab = tab

local AceGUI = LibStub("AceGUI-3.0")

---Id of the tab in the addon window
local TAB_ID = "members"
---Key of the dropdown entry that shows all members
local ALL = 0
---Width of the column with the names
local NAME_WIDTH = 190
---Width of the dropdown
local DROPDOWN_WIDTH = 220
---Seconds for which changes of the tables and of the roster are collected before the list is built again
local REFRESH_DELAY = 0.5
local OFFLINE_COLOR, ONLINE_COLOR, FILTER_COLOR, DETAIL_COLOR = "|cff808080", "|cffffffff", "|cffffd100", "|cffa0a0a0"

---Makes a text of another member safe to show: a character name comes from the key of a received record.
---@param text string
---@return string
local function plain(text)
  return (text:gsub("|", "||"))
end

---Returns the colour code of a member name: the class colour for an online member whose class is known.
---@param row OOOOProfessionRosterRow
---@return string
local function nameColor(row)
  if not row.online then
    return OFFLINE_COLOR
  end
  -- The class token comes from a received record, so it is only looked up
  local color = row.class and RAID_CLASS_COLORS[row.class]
  if type(color) == "table" and type(color.r) == "number" and type(color.g) == "number"
    and type(color.b) == "number" then
    return ("|cff%02x%02x%02x"):format(color.r * 255, color.g * 255, color.b * 255)
  end
  return ONLINE_COLOR
end

---Builds the text with the professions of a member: name, level, and the count of shared recipes.
---@param row OOOOProfessionRosterRow
---@param filter integer|nil The profession that the list is narrowed to; it is shown in yellow
---@return string
local function professionText(row, filter)
  local parts = {}
  for index, entry in ipairs(row.professions) do
    local color = not row.online and OFFLINE_COLOR or (entry.id == filter and FILTER_COLOR or ONLINE_COLOR)
    local text = color .. ns.professionRecipes.ProfessionName(entry.id) .. " " .. entry.level .. "/" .. entry.max
      .. "|r"
    if entry.recipes > 0 then
      text = text .. " " .. (row.online and DETAIL_COLOR or OFFLINE_COLOR) .. "(" .. entry.recipes .. ")|r"
    end
    parts[index] = text
  end
  return table.concat(parts, "    ")
end

---Fills the dropdown with the professions that members have, when they have changed.
---@param professionIds integer[] In ascending order
function tab:UpdateDropdown(professionIds)
  local joined = table.concat(professionIds, ",")
  if joined == self.listedIds then
    return
  end
  self.listedIds = joined
  local list, order = { [ALL] = "All professions" }, { ALL }
  local names = {}
  for _, id in ipairs(professionIds) do
    names[#names + 1] = { id = id, name = ns.professionRecipes.ProfessionName(id) }
  end
  table.sort(names, function(left, right)
    return left.name < right.name
  end)
  for _, entry in ipairs(names) do
    list[entry.id] = entry.name
    order[#order + 1] = entry.id
  end
  -- A profession that nobody has any more stays selected until the user picks another one
  if self.filter and not list[self.filter] then
    list[self.filter] = ns.professionRecipes.ProfessionName(self.filter)
    order[#order + 1] = self.filter
  end
  self.dropdown:SetList(list, order)
  self.dropdown:SetValue(self.filter or ALL)
end

---Builds the list of members again.
function tab:Update()
  local scroll = self.list
  if not scroll then
    return
  end
  local rows, professionIds = ns.professionRoster.rows({
    sync = ns.sync,
    isOnline = function(name)
      return ns.guildState:IsOnline(name) == true
    end,
  }, self.filter)
  self:UpdateDropdown(professionIds)

  scroll:ReleaseChildren()
  scroll:PauseLayout()
  if #rows == 0 then
    local hint = AceGUI:Create("Label")
    hint:SetFullWidth(true)
    hint:SetFontObject(GameFontDisable)
    hint:SetText(self.filter and "No member has shared this profession."
      or "No member has shared a profession yet.")
    scroll:AddChild(hint)
  end
  for _, row in ipairs(rows) do
    local line = AceGUI:Create("SimpleGroup")
    line:SetFullWidth(true)
    line:SetLayout("OOOOLine")
    local name = AceGUI:Create("Label")
    name:SetFontObject(GameFontHighlight)
    name:SetUserData("width", NAME_WIDTH)
    name:SetText(nameColor(row) .. plain(row.name) .. "|r")
    line:AddChild(name)
    local professions = AceGUI:Create("Label")
    professions:SetFontObject(GameFontHighlight)
    professions:SetText(professionText(row, self.filter))
    line:AddChild(professions)
    scroll:AddChild(line)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()

  local count = #rows .. (#rows == 1 and " member" or " members")
  if self.filter then
    ns.mainWindow:SetStatus(count .. " with " .. ns.professionRecipes.ProfessionName(self.filter)
      .. ", highest skill first. The number in brackets counts the shared recipes.")
  else
    ns.mainWindow:SetStatus(count .. " with shared professions. The number in brackets counts the shared recipes.")
  end
end

---Asks for `Update` after `REFRESH_DELAY`. A later call replaces an earlier one that has not run yet.
function tab:ScheduleUpdate()
  self.updateToken = self.updateToken + 1
  local token = self.updateToken
  C_Timer.After(REFRESH_DELAY, function()
    if token == tab.updateToken then
      tab:Update()
    end
  end)
end

---Builds the content of the tab: the profession filter over the list of members.
---@param container table The AceGUI tab group
function tab:Build(container)
  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOORows")
  root:SetAutoAdjustHeight(false)

  -- In a group of its own: a row of the layout is as wide as the tab
  local top = AceGUI:Create("SimpleGroup")
  top:SetLayout("Flow")
  local dropdown = AceGUI:Create("Dropdown")
  dropdown:SetLabel("Profession")
  dropdown:SetWidth(DROPDOWN_WIDTH)
  dropdown:SetCallback("OnValueChanged", function(_widget, _event, key)
    tab.filter = key ~= ALL and key or nil
    -- Later: the dropdown closes its list after this callback
    tab:ScheduleUpdate()
  end)
  top:AddChild(dropdown)
  root:AddChild(top)

  local list = AceGUI:Create("ScrollFrame")
  list:SetLayout("List")
  list:SetUserData("fill", true)
  root:AddChild(list)

  container:AddChild(root)
  root:DoLayout()

  self.list, self.dropdown, self.listedIds = list, dropdown, nil
  ns.sync.RegisterCallback(tab, "OnRecordChanged", function(_event, tableName)
    if tableName == ns.professionData.TABLE or tableName == ns.syncCharacter.TABLE then
      tab:ScheduleUpdate()
    end
  end)
  ns.guildState.RegisterCallback(tab, "OnRosterChanged", function()
    tab:ScheduleUpdate()
  end)
  self:Update()
end

---Forgets the widgets, which the window releases. The filter stays.
function tab:Close()
  self.updateToken = self.updateToken + 1
  self.list, self.dropdown, self.listedIds = nil, nil, nil
  ns.sync.UnregisterCallback(tab, "OnRecordChanged")
  ns.guildState.UnregisterCallback(tab, "OnRosterChanged")
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = "Members",
  order = 30,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
})
