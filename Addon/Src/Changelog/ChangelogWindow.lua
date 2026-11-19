local addonName, ns = ...

-- The window "What's new" (`/oooo new`): the releases at the left, the notes of the selected release on a
-- parchment page at the right, and the buttons Newer and Older below. Also the line after login with the
-- link that opens the window.
--
-- The notes are `ns.changelog` and the release version is `ns.version`, both from the generated file
-- Changelog/ChangelogData.lua (scripts/release_tool.py writes it from CHANGELOG.md).
--
-- The frame is not protected, so it may be shown, hidden, and moved in combat.
--
-- Not checked on Forever when this was written: the templates ButtonFrameTemplate, InsetFrameTemplate, and
-- UIPanelScrollFrameTemplate, the atlases, and the fonts QuestTitleFont and QuestFont. Each has a fallback.

---@class OOOOChangelogItem One change
---@field lead string The heading of the change
---@field text string The explanation; `code` in backticks; can be empty

---@class OOOOChangelogSection
---@field title string
---@field items OOOOChangelogItem[]

---@class OOOOChangelogRelease
---@field version string As `VERSION` of scripts/release_tool.py: "2026.11.2"
---@field date string "2026-11-19"
---@field sections OOOOChangelogSection[]

---@class OOOOChangelogSettings `db.profile.changelog`: where the user left the window
---@field point string|nil Anchor point of the window; nil until the window was moved
---@field relativePoint string|nil Anchor point of the screen
---@field x number|nil
---@field y number|nil

---@class OOOOChangelogWindow
---@field frame table|nil The window; nil until it is first opened
---@field selected integer Index of the shown release in `ns.changelog`
---@field firstShown integer Index of the release in the first visible row of the list
---@field strings table[] Font strings of the page, reused by every render
---@field textures table[] Textures of the page, reused by every render
---@field usedStrings integer
---@field usedTextures integer
local window = { selected = 1, firstShown = 1, strings = {}, textures = {}, usedStrings = 0, usedTextures = 0 }
ns.changelogWindow = window

---Global name of the frame: the game closes the frames of `UISpecialFrames` with Escape, by name
local FRAME_NAME = "OOOOChangelogFrame"
local ADDON_TITLE = "OO OO Guild Companion"
---The data of the hyperlink in the line after login; see `ns.mentions.RegisterLink` for how a click arrives
local LINK = "addon:" .. addonName .. ":changelog"
---Seconds after the guild check at which the line is printed, so that the login messages do not bury it
local NOTICE_DELAY = 4

local WIDTH, HEIGHT = 840, 580
local LIST_WIDTH = 330
local ROW_HEIGHT = 42
---The list runs from LIST_TOP below the top of the window to LIST_BOTTOM above its bottom; its rows start
---ROWS_TOP below its top
local LIST_TOP, LIST_BOTTOM, ROWS_TOP = 62, 44, 46
---Space between the edge of the page and its text, at the left and at the right
local PAGE_MARGIN = 40
local CONTENT_WIDTH = WIDTH - LIST_WIDTH - 34 - 2 * PAGE_MARGIN
---Pixels that one step of the mouse wheel scrolls when the scroll frame has no scroll bar of its own
local WHEEL_STEP = 40

---Ink on the parchment, like quest text
local INK = { 0.18, 0.10, 0.02 }
local INK_SOFT = { 0.32, 0.22, 0.12 }
---Colour of a section heading and of its bullets, by the title of the section
local SECTION_COLORS = {
  New = { 0.10, 0.45, 0.10 },
  Changed = { 0.12, 0.30, 0.62 },
  Fixed = { 0.70, 0.36, 0.05 },
}
---Colour of a section with another title
local SECTION_COLOR = { 0.12, 0.30, 0.62 }
---Colour code of `code` in the text of a change
local CODE_COLOR = "|cff14306e"
---Anchor points that a saved position may name
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

---Returns the releases, newest first; empty when the generated file is missing.
---@return OOOOChangelogRelease[]
local function releases()
  return ns.changelog or {}
end

