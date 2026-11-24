local addonName, ns = ...

-- The one window of the addon: an AceGUI-3.0 frame with a tab per feature. `/oooo` opens and closes it.
-- A feature registers its tab at file scope (`RegisterTab`); the window builds the content of a tab when the
-- tab is selected and releases it when another tab is selected or the window closes.
--
-- The frame is not protected, so it may be shown, hidden, moved, and resized in combat.
--
-- Not checked on Forever when this was written: AceGUI-3.0 in a window of the addon itself. The settings
-- window (AceConfigDialog-3.0) is built from the same widgets and works in the client.

---@class OOOOMainWindowSettings `db.profile.window`: the status table of the AceGUI frame, and the tab
---@field width number
---@field height number
---@field top number|nil Top edge of the window; nil until the window was moved or resized
---@field left number|nil
---@field tab string|nil Id of the tab that was shown last

---@class OOOOMainWindowTab One tab of the window
---@field id string Short name: "chat"
---@field title string Text of the tab
---@field order number Place among the tabs, lowest first
---@field Build fun(container: table) Adds the content of the tab to the container, which has the layout
---"Fill": one child
---@field Close (fun())|nil Called before the content is released: the tab forgets its widgets
---@field IsVisible (fun(): boolean)|nil Tells whether the window has the tab; asked when the window opens.
---Without it the tab is always there.

---@class OOOOMainWindow
---@field tabs OOOOMainWindowTab[] The registered tabs
---@field byId table<string, OOOOMainWindowTab>
---@field frame table|nil The AceGUI frame; nil until the window is first opened. It is kept for the session.
---@field tabGroup table|nil The AceGUI tab group in it
---@field current OOOOMainWindowTab|nil The tab whose content is built; nil while the window is closed
---@field shownTabs string|nil The ids of the tabs that the tab group has, joined
---@field tabStatus string|nil What the shown tab has to say in the status line
local main = { tabs = {}, byId = {} }
ns.mainWindow = main

local AceGUI = LibStub("AceGUI-3.0")

---Global name of the frame: the game closes the frames of `UISpecialFrames` with Escape, by name
local FRAME_NAME = "OOOOMainFrame"
local WINDOW_TITLE = "OO OO Guild Companion"
---Smallest size that the user can give the window
local MIN_WIDTH, MIN_HEIGHT = 760, 420
---Space between two parts of the layouts below
local GAP = 8

--------------------------------------------------------------------------------
-- Layouts
--------------------------------------------------------------------------------

-- The layouts of AceGUI stack widgets or let them flow; none splits a container into parts that follow
-- the size of the window. A layout gets the content frame of a container and its children.

---Returns the size of a content frame.
---@param content table
---@return number width
---@return number height
local function sizeOf(content)
  return content.width or content:GetWidth() or 0, content.height or content:GetHeight() or 0
end

---Lays a child out again when it is a container.
---@param child table AceGUI widget
local function layoutChild(child)
  if child.DoLayout then
    child:DoLayout()
  end
end

