local addonName, ns = ...

-- The tab "Recipes" of the addon window (.agents/00-plan.md, section 5.4 and step 12.7): AceGUI-3.0 widgets
-- over the model of Professions/ProfessionSearch.lua. Two search boxes, the list of found recipes, and the
-- detail of the clicked recipe.
--
-- It calls no protected function. It does not whisper a crafter: opening a chat from addon code is a
-- protected call.
--
-- Not checked on Forever when this was written: the tooltip methods `SetItemByID` and `SetSpellByID`, and
-- `C_Item.GetItemIconByID` for the icons of the materials. Each is looked up before it is used.

---@class OOOOProfessionSearchTab
---@field model OOOOProfessionSearch|nil The search model; made when the tab is first shown
---@field results table|nil AceGUI ScrollFrame with the found recipes; nil while the tab is not shown
---@field detail table|nil AceGUI ScrollFrame with the detail of the selected recipe
---@field recipeText string Text of the box "Recipe"; kept while the tab is not shown
---@field materialText string Text of the box "Material"
---@field rows OOOOProfessionRow[] The result of the last search
---@field rowLabels table<integer, table> Recipe id -> the label of its row
---@field total integer How many recipes matched the last search
---@field searched boolean|nil true when the last search had a text
---@field selectedId integer|nil The recipe that the detail part shows
---@field searchToken integer Counts the scheduled searches, so that only the last one runs
---@field tooltipShown boolean|nil true while a tooltip of this tab is shown
local tab = { recipeText = "", materialText = "", rows = {}, rowLabels = {}, total = 0, searchToken = 0 }
ns.professionSearchTab = tab

local AceGUI = LibStub("AceGUI-3.0")

---Id of the tab in the addon window
local TAB_ID = "recipes"
---Width of the detail part at the right side. The label of the recipe keeps its icon at the left only
---while 200 pixels are left for the text.
local DETAIL_WIDTH = 310
---Width of one search box
local BOX_WIDTH = 220
---Side of the icon of a row
local ICON_SIZE = 28
---Seconds between the last key and the search
local SEARCH_DELAY = 0.3
---Seconds for which changes of the table, the roster, and the names are collected before a new search
local REFRESH_DELAY = 0.5
---Names of members in a row before the rest is counted
local ROW_NAMES = 4
---Members that the detail part lists before the rest is counted
local DETAIL_MEMBERS = 100
---Side of the icon of the selected recipe in the detail part
local CRAFT_ICON_SIZE = 36
---Side of the icon of one material, and the width of its widget
local REAGENT_SIZE, REAGENT_WIDTH = 32, 46
---Icon of a recipe without one: the question mark
local UNKNOWN_ICON = 134400
---Texture under the mouse on a row
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
---Background of the selected row: silver, with its alpha
local SELECTION_COLOR = { 0.75, 0.75, 0.75, 0.25 }
local HINT = "Type a part of a recipe name, or of the name of a material, with 2 letters or more."
local DETAIL_HINT = "Click a recipe to see its materials and the members who know it."
local ONLINE_COLOR, OFFLINE_COLOR, TITLE_COLOR, SELECTED_COLOR = "|cffffffff", "|cff808080", "|cffffd100", "|cff40ff40"

---Makes a text of another member safe to show: a character name comes from the key of a received record.
---@param text string
---@return string
local function plain(text)
  return (text:gsub("|", "||"))
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

---Returns the chat link of what a recipe makes: the item, or what the client links for a recipe without one.
---@param recipeId integer
---@param itemId integer|nil
---@return string|nil link nil when the client has none, or not yet
local function linkOf(recipeId, itemId)
  local link = itemId and itemLinkOf(itemId) or nil
  if link == nil then
    link = C_TradeSkillUI.GetRecipeItemLink(recipeId)
  end
  if issecretvalue(link) or type(link) ~= "string" then
    return nil
  end
  return link
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

--------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------

---Hides the tooltip of this tab, when one is shown: its widget may be about to be released.
function tab:HideTooltip()
  if self.tooltipShown then
    self.tooltipShown = false
    GameTooltip:Hide()
  end
end