---Creates a frame from a template that the client may lack.
---@param frameType string
---@param name string|nil
---@param parent table
---@param template string
---@return table|nil frame nil when the client refused
local function tryCreate(frameType, name, parent, template)
  local created, frame = pcall(CreateFrame, frameType, name, parent, template)
  return created and frame or nil
end

---Tells whether the client has a texture atlas.
---@param name string
---@return boolean
local function hasAtlas(name)
  local api = _G.C_Texture
  return type(api) == "table" and type(api.GetAtlasInfo) == "function" and api.GetAtlasInfo(name) ~= nil
end

---Gives a font string the font of a font object at another size.
---@param fontString table
---@param fontName string Global name of the font object; GameFontHighlight when the client lacks it
---@param size number
local function sizedFont(fontString, fontName, size)
  local fontObject = _G[fontName] or GameFontHighlight
  local path, _, flags = fontObject:GetFont()
  fontString:SetFont(path, size, flags)
end

---Turns the text of a change into the text of a font string: a `|` is shown as it is, and `code` in
---backticks gets its colour.
---@param text string
---@return string
local function formatText(text)
  return (text:gsub("|", "||"):gsub("`([^`]+)`", CODE_COLOR .. "%1|r"))
end

---Counts the changes of a release.
---@param release OOOOChangelogRelease
---@return integer
local function countChanges(release)
  local count = 0
  for _, section in ipairs(release.sections) do
    count = count + #section.items
  end
  return count
end

---@param count integer
---@return string text "1 change", "5 changes"
local function changesText(count)
  return count .. (count == 1 and " change" or " changes")
end

---Stores where the user left the window.
---@param frame table
local function savePosition(frame)
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  local settings = ns.db.profile.changelog
  settings.point, settings.relativePoint, settings.x, settings.y = point, relativePoint, x, y
end

---Puts the window where the user left it, or in the middle of the screen.
---@param frame table
local function restorePosition(frame)
  local settings = ns.db.profile.changelog
  frame:ClearAllPoints()
  if POINTS[settings.point] and POINTS[settings.relativePoint] and type(settings.x) == "number"
    and type(settings.y) == "number" then
    frame:SetPoint(settings.point, UIParent, settings.relativePoint, settings.x, settings.y)
  else
    frame:SetPoint("CENTER")
  end
end

--------------------------------------------------------------------------------
-- The page
--------------------------------------------------------------------------------

---Returns a font string of the page, a reused one when the pool has one.
---@param fontName string Global name of a font object
---@param size number
---@param color number[]
---@return table fontString
function window:PageString(fontName, size, color)
  self.usedStrings = self.usedStrings + 1
  local fontString = self.strings[self.usedStrings]
  if not fontString then
    fontString = self.frame.content:CreateFontString(nil, "OVERLAY")
    self.strings[self.usedStrings] = fontString
  end
  sizedFont(fontString, fontName, size)
  fontString:SetTextColor(color[1], color[2], color[3])
  fontString:SetShadowOffset(0, 0)
  fontString:SetJustifyH("LEFT")
  fontString:SetWordWrap(true)
  fontString:SetSpacing(0)
  fontString:ClearAllPoints()
  fontString:Show()
  return fontString
end

---Returns a texture of the page, a reused one when the pool has one.
---@return table texture
function window:PageTexture()
  self.usedTextures = self.usedTextures + 1
  local texture = self.textures[self.usedTextures]
  if not texture then
    texture = self.frame.content:CreateTexture(nil, "ARTWORK")
    self.textures[self.usedTextures] = texture
  end
  texture:ClearAllPoints()
  texture:SetTexCoord(0, 1, 0, 1)
  texture:SetVertexColor(1, 1, 1, 1)
  texture:Show()
  return texture
end