---Children side by side, each as high as the container. A child with the user data "width" has that
---width; the others share the rest.
AceGUI:RegisterLayout("OOOOColumns", function(content, children)
  local width, height = sizeOf(content)
  local fixed, flexible = 0, 0
  for _, child in ipairs(children) do
    local own = child:GetUserData("width")
    if own then
      fixed = fixed + own
    else
      flexible = flexible + 1
    end
  end
  local share = flexible > 0 and math.max(0, (width - fixed - GAP * (#children - 1)) / flexible) or 0
  -- The width that AceGUI keeps for a content frame can differ from the width on the screen. So with one
  -- flexible child the places come from the two edges of the content frame, not from that number: the
  -- flexible column ends where the columns at its right begin, and the columns can never overlap.
  local fromEdges = flexible == 1
  local fixedTotal = fixed + GAP * (#children - 1)
  local x, before, flexibleSeen = 0, 0, false
  for _, child in ipairs(children) do
    local ownWidth = child:GetUserData("width")
    local own = ownWidth or share
    -- The fixed columns and the gaps at the right of this child
    local after = fixedTotal - before - (ownWidth or 0)
    local frame = child.frame
    frame:ClearAllPoints()
    if not (fromEdges and flexibleSeen) then
      frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, 0)
    end
    if fromEdges and (flexibleSeen or not ownWidth) then
      frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -after, 0)
    end
    flexibleSeen = flexibleSeen or not ownWidth
    child:SetWidth(own)
    child:SetHeight(height)
    frame:Show()
    layoutChild(child)
    x = x + own + GAP
    before = before + (ownWidth or 0) + GAP
  end
end)

---Children below each other, each as wide as the container. A child with the user data "fill" shares
---the height that the others leave; the others keep their own height.
AceGUI:RegisterLayout("OOOORows", function(content, children)
  local width, height = sizeOf(content)
  local fixed, flexible = 0, 0
  for _, child in ipairs(children) do
    child:SetWidth(width)
    if child:GetUserData("fill") then
      flexible = flexible + 1
    else
      -- The height of a label or of a flowing group follows its width
      layoutChild(child)
      fixed = fixed + (child.frame.height or child.frame:GetHeight() or 0)
    end
  end
  local share = flexible > 0 and math.max(0, (height - fixed - GAP * (#children - 1)) / flexible) or 0
  local y = 0
  for _, child in ipairs(children) do
    local frame = child.frame
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    -- The right edge follows the content frame on the screen, as in the columns above
    frame:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    if child:GetUserData("fill") then
      child:SetHeight(share)
      layoutChild(child)
    end
    frame:Show()
    y = y + (frame.height or frame:GetHeight() or 0) + GAP
  end
end)

---One line of a list: children side by side, each in the middle of the height. A child with the user data
---"width" has that width; one without it takes what is left. The container gets the height of its highest
---child.
AceGUI:RegisterLayout("OOOOLine", function(content, children)
  local width = sizeOf(content)
  local x, height = 0, 0
  for _, child in ipairs(children) do
    local own = child:GetUserData("width") or math.max(0, width - x)
    local frame = child.frame
    frame:ClearAllPoints()
    frame:SetPoint("LEFT", content, "LEFT", x, 0)
    child:SetWidth(own)
    frame:Show()
    height = math.max(height, frame.height or frame:GetHeight() or 0)
    x = x + own
  end
  local container = content.obj
  if container.LayoutFinished then
    container:LayoutFinished(nil, height)
  end
end)

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

---Adds a tab to the window. Called at file scope, before the window is first opened.
---@param tab OOOOMainWindowTab
function main:RegisterTab(tab)
  assert(not self.byId[tab.id], "tab registered twice: " .. tab.id)
  self.byId[tab.id] = tab
  self.tabs[#self.tabs + 1] = tab
  table.sort(self.tabs, function(left, right)
    return left.order < right.order
  end)
end

---Tells whether the window has a tab now.
---@param id string|nil
---@return boolean
function main:IsTabVisible(id)
  local tab = id and self.byId[id]
  if not tab then
    return false
  end
  return tab.IsVisible == nil or tab.IsVisible() == true
end

---Gives the tab group the tabs that are visible now (`IsVisible`). Called when the window opens, because a tab
---for officers follows the rank of the character, which the roster tells only some time after the login.
function main:UpdateTabs()
  local list, joined = {}, {}
  for _, tab in ipairs(self.tabs) do
    if self:IsTabVisible(tab.id) then
      list[#list + 1] = { value = tab.id, text = tab.title }
      joined[#joined + 1] = tab.id
    end
  end
  local shown = table.concat(joined, ",")
  if shown ~= self.shownTabs then
    self.shownTabs = shown
    self.tabGroup:SetTabs(list)
  end
end

---Releases the content of the shown tab.
function main:CloseTab()
  local tab = self.current
  if not tab then
    return
  end
  self.current = nil
  if tab.Close then
    tab.Close()
  end
  self.tabGroup:ReleaseChildren()
  self:SetStatus("")
end

---Builds the content of a tab in place of the one that is shown. The tab group calls it when a tab is
---selected.
---@param id string
function main:ShowTab(id)
  local tab = self.byId[id]
  if not tab or tab == self.current then
    return
  end
  self:CloseTab()
  self.current = tab
  ns.db.profile.window.tab = id
  tab.Build(self.tabGroup)
end

---Sets what the shown tab says in the status line at the bottom of the window.
---@param text string
function main:SetStatus(text)
  self.tabStatus = text
  self:UpdateStatus()
end

---Writes the status line: a sync that runs, in front of the text of the tab, so that a long text of the tab
---cannot cut it off.
function main:UpdateStatus()
  if not self.frame then
    return
  end
  local current = ns.syncSession.current
  local syncText = current and ns.syncSession.progressText(current:Progress())
  local tabText = self.tabStatus or ""
  if syncText and tabText ~= "" then
    self.frame:SetStatusText(syncText .. " - " .. tabText)
  else
    self.frame:SetStatusText(syncText or tabText)
  end
end

---Tells whether a tab is the one whose content is built.
---@param id string
---@return boolean
function main:IsShown(id)
  return self.current ~= nil and self.current.id == id
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---Builds the frame and its tab group. The frame is never released: its global name must stay the name of
---this window, and a released AceGUI frame is handed to the next addon that asks for one.
---@return table frame The AceGUI frame
function main:Create()
  local frame = AceGUI:Create("Frame")
  self.frame = frame
  frame:SetTitle(WINDOW_TITLE)
  frame:SetLayout("Fill")
  -- AceGUI writes the size and the place of the window into this table
  frame:SetStatusTable(ns.db.profile.window)
  if type(frame.frame.SetResizeBounds) == "function" then
    frame.frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
  end
  -- Fires when the frame is hidden: by its button, by Escape, or by `Toggle`
  frame:SetCallback("OnClose", function()
    main:CloseTab()
  end)

  local tabGroup = AceGUI:Create("TabGroup")
  self.tabGroup = tabGroup
  tabGroup:SetLayout("Fill")
  self:UpdateTabs()
  tabGroup:SetCallback("OnGroupSelected", function(_widget, _event, id)
    main:ShowTab(id)
  end)
  frame:AddChild(tabGroup)

  -- Escape closes the frames that this list names
  local special = _G.UISpecialFrames
  if type(special) == "table" then
    _G[FRAME_NAME] = frame.frame
    special[#special + 1] = FRAME_NAME
  end
  return frame
end

---Shows the window.
---@param tabId string|nil The tab to show; nil shows the tab that was shown last
---@return boolean opened false when the shared database is not ready
function main:Open(tabId)
  if not ns.sync.data or not ns.professionNames.current then
    ns.print("The shared database is not ready.")
    return false
  end
  local frame = self.frame or self:Create()
  self:UpdateTabs()
  self:UpdateStatus()
  frame:Show()
  local saved = ns.db.profile.window.tab
  local id = (self:IsTabVisible(tabId) and tabId) or (self:IsTabVisible(saved) and saved) or nil
  if not id then
    for _, tab in ipairs(self.tabs) do
      if self:IsTabVisible(tab.id) then
        id = tab.id
        break
      end
    end
  end
  if id and not self:IsShown(id) then
    -- Fires "OnGroupSelected", which builds the content
    self.tabGroup:SelectTab(id)
  end
  return true
end

---Opens the window, or closes it when it is open.
function main:Toggle()
  if self.frame and self.frame.frame:IsShown() then
    self.frame:Hide()
  else
    self:Open()
  end
end

ns.slash:SetDefault("open or close the addon window", function()
  main:Toggle()
end)

---The action of Bindings.xml, and the key that it gets on the first login
local BINDING_ACTION = "OOOOGC_TOGGLEWINDOW"
local DEFAULT_KEY = "ALT-O"

-- The label of the action in the key bindings of the game (section "AddOns")
_G["BINDING_NAME_" .. BINDING_ACTION] = "Show OOOO Window"

---Called by the key binding of Bindings.xml, which runs in the global scope.
function _G.OOOOguildcompanion_ToggleWindow()
  main:Toggle()
end

---Gives the action its default key, once per binding set. A binding of an addon cannot name a default key
---in Bindings.xml, so the key is set here and saved; after that the choice of the user stands, also when
---they remove the key. A key that is in use is not taken.
function main:ApplyDefaultKey()
  -- SetBinding is refused in combat (a reload in a fight); the next login tries again
  if InCombatLockdown() then
    return
  end
  local set = GetCurrentBindingSet()
  -- Set 1 is shared by the account, set 2 belongs to the character
  local store = set == 1 and ns.db.global or ns.db.char
  if store.defaultKeySet then
    return
  end
  if GetBindingKey(BINDING_ACTION) then
    store.defaultKeySet = true
    return
  end
  local used = GetBindingAction(DEFAULT_KEY)
  if used and used ~= "" then
    store.defaultKeySet = true
    ns.print("Alt+O is in use. Choose a key for the addon window in the key bindings, section AddOns.")
    return
  end
  if SetBinding(DEFAULT_KEY, BINDING_ACTION) then
    SaveBindings(set)
    store.defaultKeySet = true
  end
end
