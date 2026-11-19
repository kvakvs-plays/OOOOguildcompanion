local addonName, ns = ...

-- The window "Guild professions" (.agents/00-plan.md, section 5.4 and step 12.7): the frames over the model
-- of Professions/ProfessionSearch.lua. `/oooo prof` opens and closes it.
--
-- The frame is not protected and calls no protected function, so it may be shown, hidden, and moved in
-- combat. It does not whisper a crafter: opening a chat from addon code is a protected call.
--
-- Not checked on Forever when this was written: the tooltip methods `SetItemByID` and `SetSpellByID`, and
-- `C_Item.GetItemIconByID` for the icons of the materials. Each is looked up before it is used.

---@class OOOOProfessionWindowSettings `db.profile.professions`: where the user left the window
---@field point string|nil Anchor point of the window; nil until the window was moved
---@field relativePoint string|nil Anchor point of the screen
---@field x number|nil
---@field y number|nil

---@class OOOOProfessionWindow
---@field frame table|nil The window; nil until it is first opened
---@field model OOOOProfessionSearch|nil The search model; made with the window
---@field recipeBox table The edit box "Recipe"
---@field materialBox table The edit box "Material"
---@field rowButtons table[] The row buttons of the result list, top first
---@field rows OOOOProfessionRow[] The result of the last search
---@field total integer How many recipes matched the last search
---@field offset integer Number of rows above the first row button
---@field selectedId integer|nil The recipe that the detail part shows
---@field status table FontString below the list
---@field hint table FontString in the empty list
---@field pane table Frame of the detail part; hidden while no recipe is selected
---@field craftIcon table Texture: the icon of the selected recipe
---@field craftLink table Button with the name of the selected recipe as a link; `link` is its chat link
---@field craftInfo table FontString: the profession and how many items a craft makes
---@field materialsTitle table FontString "Materials"
---@field reagentButtons table[] The squares of the materials; made when first needed
---@field detail table FontString of the detail part: the members who know the recipe
---@field searchToken integer Counts the scheduled searches, so that only the last one runs
---@field professionNames table<integer, string> Skill line id -> name, as the client gave it
local window = { rows = {}, total = 0, offset = 0, searchToken = 0, professionNames = {}, reagentButtons = {} }
ns.professionWindow = window

---Global name of the frame: the game closes the frames of `UISpecialFrames` with Escape, by name
local FRAME_NAME = "OOOOProfessionsFrame"
local WINDOW_TITLE = "Guild professions"
local WIDTH, HEIGHT = 760, 460
---Width of the detail part at the right side
local DETAIL_WIDTH = 250
---Space between the border of the detail part and what it shows
local DETAIL_INSET = 8
local PADDING = 10
local HEADER_HEIGHT = 30
---Height of the line with the two search boxes
local SEARCH_HEIGHT = 30
---Height of the status line below the list
local STATUS_HEIGHT = 18
local ROW_HEIGHT = 34
local ICON_SIZE = 28
---Seconds between the last key and the search
local SEARCH_DELAY = 0.3
---Seconds for which changes of the table, the roster, and the names are collected before a new search
local REFRESH_DELAY = 0.5
---Names of members in a row before the rest is counted
local ROW_NAMES = 4
---Members that the detail part lists before the rest is counted
local DETAIL_MEMBERS = 22
---Side of the icon of the selected recipe in the detail part
local CRAFT_ICON_SIZE = 36
---Side of the square of one material, and the space between two squares
local REAGENT_SIZE, REAGENT_GAP = 36, 4
---Size of the count in the square of a material
local REAGENT_COUNT_FONT = 15
---Icon of a recipe without one: the question mark
local UNKNOWN_ICON = 134400
local HINT = "Type a part of a recipe name, or of the name of a material,\nwith 2 letters or more."
local ONLINE_COLOR, OFFLINE_COLOR, TITLE_COLOR = "|cffffffff", "|cff808080", "|cffffd100"
---Anchor points that a saved position may name
local POINTS = {
  TOPLEFT = true,
  TOP = true,
  TOPRIGHT = true,
  LEFT = true,
  CENTER = true,
  RIGHT = true,
  BOTTOMLEFT = true,
  BOTTOM = true,
  BOTTOMRIGHT = true
}

