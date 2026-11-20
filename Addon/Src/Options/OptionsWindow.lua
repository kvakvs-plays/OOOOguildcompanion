local addonName, ns = ...

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

---@class OOOOOptionsWindow
---@field options table|nil AceConfig options table, built on first use
local optionsWindow = {}
ns.optionsWindow = optionsWindow

local WINDOW_TITLE = "OO OO Guild Companion"
local EMOJI_SIZE = 32
---Silver, for the aliases beside the white emoji name
local ALIAS_COLOR = "|cffc0c0c0"

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

---Text of an emoji line: the name, then in silver the aliases and a note for a case sensitive emoji.
---@param emoji OOOOEmoji
---@return string
local function emojiLabel(emoji)
  local label = emoji.name
  if #emoji.aliases > 0 then
    label = label .. "  " .. ALIAS_COLOR .. table.concat(emoji.aliases, ", ") .. "|r"
  end
  if emoji.caseSensitive then
    label = label .. "  " .. ALIAS_COLOR .. "(exact letter case)|r"
  end
  return label
end

---The checkboxes of the General tab that choose the kinds of chat with emoji.
---@return table group AceConfig inline group
local function buildEmojiChannels()
  local args = {}
  for index, channel in ipairs(ns.emojiChat.CHANNELS) do
    args[channel.key] = {
      type = "toggle",
      order = index,
      name = channel.title,
      desc = "Show emoji in " .. channel.title:lower() .. " chat.",
      arg = channel.key,
    }
  end
  return {
    type = "group",
    order = 3,
    inline = true,
    name = "Show emoji in channels",
    get = function(info)
      return ns.emojiChat:IsChannelEnabled(info.arg)
    end,
    set = function(info, value)
      ns.emojiChat:SetChannelEnabled(info.arg, value)
    end,
    args = args,
  }
end

---The General tab: settings of the addon as a whole.
---@return table group AceConfig group
local function buildGeneralTab()
  return {
    type = "group",
    order = 0,
    name = "General",
    args = {
      optAlias = {
        type = "toggle",
        order = 1,
        width = "full",
        name = "Enable the /opt command",
        desc = "/opt opens this window, like /oooo opt. Turn it off when another addon uses /opt.",
        get = function()
          return ns.db.profile.general.optAlias
        end,
        set = function(_, value)
          ns.addon:SetOptAliasEnabled(value)
        end,
      },
      emojiSize = {
        type = "select",
        order = 2,
        name = "Emoji size",
        desc = "Size of an emoji in chat. Lines that are already in the chat window keep their size.",
        values = function()
          local values = {}
          for _, size in ipairs(ns.emojiChat.SIZES) do
            values[size] = size .. " px"
          end
          return values
        end,
        -- A list, so that the sizes are in ascending order and not in the order of the hash table
        sorting = ns.emojiChat.SIZES,
        get = function()
          return ns.emojiChat:GetSize()
        end,
        set = function(_, value)
          ns.emojiChat:SetSize(value)
        end,
      },
      emojiChannels = buildEmojiChannels(),
      mentionsHeader = {
        type = "header",
        order = 10,
        name = "Mentions",
      },
      mentionsWatch = {
        type = "input",
        order = 11,
        width = "full",
        name = "@nicknames and keywords to watch (comma separated)",
        desc = "A guild chat line that has @ directly before one of these, like @nickname, is listed as a "
          .. "mention of you in the chat history (/oooo, tab \"Guild chat\"). The letter case does not matter.",
        get = function()
          return ns.db.profile.mentions.watch
        end,
        set = function(_, value)
          ns.db.profile.mentions.watch = value
          ns.mentions:WatchChanged()
        end,
      },
      mentionsNotifyOnLogin = {
        type = "toggle",
        order = 12,
        width = "full",
        name = "Tell me after login about unread mentions",
        desc = "Prints one line some seconds after login when the list holds a mention of you that you have "
          .. "not opened. Mentions that the sync brings later are announced in any case.",
        get = function()
          return ns.db.profile.mentions.notifyOnLogin
        end,
        set = function(_, value)
          ns.db.profile.mentions.notifyOnLogin = value
        end,
      },
    },
  }
end

---The Emoji tab: one line per emoji with the image, the name with the aliases, and a checkbox.
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
      name = emojiLabel(emoji),
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
      desc = "Show " .. emoji.name .. " as an image.",
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
        general = buildGeneralTab(),
        emoji = buildEmojiTab(),
        -- The Sync tab is built in Sync/SyncOptions.lua
        sync = ns.syncOptions.buildTab(),
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