---Shows the tooltip of an item or of a craft spell, or a name when the tooltip can show neither.
---@param owner table The frame under the mouse
---@param itemId integer|nil
---@param recipeId integer|nil
---@param name string|nil
function tab:ShowTooltip(owner, itemId, recipeId, name)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if itemId and type(GameTooltip.SetItemByID) == "function" then
    GameTooltip:SetItemByID(itemId)
  elseif recipeId and not itemId and type(GameTooltip.SetSpellByID) == "function" then
    GameTooltip:SetSpellByID(recipeId)
  else
    GameTooltip:AddLine(name or ("#" .. (itemId or recipeId or 0)))
  end
  GameTooltip:Show()
  self.tooltipShown = true
end

---Connects the tooltip to a widget that fires "OnEnter" and "OnLeave".
---@param widget table AceGUI widget
---@param itemId integer|nil
---@param recipeId integer|nil
---@param name string|nil
local function setTooltip(widget, itemId, recipeId, name)
  widget:SetCallback("OnEnter", function(entered)
    tab:ShowTooltip(entered.frame, itemId, recipeId, name)
  end)
  widget:SetCallback("OnLeave", function()
    tab:HideTooltip()
  end)
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

---Builds the text of a row: the name of the recipe and its profession, and below them the members.
---@param row OOOOProfessionRow
---@param selected boolean true for the recipe that the detail part shows
---@return string
local function rowText(row, selected)
  return (selected and SELECTED_COLOR or TITLE_COLOR) .. row.name .. "|r  " .. OFFLINE_COLOR
    .. ns.professionRecipes.ProfessionName(row.professionId) .. "|r\n" .. crafterLine(row)
end

---Hides the background of a row when AceGUI takes the row back.
---@param label table AceGUI InteractiveLabel
local function hideSelection(label)
  label.frame.ooooSelection:Hide()
end

---Shows or hides the silver background of a row. AceGUI keeps the frame of a released label for the next
---label of any window, so the texture is made once per frame and hidden when the row is released.
---@param label table AceGUI InteractiveLabel
---@param selected boolean true for the recipe that the detail part shows
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

---Shows the rows of the last search, or the hint while nothing was searched.
function tab:UpdateRows()
  local scroll = self.results
  self:HideTooltip()
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.rowLabels = {}
  if not self.searched then
    local hint = AceGUI:Create("Label")
    hint:SetFullWidth(true)
    hint:SetFontObject(GameFontDisable)
    hint:SetText(HINT)
    scroll:AddChild(hint)
  end
  for _, row in ipairs(self.rows) do
    local label = AceGUI:Create("InteractiveLabel")
    label:SetFullWidth(true)
    label:SetFontObject(GameFontHighlight)
    label:SetImage(row.icon or UNKNOWN_ICON)
    label:SetImageSize(ICON_SIZE, ICON_SIZE)
    label:SetText(rowText(row, row.id == self.selectedId))
    label:SetHighlight(ROW_HIGHLIGHT)
    setSelection(label, row.id == self.selectedId)
    label:SetCallback("OnClick", function()
      tab:OnRowClick(row)
    end)
    setTooltip(label, row.itemId, row.id, row.name)
    self.rowLabels[row.id] = label
    scroll:AddChild(label)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

---Shows the status line of the window: the loading of names, or what the last search found.
function tab:UpdateStatus()
  if not self.results then
    return
  end
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
  ns.mainWindow:SetStatus(text)
end

---Handles a click on a row: a modified click (shift) hands the link to the game, which puts it into the
---chat box; a plain click shows the detail.
---@param row OOOOProfessionRow
function tab:OnRowClick(row)
  local handle = _G.HandleModifiedItemClick
  local link = linkOf(row.id, row.itemId)
  if link and type(handle) == "function" and handle(link) then
    return
  end
  local previous = self.selectedId
  self.selectedId = row.id
  -- Only the texts change: the clicked row is not released inside its own click
  for _, shown in ipairs(self.rows) do
    if shown.id == previous or shown.id == row.id then
      local label = self.rowLabels[shown.id]
      if label then
        label:SetText(rowText(shown, shown.id == row.id))
        setSelection(label, shown.id == row.id)
      end
    end
  end
  self:UpdateDetail()
end

--------------------------------------------------------------------------------
-- The detail part
--------------------------------------------------------------------------------