---Writes the notes of the selected release onto the page.
function window:RenderPage()
  local release = releases()[self.selected]
  local content = self.frame.content
  for _, fontString in ipairs(self.strings) do
    fontString:Hide()
  end
  for _, texture in ipairs(self.textures) do
    texture:Hide()
  end
  self.usedStrings, self.usedTextures = 0, 0

  local width = CONTENT_WIDTH
  ---Distance from the top of the page to the next line
  local y = 0
  ---Puts a font string at the next line.
  ---@param fontString table
  ---@param x number
  ---@param gap number Space below it
  local function place(fontString, x, gap)
    fontString:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    y = y + fontString:GetStringHeight() + gap
  end

  local title = self:PageString("QuestTitleFont", 30, INK)
  title:SetWidth(width)
  title:SetText("Version " .. release.version)
  place(title, 0, 4)

  local meta = self:PageString("QuestFont", 14, INK_SOFT)
  meta:SetWidth(width)
  meta:SetText("Released " .. release.date .. "  ·  " .. changesText(countChanges(release))
    .. (release.version == ns.version and "  ·  the version you have" or ""))
  place(meta, 0, 14)

  local divider = self:PageTexture()
  divider:SetColorTexture(INK_SOFT[1], INK_SOFT[2], INK_SOFT[3], 0.5)
  divider:SetHeight(1)
  divider:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
  divider:SetPoint("RIGHT", content, "RIGHT", 0, 0)
  y = y + 16

  for _, section in ipairs(release.sections) do
    local color = SECTION_COLORS[section.title] or SECTION_COLOR
    -- The heading in its colour with a short bar beside it: easy to find while scrolling
    local bar = self:PageTexture()
    bar:SetColorTexture(color[1], color[2], color[3], 0.9)
    bar:SetSize(4, 18)
    bar:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y - 1)
    local heading = self:PageString("QuestTitleFont", 19, color)
    heading:SetWidth(width - 12)
    heading:SetText(formatText(section.title))
    place(heading, 12, 10)

    for _, item in ipairs(section.items) do
      local dot = self:PageTexture()
      dot:SetTexture("Interface\\QuestFrame\\UI-Quest-BulletPoint")
      dot:SetVertexColor(color[1] * 1.4, color[2] * 1.4, color[3] * 1.4)
      dot:SetSize(12, 12)
      dot:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y - 2)
      -- The lead phrase as the heading of the change, the explanation under it in softer ink
      local lead = self:PageString("QuestTitleFont", 15, INK)
      lead:SetWidth(width - 32)
      lead:SetText(formatText((item.lead:gsub("%.$", ""))))
      if item.text == "" then
        place(lead, 30, 14)
      else
        place(lead, 30, 3)
        local text = self:PageString("QuestFont", 14, INK_SOFT)
        text:SetWidth(width - 32)
        text:SetSpacing(2)
        text:SetText(formatText(item.text))
        place(text, 30, 14)
      end
    end
    y = y + 10
  end

  content:SetHeight(math.max(y, 1))
  self.frame.scroll:SetVerticalScroll(0)
end

--------------------------------------------------------------------------------
-- The list of releases
--------------------------------------------------------------------------------

