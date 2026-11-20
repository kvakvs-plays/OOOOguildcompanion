local addonName, ns = ...

-- The tab "Members" of the addon window: every member who shares professions, with an icon per profession
-- that carries the skill level. AceGUI-3.0 widgets over the model of Professions/ProfessionRoster.lua.
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
local OFFLINE_COLOR, ONLINE_COLOR = "|cff808080", "|cffffffff"
---Side of a profession icon, and of the cell that holds it with its margin
local ICON_SIZE, ICON_CELL = 32, 36
---Font size of the two numbers in an icon
local NUMBER_SIZE = 10
---Colour of the highest skill in an icon: silver
local MAX_COLOR = { 0.75, 0.75, 0.75 }
---Alpha of the icon of an offline member, which is also grey
local OFFLINE_ALPHA = 0.6
---Icon of a profession that `PROFESSION_ICONS` lacks: the question mark
local UNKNOWN_ICON = 134400
---Skill line id -> icon. The record of a member carries only the id, and the client gives the icon only for
---the own professions (`GetProfessionInfo`), so the Classic icons are named here.
---@type table<integer, string>
local PROFESSION_ICONS = {
  [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", -- First Aid
  [164] = "Interface\\Icons\\Trade_BlackSmithing",
  [165] = "Interface\\Icons\\Trade_LeatherWorking",
  [171] = "Interface\\Icons\\Trade_Alchemy",
  [182] = "Interface\\Icons\\Trade_Herbalism",
  [185] = "Interface\\Icons\\INV_Misc_Food_15", -- Cooking
  [186] = "Interface\\Icons\\Trade_Mining",
  [197] = "Interface\\Icons\\Trade_Tailoring",
  [202] = "Interface\\Icons\\Trade_Engineering",
  [333] = "Interface\\Icons\\Trade_Engraving", -- Enchanting
  [356] = "Interface\\Icons\\Trade_Fishing",
  [393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", -- Skinning
}
---Background of the odd lines of the list: silver, with its alpha
local STRIPE_COLOR = { 0.75, 0.75, 0.75, 0.15 }

---Hides the stripe of a line when AceGUI takes the line back.
---@param line table AceGUI SimpleGroup
local function hideStripe(line)
  line.frame.ooooStripe:Hide()
end

---Gives a line of the list the silver background. AceGUI keeps the frame of a released group for the next
---group of any window, so the texture is made once per frame and hidden when the line is released.
---@param line table AceGUI SimpleGroup
local function showStripe(line)
  local frame = line.frame
  local stripe = frame.ooooStripe
  if not stripe then
    stripe = frame:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(frame)
    stripe:SetColorTexture(STRIPE_COLOR[1], STRIPE_COLOR[2], STRIPE_COLOR[3], STRIPE_COLOR[4])
    frame.ooooStripe = stripe
  end
  stripe:Show()
  line:SetCallback("OnRelease", hideStripe)
end

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

--------------------------------------------------------------------------------
-- The widget type "OOOOProfessionIcon"
--------------------------------------------------------------------------------

local ICON_TYPE, ICON_VERSION = "OOOOProfessionIcon", 1

---Shows the name and the skill of the profession of an icon.
---@param frame table The frame of the widget
local function showIconTooltip(frame)
  local entry = frame.obj.entry
  if not entry then
    return
  end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ns.professionRecipes.ProfessionName(entry.id))
  GameTooltip:AddLine(entry.level .. " / " .. entry.max, 1, 1, 1)
  GameTooltip:Show()
end

---Hides the tooltip of an icon.
---@param frame table The frame of the widget
local function hideIconTooltip(frame)
  if GameTooltip:IsOwned(frame) then
    GameTooltip:Hide()
  end
end

---Builds a profession icon: an AceGUI widget with the icon of a profession and, at its bottom right, the
---skill level in white over the highest level in silver. The name is in the tooltip.
---@return table widget
local function createProfessionIcon()
  local frame = CreateFrame("Frame", nil, UIParent)
  frame:Hide()
  frame:EnableMouse(true)
  frame:SetScript("OnEnter", showIconTooltip)
  frame:SetScript("OnLeave", hideIconTooltip)
  local texture = frame:CreateTexture(nil, "ARTWORK")
  texture:SetSize(ICON_SIZE, ICON_SIZE)
  texture:SetPoint("CENTER")
  -- Without the border that is part of an icon file
  texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  local font = GameFontHighlight:GetFont()
  local max = frame:CreateFontString(nil, "OVERLAY")
  max:SetFont(font, NUMBER_SIZE, "OUTLINE")
  max:SetTextColor(MAX_COLOR[1], MAX_COLOR[2], MAX_COLOR[3])
  max:SetPoint("BOTTOMRIGHT", texture, "BOTTOMRIGHT", 0, 1)
  local level = frame:CreateFontString(nil, "OVERLAY")
  level:SetFont(font, NUMBER_SIZE, "OUTLINE")
  level:SetTextColor(1, 1, 1)
  level:SetPoint("BOTTOMRIGHT", max, "TOPRIGHT")
  local widget = {
    frame = frame,
    type = ICON_TYPE,
    ---The profession that is shown; nil while the widget is not in use
    entry = nil, ---@type OOOOProfessionRosterEntry|nil
    OnAcquire = function(self)
      self:SetWidth(ICON_CELL)
      self:SetHeight(ICON_CELL)
    end,
    OnRelease = function(self)
      self.entry = nil
    end,
    ---Shows a profession of a member.
    ---@param entry OOOOProfessionRosterEntry
    ---@param online boolean Whether the member is online; the icon of an offline member is grey
    SetProfession = function(self, entry, online)
      self.entry = entry
      texture:SetTexture(PROFESSION_ICONS[entry.id] or UNKNOWN_ICON)
      texture:SetDesaturated(not online)
      texture:SetAlpha(online and 1 or OFFLINE_ALPHA)
      level:SetText(entry.level)
      max:SetText(entry.max)
    end,
  }
  return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(ICON_TYPE, createProfessionIcon, ICON_VERSION)

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

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
    professionName = ns.professionRecipes.ProfessionName,
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
  for index, row in ipairs(rows) do
    local line = AceGUI:Create("SimpleGroup")
    line:SetFullWidth(true)
    line:SetLayout("OOOOLine")
    if index % 2 == 1 then
      showStripe(line)
    end
    local name = AceGUI:Create("Label")
    name:SetFontObject(GameFontHighlight)
    name:SetUserData("width", NAME_WIDTH)

    local maybeOffline = ""
    if not row.online then maybeOffline = " (offline)" end
    name:SetText(nameColor(row) .. plain(row.name) .. maybeOffline .. "|r")

    line:AddChild(name)
    for _, entry in ipairs(row.professions) do
      local icon = AceGUI:Create(ICON_TYPE)
      icon:SetUserData("width", ICON_CELL)
      icon:SetProfession(entry, row.online)
      line:AddChild(icon)
    end
    scroll:AddChild(line)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()

  local count = #rows .. (#rows == 1 and " member" or " members")
  if self.filter then
    ns.mainWindow:SetStatus(count .. " with " .. ns.professionRecipes.ProfessionName(self.filter)
      .. ", highest skill first.")
  else
    ns.mainWindow:SetStatus(count .. " with shared professions.")
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
