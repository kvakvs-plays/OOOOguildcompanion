local addonName, ns = ...

---@class OOOOEmojiSettings
---@field disabled table<string, boolean> Emoji name -> true when the user turned the emoji off

---@class OOOOProfile
---@field emoji OOOOEmojiSettings

---@class OOOOGlobalSettings
---@field schemaVersion integer|nil Version of the saved variables layout, for migrations
---@field probeResults table<string, OOOOProbeResult>|nil Probe name -> last result, written by SyncProbe.lua

---@class OOOODatabase AceDB-3.0 database object
---@field profile OOOOProfile
---@field global OOOOGlobalSettings

---@class OOOONamespace
---@field addon OOOOAddon
---@field db OOOODatabase Set in OnInitialize; nil while the files are loading
---@field emoji OOOOEmojiModule
---@field emojiChat OOOOEmojiChat
---@field emojiIndex table<string, string[]>
---@field emojiAliases table<string, string[]>
---@field emojiOptions table<string, OOOOEmojiOptions>
---@field optionsWindow OOOOOptionsWindow
---@field print fun(text: string) Prints one line for the user
---@field newDispatcher fun(prefix: string): OOOODispatcher
---@field slash OOOODispatcher Commands after `/oooo`
---@field syncSlash OOOODispatcher Commands after `/oooo sync`
---@field syncProbe OOOOSyncProbe

---Version of the saved variables layout. Raise it together with a migration step in `migrate`.
local SCHEMA_VERSION = 1

local defaults = {
  profile = {
    emoji = {
      disabled = {},
    },
  },
}

---@class OOOOAddon AceAddon-3.0 object with AceConsole-3.0 mixed in
---@field Print fun(self: OOOOAddon, ...: any)
---@field RegisterChatCommand fun(self: OOOOAddon, command: string, handler: string|function)
---@field NewModule fun(self: OOOOAddon, name: string, ...: string): table
local addon = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0")
ns.addon = addon

function ns.print(text)
  addon:Print(text)
end

ns.slash:Register("opt", "opt - open the settings window", function()
  ns.optionsWindow:Open()
end)

---Brings saved variables of an older addon version to the current layout.
---@param db OOOODatabase
local function migrate(db)
  -- Version 1 is the first layout, so there is nothing to convert yet
  if (db.global.schemaVersion or 0) < SCHEMA_VERSION then
    db.global.schemaVersion = SCHEMA_VERSION
  end
end

---Called by AceAddon on ADDON_LOADED for this addon, when the saved variables are available.
function addon:OnInitialize()
  -- `true` selects one "Default" profile shared by all characters of the account
  ns.db = LibStub("AceDB-3.0"):New("OOOOguildcompanionDB", defaults, true)
  migrate(ns.db)

  ns.optionsWindow:Register()
  self:RegisterChatCommand("oooo", "OnSlashCommand")
end

---Handles `/oooo <command>`: the first word selects a handler in `ns.slash` (Slash.lua).
---@param input string Text after the slash command
function addon:OnSlashCommand(input)
  ns.slash:Dispatch(input)
end