---Shows as many rows as fit, scrolled so that the selected release is visible.
function window:UpdateList()
  local frame = self.frame
  local fit = math.max(1, math.floor((HEIGHT - LIST_TOP - LIST_BOTTOM - ROWS_TOP - 8) / ROW_HEIGHT))
  if self.selected < self.firstShown then
    self.firstShown = self.selected
  elseif self.selected >= self.firstShown + fit then
    self.firstShown = self.selected - fit + 1
  end
  for index, row in ipairs(frame.rows) do
    local slot = index - self.firstShown
    row:SetShown(slot >= 0 and slot < fit)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 8, -ROWS_TOP - slot * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", -8, -ROWS_TOP - slot * ROW_HEIGHT)
    local isSelected = index == self.selected
    row.selectedBg:SetShown(isSelected)
    row.selectedEdge:SetShown(isSelected)
    if isSelected then
      row.label:SetTextColor(1, 1, 1)
    else
      row.label:SetTextColor(1, 0.82, 0)
    end
  end
  frame.newer:SetEnabled(self.selected > 1)
  frame.older:SetEnabled(self.selected < #releases())
end

---Shows a release.
---@param index integer Index in `ns.changelog`; clamped
function window:Select(index)
  self.selected = math.max(1, math.min(#releases(), index))
  self:UpdateList()
  self:RenderPage()
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---Builds an inset panel.
---@param parent table
---@return table frame
local function createInset(parent)
  local frame = tryCreate("Frame", nil, parent, "InsetFrameTemplate")
  if not frame then
    frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    frame:SetBackdropColor(0, 0, 0, 0.5)
  end
  return frame
end

---Builds one row of the list.
---@param list table The list panel
---@param index integer Index of the release
---@param release OOOOChangelogRelease
---@return table row
local function createRow(list, index, release)
  local row = CreateFrame("Button", nil, list)
  row:SetHeight(ROW_HEIGHT)
  -- The selected row: the art of the game's options list, or a soft wash with a gold edge without it
  row.selectedBg = row:CreateTexture(nil, "BACKGROUND")
  row.selectedBg:SetAllPoints()
  row.selectedEdge = row:CreateTexture(nil, "BORDER")
  row.selectedEdge:SetPoint("TOPLEFT")
  row.selectedEdge:SetPoint("BOTTOMLEFT")
  row.selectedEdge:SetWidth(3)
  if hasAtlas("options_list_active") then
    row.selectedBg:SetAtlas("options_list_active")
    row.selectedEdge:SetAlpha(0)
  else
    row.selectedBg:SetColorTexture(1, 0.82, 0.3, 0.14)
    row.selectedEdge:SetColorTexture(1, 0.82, 0.3, 0.95)
  end
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  row.label:SetPoint("TOPLEFT", 12, -6)
  row.label:SetText("Version " .. release.version)
  local date = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  date:SetTextColor(0.78, 0.78, 0.78)
  date:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
  date:SetText(release.date .. "  ·  " .. changesText(countChanges(release)))
  local installed = row:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
  installed:SetPoint("RIGHT", -10, 0)
  installed:SetText(release.version == ns.version and "Installed" or "")
  row:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    window:Select(index)
  end)
  return row
end

---Builds the frames of the window.
---@return table frame
function window:Create()
  local title = "What's new in " .. ADDON_TITLE .. "  |cff9d9d9d" .. (ns.version or "?") .. "|r"
  local frame = tryCreate("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
  if frame then
    local hidePortrait = _G.ButtonFrameTemplate_HidePortrait
    if type(hidePortrait) == "function" then
      hidePortrait(frame)
    end
    if type(frame.SetTitle) == "function" then
      frame:SetTitle(title)
    end
    if frame.Inset then
      frame.Inset:Hide()
    end
  else
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
      insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", 0, -12)
    titleText:SetText(title)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
  end
  self.frame = frame
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
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

  local all = releases()
  local total = 0
  for _, release in ipairs(all) do
    total = total + countChanges(release)
  end
  local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  summary:SetPoint("TOPLEFT", 16, -36)
  summary:SetText((#all == 1 and "1 version" or #all .. " versions") .. " and " .. changesText(total)
    .. ", newest first. Pick one to read it.")

  -- Left: the list of releases
  local list = createInset(frame)
  list:SetPoint("TOPLEFT", 10, -LIST_TOP)
  list:SetPoint("BOTTOMLEFT", 10, LIST_BOTTOM)
  list:SetWidth(LIST_WIDTH)
  local listTitle = list:CreateFontString(nil, "OVERLAY")
  sizedFont(listTitle, "QuestTitleFont", 20)
  listTitle:SetTextColor(1, 0.82, 0)
  listTitle:SetPoint("TOPLEFT", 16, -14)
  listTitle:SetText("Versions")
  local listHint = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  listHint:SetPoint("TOPRIGHT", -16, -20)
  listHint:SetText("mouse wheel to move")
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_list, delta)
    window:Select(window.selected - delta)
  end)
  frame.rows = {}
  for index, release in ipairs(all) do
    frame.rows[index] = createRow(list, index, release)
  end

  -- Right: the parchment page with a scrolling body
  local page = CreateFrame("Frame", nil, frame)
  page:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, 0)
  page:SetPoint("BOTTOMRIGHT", -12, LIST_BOTTOM)
  local parchment = page:CreateTexture(nil, "BACKGROUND")
  parchment:SetAllPoints()
  if hasAtlas("QuestBG-Parchment") then
    parchment:SetAtlas("QuestBG-Parchment")
  else
    parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
    parchment:SetTexCoord(0, 0.586, 0, 0.65)
  end

  local scroll = tryCreate("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    or CreateFrame("ScrollFrame", nil, page)
  scroll:SetPoint("TOPLEFT", PAGE_MARGIN, -34)
  scroll:SetPoint("BOTTOMRIGHT", -PAGE_MARGIN, 24)
  scroll:EnableMouseWheel(true)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_WIDTH, 1)
  scroll:SetScrollChild(content)
  if not scroll.ScrollBar then
    scroll:SetScript("OnMouseWheel", function(scrolled, delta)
      local limit = math.max(0, content:GetHeight() - scrolled:GetHeight())
      scrolled:SetVerticalScroll(math.max(0, math.min(limit, scrolled:GetVerticalScroll() - delta * WHEEL_STEP)))
    end)
  end
  frame.scroll, frame.content = scroll, content

  frame.newer = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.newer:SetSize(110, 22)
  frame.newer:SetPoint("BOTTOMLEFT", 12, 12)
  frame.newer:SetText("< Newer")
  frame.newer:SetScript("OnClick", function()
    window:Select(window.selected - 1)
  end)
  frame.older = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.older:SetSize(110, 22)
  frame.older:SetPoint("LEFT", frame.newer, "RIGHT", 12, 0)
  frame.older:SetText("Older >")
  frame.older:SetScript("OnClick", function()
    window:Select(window.selected + 1)
  end)

  -- Escape closes the frames that this list names
  local special = _G.UISpecialFrames
  if type(special) == "table" then
    special[#special + 1] = FRAME_NAME
  end
  return frame
end

---Shows the window with the newest release, and notes that the user has seen the notes of this version.
---@return boolean opened false when the addon has no list of changes
function window:Open()
  if #releases() == 0 then
    ns.print("This copy of the addon has no list of changes.")
    return false
  end
  local frame = self.frame or self:Create()
  frame:Show()
  self:Select(1)
  -- Saved data of a newer addon version is left alone
  if not ns.dbIsNewer then
    ns.db.global.changelogSeen = ns.version
  end
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

ns.slash:Register("new", "new - show what is new in each version", function()
  window:Toggle()
end)

--------------------------------------------------------------------------------
-- The line after login
--------------------------------------------------------------------------------

---Listens for a click on the hyperlink of the line, as `ns.mentions.RegisterLink` does for its notice.
---@return boolean usable false when the client has no such registry; the line then names the slash command
local function registerLink()
  local registry = _G.EventRegistry
  if type(registry) ~= "table" or type(registry.RegisterCallback) ~= "function" then
    return false
  end
  registry:RegisterCallback("SetItemRef", function(...)
    -- The link is the first argument after the owner; its place is not relied upon
    for index = 1, select("#", ...) do
      local value = select(index, ...)
      if not issecretvalue(value) and value == LINK then
        window:Open()
        return
      end
    end
  end, window)
  return true
end

local linkUsable = registerLink()

---Builds the line that names the version and points at the window.
---@param seenVersion string|nil The version whose notes the user has opened; nil when none
---@return string
function window.noticeText(seenVersion)
  local text
  if seenVersion == nil then
    text = "Version " .. ns.version .. " installed. "
  elseif seenVersion ~= ns.version then
    text = "Updated to version " .. ns.version .. ". "
  else
    text = "Version " .. ns.version .. ". "
  end
  if linkUsable then
    return text .. "|cff71d5ff|H" .. LINK .. "|h[See what's new]|h|r"
  end
  return text .. "Type /oooo new to see what's new."
end

---true when the line was asked for in this session
local noticeDone = false

-- The line waits for the guild check: a character outside the guild gets one message and nothing else
ns.guildState.RegisterCallback(window, "OnGuildStateChanged", function(_event, inGuild)
  if not inGuild or noticeDone or not ns.version or #releases() == 0 then
    return
  end
  noticeDone = true
  C_Timer.After(NOTICE_DELAY, function()
    ns.print(window.noticeText(ns.db.global.changelogSeen))
  end)
end)