---Makes a text of another member safe to show: a character name comes from the key of a received record.
---@param text string
---@return string
local function plain(text)
  return (text:gsub("|", "||"))
end

---Stores where the user left the window.
---@param frame table
local function savePosition(frame)
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  local settings = ns.db.profile.professions
  settings.point, settings.relativePoint, settings.x, settings.y = point, relativePoint, x, y
end

---Puts the window where the user left it, or in the middle of the screen.
---@param frame table
local function restorePosition(frame)
  local settings = ns.db.profile.professions
  frame:ClearAllPoints()
  if POINTS[settings.point] and POINTS[settings.relativePoint] and type(settings.x) == "number"
      and type(settings.y) == "number" then
    frame:SetPoint(settings.point, UIParent, settings.relativePoint, settings.x, settings.y)
  else
    frame:SetPoint("CENTER")
  end
end

---Returns the name of a profession in the language of the client.
---@param professionId integer|nil Skill line id
---@return string
function window:ProfessionName(professionId)
  if not professionId then
    return ""
  end
  local known = self.professionNames[professionId]
  if known then
    return known
  end
  local name = C_TradeSkillUI.GetTradeSkillDisplayName(professionId)
  if issecretvalue(name) or type(name) ~= "string" or name == "" then
    return "#" .. professionId
  end
  self.professionNames[professionId] = name
  return name
end

---Returns the chat link of what a recipe makes: the item, or what the client links for a recipe without one.
---@param recipeId integer
---@param itemId integer|nil
---@return string|nil link nil when the client has none, or not yet
local function linkOf(recipeId, itemId)
  local link
  if itemId then
    local _name, itemLink = C_Item.GetItemInfo(itemId)
    link = itemLink
  end
  if link == nil then
    link = C_TradeSkillUI.GetRecipeItemLink(recipeId)
  end
  if issecretvalue(link) or type(link) ~= "string" then
    return nil
  end
  return link
end

--------------------------------------------------------------------------------
-- The result list
--------------------------------------------------------------------------------