---Handles a click on the name of the selected recipe as the chat frame handles a click on a link: a plain
---click opens the link in the link tooltip, a shift-click puts it into the chat box.
---@param link string|nil The chat link of the recipe
---@param mouseButton string
function tab:OnCraftLinkClick(link, mouseButton)
  if not link then
    return
  end
  local data = link:match("|H(.-)|h")
  local setItemRef = _G.SetItemRef
  if data and type(setItemRef) == "function" then
    setItemRef(data, link, mouseButton, ns.mainWindow.frame.frame)
  end
end

---Adds the icon of one material to the detail part: the item with the needed count below it. The mouse
---shows the item, a shift-click puts its link into the chat box.
---@param scroll table The AceGUI container of the detail part
---@param reagent { itemId: integer, count: integer, name: string|nil }
local function addReagent(scroll, reagent)
  local icon = AceGUI:Create("Icon")
  icon:SetImage(itemIcon(reagent.itemId))
  icon:SetLabel("x" .. reagent.count)
  icon:SetImageSize(REAGENT_SIZE, REAGENT_SIZE)
  icon:SetWidth(REAGENT_WIDTH)
  icon:SetCallback("OnClick", function()
    local handle = _G.HandleModifiedItemClick
    local link = itemLinkOf(reagent.itemId)
    if link and type(handle) == "function" then
      handle(link)
    end
  end)
  setTooltip(icon, reagent.itemId, nil, reagent.name)
  scroll:AddChild(icon)
end

---Adds a heading to the detail part.
---@param scroll table
---@param text string
local function addHeading(scroll, text)
  local heading = AceGUI:Create("Heading")
  heading:SetText(text)
  -- An AceGUI heading is not full width by itself: in the flow layout it would share a row with an icon
  heading:SetFullWidth(true)
  scroll:AddChild(heading)
end

