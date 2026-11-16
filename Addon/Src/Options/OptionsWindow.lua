local addonName, ns = ...

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

---@class OOOOOptionsWindow
---@field options table|nil AceConfig options table, built on first use
local optionsWindow = {}
ns.optionsWindow = optionsWindow

local WINDOW_TITLE = "OO OO Guild Companion"
local EMOJI_SIZE = 32

---AceConfig `get` of an emoji checkbox; `info.arg` is the emoji name.
---@param info table AceConfig info table
---@return boolean
local function getEmojiEnabled(info)
  return ns.emoji:IsEnabled(info.arg)
end

---AceConfig `set` of an emoji checkbox; `info.arg` is the emoji name.
---@param info table AceConfig info table
---@param value boolean
local function setEmojiEnabled(info, value)
  ns.emoji:SetEnabled(info.arg, value)
end

---The Emoji tab: one line per emoji with the image, the trigger word, and a checkbox.
---@return table group AceConfig group
local function buildEmojiTab()
  local args = {
    hint = {
      type = "description",
      order = 0,
      name = "Untick an emoji to turn it off for you. This does not change what other guild members see.\n ",
    },
  }

  for index, emoji in ipairs(ns.emoji:GetAll()) do
    -- A toggle draws its image at a fixed 16 pixels, so the image goes into a description beside it.
    -- The two relative widths add up to less than 1, which keeps one emoji per line at any window width.
    args["image_" .. emoji.name] = {
      type = "description",
      order = index * 2,
      name = emoji.trigger,
      fontSize = "medium",
      image = emoji.texture,
      imageWidth = EMOJI_SIZE,
      imageHeight = EMOJI_SIZE,
      width = "relative",
      relWidth = 0.6,
    }
    args["enabled_" .. emoji.name] = {
      type = "toggle",
      order = index * 2 + 1,
      name = "Enabled",
      desc = "Show " .. emoji.trigger .. " as an image.",
      arg = emoji.name,
      width = "relative",
      relWidth = 0.35,
    }
  end

  return {
    type = "group",
    order = 1,
    name = "Emoji",
    get = getEmojiEnabled,
    set = setEmojiEnabled,
    args = args,
  }
end

---Options table callback for AceConfig. The table is built on the first call, when all files are loaded.
---@return table options AceConfig options table
local function getOptions()
  if not optionsWindow.options then
    optionsWindow.options = {
      type = "group",
      name = WINDOW_TITLE .. " " .. (C_AddOns.GetAddOnMetadata(addonName, "Version") or ""),
      childGroups = "tab",
      args = {
        emoji = buildEmojiTab(),
      },
    }
  end
  return optionsWindow.options
end

---Registers the options table with AceConfig and adds it to the game's Options > AddOns list.
---Call once, from OnInitialize.
function optionsWindow:Register()
  AceConfig:RegisterOptionsTable(addonName, getOptions)
  AceConfigDialog:SetDefaultSize(addonName, 520, 560)

  -- AddToBlizOptions needs the Mainline Settings API. Its presence on Forever is expected but was not
  -- checked on the release client, so probe it; /oooo opt works either way.
  local settings = _G.Settings
  if type(settings) == "table" and settings.RegisterCanvasLayoutCategory and settings.RegisterAddOnCategory then
    AceConfigDialog:AddToBlizOptions(addonName, WINDOW_TITLE)
  end
end

---Shows the settings window. When it is already open, its controls are refreshed.
function optionsWindow:Open()
  AceConfigDialog:Open(addonName)
end