---Builds the line with the members of a row: the first names, online ones in white, and the count of the rest.
---@param row OOOOProfessionRow
---@return string
local function crafterLine(row)
  local parts = {}
  for index = 1, math.min(#row.crafters, ROW_NAMES) do
    parts[index] = (index <= row.online and ONLINE_COLOR or OFFLINE_COLOR) .. plain(row.crafters[index]) .. "|r"
  end
  local text = table.concat(parts, ", ")
  if #row.crafters > ROW_NAMES then
    text = text .. OFFLINE_COLOR .. " +" .. (#row.crafters - ROW_NAMES) .. "|r"
  end
  return text
end

---Shows the rows of the last search from the scroll offset on.
function window:UpdateRows()
  local rows = self.rows
  self.offset = math.max(0, math.min(self.offset, #rows - #self.rowButtons))
  for index, button in ipairs(self.rowButtons) do
    local row = rows[self.offset + index]
    button.row = row
    if row then
      button.icon:SetTexture(row.icon or UNKNOWN_ICON)
      button.name:SetText(row.name)
      button.profession:SetText(self:ProfessionName(row.professionId))
      button.crafters:SetText(crafterLine(row))
      button.selected:SetShown(row.id == self.selectedId)
      button:Show()
    else
      button:Hide()
    end
  end
end

---Shows the status line: the loading of names, or what the last search found.
function window:UpdateStatus()
  local done, total = ns.professionNames.current:Progress()
  local text
  if done < total then
    text = "Loading names: " .. done .. " of " .. total
  elseif not self.searched then
    text = self.model:RecipeCount() .. " recipes are known in the guild."
  elseif self.total == 0 then
    text = "No recipe found."
  elseif self.total > #self.rows then
    text = "Showing " .. #self.rows .. " of " .. self.total .. " recipes. Type more to narrow the list."
  else
    text = self.total .. (self.total == 1 and " recipe." or " recipes.")
  end
  self.status:SetText(text)
  self.hint:SetShown(not self.searched)
end

---Returns the chat link of an item.
---@param itemId integer
---@return string|nil link nil while the client has not loaded the item
local function itemLinkOf(itemId)
  local _name, link = C_Item.GetItemInfo(itemId)
  if issecretvalue(link) or type(link) ~= "string" then
    return nil
  end
  return link
end

---Shows the tooltip of an item, or its name when the tooltip cannot show an item id.
---@param owner table The frame under the mouse
---@param itemId integer
---@param name string|nil
local function showItemTooltip(owner, itemId, name)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if type(GameTooltip.SetItemByID) == "function" then
    GameTooltip:SetItemByID(itemId)
  else
    GameTooltip:AddLine(name or ("#" .. itemId))
  end
  GameTooltip:Show()
end

---Returns the square of a material, and builds it when it is first needed: the icon of the item with the
---count at the bottom right. The mouse shows the item, a shift-click puts its link into the chat box.
---@param index integer Position among the materials
---@return table button
function window:ReagentButton(index)
  local button = self.reagentButtons[index]
  if button then
    return button
  end
  button = CreateFrame("Button", nil, self.pane)
  self.reagentButtons[index] = button
  button:SetSize(REAGENT_SIZE, REAGENT_SIZE)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints()
  button.icon = icon
  local count = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  -- The font of the template in a larger size and with an outline, so that it reads on any icon
  local font = count:GetFont()
  if type(font) == "string" then
    count:SetFont(font, REAGENT_COUNT_FONT, "OUTLINE")
  end
  count:SetPoint("BOTTOMRIGHT", -1, 2)
  count:SetJustifyH("RIGHT")
  button.count = count
  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  button:SetScript("OnEnter", function(entered)
    if entered.itemId then
      showItemTooltip(entered, entered.itemId, entered.itemName)
    end
  end)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  button:SetScript("OnClick", function(clicked)
    local handle = _G.HandleModifiedItemClick
    local link = clicked.itemId and itemLinkOf(clicked.itemId)
    if link and type(handle) == "function" then
      handle(link)
    end
  end)
  return button
end

---Returns the icon of an item.
---@param itemId integer
---@return any texture The question mark when the client gives none
local function itemIcon(itemId)
  -- A Retail function that was not probed on Forever, so it is used only when it is there
  local iconOf = C_Item.GetItemIconByID
  local icon = type(iconOf) == "function" and iconOf(itemId) or nil
  if icon == nil or issecretvalue(icon) then
    return UNKNOWN_ICON
  end
  return icon
end

---Shows the detail of the selected recipe: its icon and its name as a link, its materials as squares with
---counts, and the members who know it.
function window:UpdateDetail()
  local recipeId = self.selectedId
  if not recipeId then
    self.pane:Hide()
    return
  end
  local detail = self.model:Detail(recipeId)
  self.pane:Show()
  self.craftIcon:SetTexture(detail.icon or UNKNOWN_ICON)
  local craftLink = self.craftLink
  craftLink.link = linkOf(recipeId, detail.itemId)
  craftLink.recipeId, craftLink.itemId, craftLink.name = recipeId, detail.itemId, detail.name
  -- Always in the yellow of a craft link, whatever colour the link of the client has
  craftLink.text:SetText(TITLE_COLOR .. "[" .. detail.name .. "]|r")
  local info = self:ProfessionName(detail.professionId)
  if detail.count > 1 then
    info = info .. (info ~= "" and ", " or "") .. "makes " .. detail.count
  end
  self.craftInfo:SetText(info)

  local perRow = math.max(1, math.floor((DETAIL_WIDTH - 2 * DETAIL_INSET + REAGENT_GAP) / (REAGENT_SIZE + REAGENT_GAP)))
  local reagentCount = #detail.reagents
  for index, reagent in ipairs(detail.reagents) do
    local button = self:ReagentButton(index)
    button.itemId, button.itemName = reagent.itemId, reagent.name
    button.icon:SetTexture(itemIcon(reagent.itemId))
    button.count:SetText(reagent.count)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", self.materialsTitle, "BOTTOMLEFT",
      ((index - 1) % perRow) * (REAGENT_SIZE + REAGENT_GAP),
      -4 - math.floor((index - 1) / perRow) * (REAGENT_SIZE + REAGENT_GAP))
    button:Show()
  end
  for index = reagentCount + 1, #self.reagentButtons do
    self.reagentButtons[index]:Hide()
  end
  self.materialsTitle:SetShown(reagentCount > 0)
  local reagentRows = math.ceil(reagentCount / perRow)
  -- The list of members starts below the squares, or in their place when the recipe has no material
  self.detail:ClearAllPoints()
  if reagentCount > 0 then
    self.detail:SetPoint("TOPLEFT", self.materialsTitle, "BOTTOMLEFT", 0,
      -4 - reagentRows * (REAGENT_SIZE + REAGENT_GAP) - 6)
  else
    self.detail:SetPoint("TOPLEFT", self.materialsTitle, "TOPLEFT")
  end
  self.detail:SetPoint("BOTTOMRIGHT", self.pane, "BOTTOMRIGHT")

  local lines = { TITLE_COLOR .. "Known by|r" }
  for index = 1, math.min(#detail.crafters, DETAIL_MEMBERS) do
    local crafter = detail.crafters[index]
    lines[#lines + 1] = "  " .. (crafter.online and ONLINE_COLOR or OFFLINE_COLOR) .. plain(crafter.name) .. "  "
        .. "skill:" .. crafter.level .. (crafter.online and "  (online)" or "") .. "|r"
  end
  if #detail.crafters > DETAIL_MEMBERS then
    lines[#lines + 1] = OFFLINE_COLOR .. "  +" .. (#detail.crafters - DETAIL_MEMBERS) .. " more|r"
  elseif #detail.crafters == 0 then
    lines[#lines + 1] = OFFLINE_COLOR .. "  nobody any more|r"
  end
  self.detail:SetText(table.concat(lines, "\n"))
end

---Handles a click on the name of the selected recipe as the chat frame handles a click on a link: a plain
---click opens the link in the link tooltip, a shift-click puts it into the chat box.
---@param button table The link button, with `link`
---@param mouseButton string
function window:OnCraftLinkClick(button, mouseButton)
  local link = button.link
  if not link then
    return
  end
  local data = link:match("|H(.-)|h")
  local setItemRef = _G.SetItemRef
  if data and type(setItemRef) == "function" then
    setItemRef(data, link, mouseButton, self.frame)
  end
end

---Runs the search with the texts of the two boxes and shows the result.
function window:RunSearch()
  if not self.frame or not self.frame:IsShown() then
    return
  end
  local recipeText, materialText = self.recipeBox:GetText(), self.materialBox:GetText()
  self.searched = ns.professionSearch.needle(recipeText) ~= nil or ns.professionSearch.needle(materialText) ~= nil
  self.rows, self.total = self.model:Search(recipeText, materialText)
  self:UpdateRows()
  self:UpdateStatus()
  self:UpdateDetail()
end

---Asks for a search after a delay. A later call replaces an earlier one that has not run yet.
---@param delay number Seconds
function window:ScheduleSearch(delay)
  self.searchToken = self.searchToken + 1
  local token = self.searchToken
  C_Timer.After(delay, function()
    if token == window.searchToken then
      window:RunSearch()
    end
  end)
end

---Handles a click on a row: a modified click (shift) hands the link to the game, which puts it into the
---chat box; a plain click shows the detail.
---@param row OOOOProfessionRow
function window:OnRowClick(row)
  local handle = _G.HandleModifiedItemClick
  local link = linkOf(row.id, row.itemId)
  if link and type(handle) == "function" and handle(link) then
    return
  end
  self.selectedId = row.id
  self:UpdateRows()
  self:UpdateDetail()
end

---Shows the tooltip of what a row makes.
---@param button table A row button with `row`
local function showRowTooltip(button)
  local row = button.row ---@type OOOOProfessionRow|nil
  if not row then
    return
  end
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  if row.itemId and type(GameTooltip.SetItemByID) == "function" then
    GameTooltip:SetItemByID(row.itemId)
  elseif type(GameTooltip.SetSpellByID) == "function" then
    GameTooltip:SetSpellByID(row.id)
  else
    GameTooltip:AddLine(row.name)
  end
  GameTooltip:Show()
end

---Builds one row button of the result list.
---@param parent table The list frame
---@param index integer Position from the top
---@param width number
---@return table button
local function createRow(parent, index, width)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(width, ROW_HEIGHT)
  button:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  local selected = button:CreateTexture(nil, "BACKGROUND")
  selected:SetAllPoints()
  selected:SetColorTexture(1, 0.82, 0, 0.15)
  button.selected = selected
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("LEFT", 2, 0)
  button.icon = icon
  local profession = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  profession:SetPoint("TOPRIGHT", -4, -4)
  profession:SetJustifyH("RIGHT")
  button.profession = profession
  local name = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
  name:SetPoint("RIGHT", profession, "LEFT", -6, 0)
  name:SetJustifyH("LEFT")
  name:SetWordWrap(false)
  button.name = name
  local crafters = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  crafters:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 0)
  crafters:SetPoint("RIGHT", -4, 0)
  crafters:SetJustifyH("LEFT")
  crafters:SetWordWrap(false)
  button.crafters = crafters
  button:SetScript("OnClick", function(clicked)
    if clicked.row then
      window:OnRowClick(clicked.row)
    end
  end)
  button:SetScript("OnEnter", showRowTooltip)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  return button
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---Builds one search box with its label.
---@param parent table The window
---@param labelText string
---@param anchor table|nil The widget to the left; nil for the first box
---@return table editBox
local function createSearchBox(parent, labelText, anchor)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if anchor then
    label:SetPoint("LEFT", anchor, "RIGHT", 24, 0)
  else
    label:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + 8))
  end
  label:SetText(labelText)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(190, 20)
  box:SetPoint("LEFT", label, "RIGHT", 10, 0)
  box:SetAutoFocus(false)
  box:SetMaxLetters(40)
  box:SetScript("OnTextChanged", function()
    window:ScheduleSearch(SEARCH_DELAY)
  end)
  box:SetScript("OnEnterPressed", function(pressed)
    pressed:ClearFocus()
    window:ScheduleSearch(0)
  end)
  -- The first Escape leaves the box, the second one closes the window
  box:SetScript("OnEscapePressed", function(pressed)
    pressed:ClearFocus()
  end)
  return box
end

---Builds the frames of the window and its model.
---@return table frame
function window:Create()
  local model = ns.professionSearch.new({
    sync = ns.sync,
    facts = ns.professionRecipes.Facts,
    names = ns.professionNames.current,
    isOnline = function(name)
      return ns.guildState:IsOnline(name) == true
    end,
  })
  self.model = model
  model.onChanged = function()
    window:ScheduleSearch(REFRESH_DELAY)
  end

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

  self.recipeBox = createSearchBox(frame, "Recipe:", nil)
  self.materialBox = createSearchBox(frame, "Material:", self.recipeBox)

  local top = HEADER_HEIGHT + SEARCH_HEIGHT + PADDING
  local listWidth = WIDTH - DETAIL_WIDTH - 3 * PADDING
  local listHeight = HEIGHT - top - STATUS_HEIGHT - 2 * PADDING
  local list = CreateFrame("Frame", nil, frame)
  list:SetSize(listWidth, listHeight)
  list:SetPoint("TOPLEFT", PADDING, -top)
  self.rowButtons = {}
  for index = 1, math.floor(listHeight / ROW_HEIGHT) do
    self.rowButtons[index] = createRow(list, index, listWidth)
  end
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_list, delta)
    window.offset = window.offset - delta
    window:UpdateRows()
  end)

  local hint = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  hint:SetPoint("TOPLEFT", 6, -6)
  hint:SetJustifyH("LEFT")
  hint:SetText(HINT)
  self.hint = hint

  local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", PADDING, PADDING)
  status:SetJustifyH("LEFT")
  self.status = status

  -- The inset of the detail part: a darker field with a white border. It stays when no recipe is selected.
  local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  inset:SetPoint("TOPLEFT", list, "TOPRIGHT", PADDING, 0)
  inset:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
  inset:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  inset:SetBackdropColor(0, 0, 0, 0.5)
  inset:SetBackdropBorderColor(1, 1, 1, 0.8)
  local pane = CreateFrame("Frame", nil, inset)
  pane:SetPoint("TOPLEFT", DETAIL_INSET, -DETAIL_INSET)
  pane:SetPoint("BOTTOMRIGHT", -DETAIL_INSET, DETAIL_INSET)
  pane:Hide()
  self.pane = pane
  local craftIcon = pane:CreateTexture(nil, "ARTWORK")
  craftIcon:SetSize(CRAFT_ICON_SIZE, CRAFT_ICON_SIZE)
  craftIcon:SetPoint("TOPLEFT")
  self.craftIcon = craftIcon
  local craftLink = CreateFrame("Button", nil, pane)
  craftLink:SetPoint("TOPLEFT", craftIcon, "TOPRIGHT", 6, 0)
  craftLink:SetPoint("RIGHT")
  craftLink:SetHeight(CRAFT_ICON_SIZE / 2)
  local linkText = craftLink:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  linkText:SetAllPoints()
  linkText:SetJustifyH("LEFT")
  linkText:SetWordWrap(false)
  craftLink.text = linkText
  craftLink:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  craftLink:SetScript("OnClick", function(clicked, mouseButton)
    window:OnCraftLinkClick(clicked, mouseButton)
  end)
  craftLink:SetScript("OnEnter", function(entered)
    if entered.itemId then
      showItemTooltip(entered, entered.itemId, entered.name)
    elseif entered.recipeId and type(GameTooltip.SetSpellByID) == "function" then
      GameTooltip:SetOwner(entered, "ANCHOR_RIGHT")
      GameTooltip:SetSpellByID(entered.recipeId)
      GameTooltip:Show()
    end
  end)
  craftLink:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  self.craftLink = craftLink
  local craftInfo = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  craftInfo:SetPoint("BOTTOMLEFT", craftIcon, "BOTTOMRIGHT", 6, 2)
  craftInfo:SetPoint("RIGHT")
  craftInfo:SetJustifyH("LEFT")
  craftInfo:SetWordWrap(false)
  self.craftInfo = craftInfo
  local materialsTitle = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  materialsTitle:SetPoint("TOPLEFT", craftIcon, "BOTTOMLEFT", 0, -10)
  materialsTitle:SetText("Materials")
  self.materialsTitle = materialsTitle

  local detail = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detail:SetJustifyH("LEFT")
  detail:SetJustifyV("TOP")
  detail:SetWordWrap(true)
  self.detail = detail

  -- The game hides and shows the window with the whole interface too, so the model follows the frame
  frame:SetScript("OnShow", function()
    model:Open()
    ns.professionNames.current.RegisterCallback(window, "OnNamesChanged", function()
      window:ScheduleSearch(REFRESH_DELAY)
    end)
    ns.guildState.RegisterCallback(window, "OnRosterChanged", function()
      window:ScheduleSearch(REFRESH_DELAY)
    end)
    -- The names of all materials, so that the search by material finds them; requested in small groups
    model:PrepareNames(C_Timer.After, function()
      window:UpdateStatus()
    end)
    window:RunSearch()
  end)
  frame:SetScript("OnHide", function()
    ns.professionNames.current.UnregisterCallback(window, "OnNamesChanged")
    ns.guildState.UnregisterCallback(window, "OnRosterChanged")
    model:Close()
  end)

  -- Escape closes the frames that this list names
  local special = _G.UISpecialFrames
  if type(special) == "table" then
    special[#special + 1] = FRAME_NAME
  end
  return frame
end

---Shows the window.
---@return boolean opened false when the shared database or the item names are not ready
function window:Open()
  if not ns.sync.data or not ns.professionNames.current then
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

ns.slash:Register("prof", "prof - open or close the guild professions window", function()
  window:Toggle()
end)