---Shows the detail of the selected recipe: its icon and its name as a link, its materials as icons with
---counts, and the members who know it.
function tab:UpdateDetail()
  local scroll = self.detail
  self:HideTooltip()
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  local recipeId = self.selectedId
  if not recipeId then
    local hint = AceGUI:Create("Label")
    hint:SetFullWidth(true)
    hint:SetFontObject(GameFontDisable)
    hint:SetText(DETAIL_HINT)
    scroll:AddChild(hint)
  else
    local detail = self.model:Detail(recipeId)
    local link = linkOf(recipeId, detail.itemId)
    local info = ns.professionRecipes.ProfessionName(detail.professionId)
    if detail.count > 1 then
      info = info .. (info ~= "" and ", " or "") .. "makes " .. detail.count
    end
    local craft = AceGUI:Create("InteractiveLabel")
    craft:SetFullWidth(true)
    craft:SetFontObject(GameFontHighlight)
    craft:SetImage(detail.icon or UNKNOWN_ICON)
    craft:SetImageSize(CRAFT_ICON_SIZE, CRAFT_ICON_SIZE)
    -- Always in the yellow of a craft link, whatever colour the link of the client has
    craft:SetText(TITLE_COLOR .. "[" .. detail.name .. "]|r\n" .. info)
    craft:SetCallback("OnClick", function(_widget, _event, mouseButton)
      tab:OnCraftLinkClick(link, mouseButton)
    end)
    setTooltip(craft, detail.itemId, recipeId, detail.name)
    scroll:AddChild(craft)

    if #detail.reagents > 0 then
      addHeading(scroll, "Materials")
      for _, reagent in ipairs(detail.reagents) do
        addReagent(scroll, reagent)
      end
    end

    addHeading(scroll, "Known by")
    local lines = {}
    for index = 1, math.min(#detail.crafters, DETAIL_MEMBERS) do
      local crafter = detail.crafters[index]
      lines[#lines + 1] = (crafter.online and ONLINE_COLOR or OFFLINE_COLOR) .. plain(crafter.name) .. "  "
        .. "skill:" .. crafter.level .. (crafter.online and "  (online)" or "") .. "|r"
    end
    if #detail.crafters > DETAIL_MEMBERS then
      lines[#lines + 1] = OFFLINE_COLOR .. "+" .. (#detail.crafters - DETAIL_MEMBERS) .. " more|r"
    elseif #detail.crafters == 0 then
      lines[#lines + 1] = OFFLINE_COLOR .. "nobody any more|r"
    end
    local members = AceGUI:Create("Label")
    members:SetFullWidth(true)
    members:SetFontObject(GameFontHighlight)
    members:SetText(table.concat(lines, "\n"))
    scroll:AddChild(members)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

--------------------------------------------------------------------------------
-- The search
--------------------------------------------------------------------------------

---Runs the search with the texts of the two boxes and shows the result.
function tab:RunSearch()
  if not self.results then
    return
  end
  local needle = ns.professionSearch.needle
  self.searched = needle(self.recipeText) ~= nil or needle(self.materialText) ~= nil
  self.rows, self.total = self.model:Search(self.recipeText, self.materialText)
  self:UpdateRows()
  self:UpdateStatus()
  self:UpdateDetail()
end

---Asks for a search after a delay. A later call replaces an earlier one that has not run yet.
---@param delay number Seconds
function tab:ScheduleSearch(delay)
  self.searchToken = self.searchToken + 1
  local token = self.searchToken
  C_Timer.After(delay, function()
    if token == tab.searchToken then
      tab:RunSearch()
    end
  end)
end

---Builds one search box.
---@param labelText string
---@param field string The field of the tab that holds the text of the box
---@return table editBox AceGUI EditBox
local function createSearchBox(labelText, field)
  local box = AceGUI:Create("EditBox")
  box:SetLabel(labelText)
  box:SetWidth(BOX_WIDTH)
  -- The search runs while the user types, so the box needs no button
  box:DisableButton(true)
  box:SetMaxLetters(40)
  box:SetText(tab[field])
  box:SetCallback("OnTextChanged", function(_widget, _event, text)
    tab[field] = text
    tab:ScheduleSearch(SEARCH_DELAY)
  end)
  box:SetCallback("OnEnterPressed", function(widget, _event, text)
    tab[field] = text
    widget:ClearFocus()
    tab:ScheduleSearch(0)
  end)
  return box
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

---Makes the search model on the shared database of the game.
---@return OOOOProfessionSearch
function tab:CreateModel()
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
    tab:ScheduleSearch(REFRESH_DELAY)
  end
  return model
end

---Builds the content of the tab: at the left the search boxes over the list, at the right the detail.
---@param container table The AceGUI tab group
function tab:Build(container)
  local model = self.model or self:CreateModel()
  model:Open()
  ns.professionNames.current.RegisterCallback(tab, "OnNamesChanged", function()
    tab:ScheduleSearch(REFRESH_DELAY)
  end)
  ns.guildState.RegisterCallback(tab, "OnRosterChanged", function()
    tab:ScheduleSearch(REFRESH_DELAY)
  end)

  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOOColumns")
  root:SetAutoAdjustHeight(false)

  local left = AceGUI:Create("SimpleGroup")
  left:SetLayout("OOOORows")
  left:SetAutoAdjustHeight(false)
  local boxes = AceGUI:Create("SimpleGroup")
  boxes:SetLayout("Flow")
  boxes:AddChild(createSearchBox("Recipe", "recipeText"))
  boxes:AddChild(createSearchBox("Material", "materialText"))
  left:AddChild(boxes)
  local results = AceGUI:Create("ScrollFrame")
  results:SetLayout("List")
  results:SetUserData("fill", true)
  left:AddChild(results)
  root:AddChild(left)

  local box = AceGUI:Create("InlineGroup")
  box:SetTitle("Recipe")
  box:SetLayout("Fill")
  box:SetAutoAdjustHeight(false)
  box:SetUserData("width", DETAIL_WIDTH)
  local detail = AceGUI:Create("ScrollFrame")
  detail:SetLayout("Flow")
  box:AddChild(detail)
  root:AddChild(box)

  container:AddChild(root)
  root:DoLayout()

  self.results, self.detail = results, detail
  -- The names of all materials, so that the search by material finds them; requested in small groups
  model:PrepareNames(C_Timer.After, function()
    tab:UpdateStatus()
  end)
  self:RunSearch()
end

---Forgets the widgets, which the window releases, and the index of the model. The texts of the boxes and
---the selected recipe stay.
function tab:Close()
  self:HideTooltip()
  self.searchToken = self.searchToken + 1
  self.results, self.detail, self.rowLabels = nil, nil, {}
  ns.professionNames.current.UnregisterCallback(tab, "OnNamesChanged")
  ns.guildState.UnregisterCallback(tab, "OnRosterChanged")
  if self.model then
    self.model:Close()
  end
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = "Recipes",
  order = 20,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
})
