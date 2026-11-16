local addonName, ns = ...

local AceGUI = LibStub("AceGUI-3.0")

---@class OOOOOptionsWindow
---@field frame table|nil AceGUI Frame widget while the window is open
local optionsWindow = {}
ns.optionsWindow = optionsWindow

local EMOJI_SIZE = 32
local TABS = {
  { text = "Emoji", value = "emoji" },
}

---One line of the Emoji tab: trigger word, image, checkbox.
---@param emoji OOOOEmoji
---@return table row AceGUI SimpleGroup widget
local function createEmojiRow(emoji)
  local row = AceGUI:Create("SimpleGroup")
  row:SetFullWidth(true)
  row:SetLayout("Flow")

  local trigger = AceGUI:Create("Label")
  trigger:SetFontObject(GameFontHighlight)
  trigger:SetText(emoji.trigger)
  trigger:SetWidth(220)
  row:AddChild(trigger)

  local image = AceGUI:Create("Label")
  image:SetImage(emoji.texture)
  image:SetImageSize(EMOJI_SIZE, EMOJI_SIZE)
  image:SetWidth(EMOJI_SIZE + 24)
  row:AddChild(image)

  local enabled = AceGUI:Create("CheckBox")
  enabled:SetLabel("Enabled")
  enabled:SetValue(ns.emoji:IsEnabled(emoji.name))
  enabled:SetWidth(120)
  enabled:SetCallback("OnValueChanged", function(_widget, _event, value)
    ns.emoji:SetEnabled(emoji.name, value)
  end)
  row:AddChild(enabled)

  return row
end

---@param container table AceGUI TabGroup widget
local function drawEmojiTab(container)
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("List")
  container:AddChild(scroll)

  local hint = AceGUI:Create("Label")
  hint:SetFullWidth(true)
  hint:SetText("Untick an emoji to turn it off for you. This does not change what other guild members see.\n ")
  scroll:AddChild(hint)

  for _, emoji in ipairs(ns.emoji:GetAll()) do
    scroll:AddChild(createEmojiRow(emoji))
  end
end

local drawTab = {
  emoji = drawEmojiTab,
}

---Shows the settings window; does nothing when it is already open.
function optionsWindow:Open()
  if self.frame then
    return
  end

  local frame = AceGUI:Create("Frame")
  frame:SetTitle("OO OO Guild Companion")
  frame:SetStatusText(addonName .. " " .. (C_AddOns.GetAddOnMetadata(addonName, "Version") or ""))
  frame:SetWidth(520)
  frame:SetHeight(560)
  frame:SetLayout("Fill")
  frame:SetCallback("OnClose", function(widget)
    AceGUI:Release(widget)
    self.frame = nil
  end)
  self.frame = frame

  local tabs = AceGUI:Create("TabGroup")
  tabs:SetLayout("Fill")
  tabs:SetTabs(TABS)
  tabs:SetCallback("OnGroupSelected", function(container, _event, group)
    container:ReleaseChildren()
    drawTab[group](container)
  end)
  frame:AddChild(tabs)
  tabs:SelectTab(TABS[1].value)
end
