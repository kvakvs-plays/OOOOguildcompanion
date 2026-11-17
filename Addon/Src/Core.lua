local addonName, ns = ...

---@class OOOOEmojiSettings
---@field disabled table<string, boolean> Emoji name -> true when the user turned the emoji off

---@class OOOOGeneralSettings
---@field optAlias boolean True when `/opt` opens the settings window, like `/oooo opt`

---@class OOOOProfile
---@field general OOOOGeneralSettings
---@field emoji OOOOEmojiSettings

---@class OOOOGlobalSettings
---@field schemaVersion integer|nil Version of the saved variables layout, for migrations
---@field probeResults table<string, OOOOProbeResult>|nil Probe name -> last result, written by SyncProbe.lua
---@field sync OOOOSyncData|nil The shared database; created by the migration to layout 2 (Database.lua)

---@class OOOODatabase AceDB-3.0 database object
---@field profile OOOOProfile
---@field global OOOOGlobalSettings

---@class OOOONamespace
---@field addon OOOOAddon
---@field db OOOODatabase Set in OnInitialize; nil while the files are loading
---@field guildState OOOOGuildState
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
---@field base94 OOOOBase94
---@field versionId OOOOVersionId
---@field syncStore OOOOSyncStore
---@field database OOOODatabaseModule
---@field sync OOOOSync
---@field syncCharacter OOOOSyncCharacter
---@field syncCommands OOOOSyncCommands
---@field dbIsNewer boolean|nil true when the saved variables are from a newer addon version and were left alone

local defaults = {
  profile = {
    general = {
      optAlias = true,
    },
    emoji = {
      disabled = {},
    },
  },
}

---@class OOOOAddon AceAddon-3.0 object with AceConsole-3.0 mixed in
---@field Print fun(self: OOOOAddon, ...: any)
---@field RegisterChatCommand fun(self: OOOOAddon, command: string, handler: string|function)
---@field UnregisterChatCommand fun(self: OOOOAddon, command: string)
---@field SetOptAliasEnabled fun(self: OOOOAddon, enabled: boolean)
---@field NewModule fun(self: OOOOAddon, name: string, ...: string): table
local addon = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0")
ns.addon = addon

function ns.print(text)
  addon:Print(text)
end

ns.slash:Register("opt", "opt - open the settings window", function()
  ns.optionsWindow:Open()
end)

---The short slash command, without the slash, that does the same as `/oooo opt`
local OPT_ALIAS = "opt"
---True while `/opt` is registered with the game
local optAliasRegistered = false

---Handles `/opt`. The setting is checked again because the command can outlive the setting until a reload.
local function onOptAlias()
  if ns.db.profile.general.optAlias then
    ns.optionsWindow:Open()
  else
    ns.print("/opt is turned off. Use /oooo opt.")
  end
end

---Turns the `/opt` alias of `/oooo opt` on or off and saves the choice.
---@param enabled boolean
function addon:SetOptAliasEnabled(enabled)
  ns.db.profile.general.optAlias = enabled
  if enabled then
    if not optAliasRegistered then
      self:RegisterChatCommand(OPT_ALIAS, onOptAlias)
      optAliasRegistered = true
    end
  elseif optAliasRegistered then
    -- AceConsole clears the game's lookup cache `hash_SlashCmdList` and throws when the client has none.
    -- Its presence on Forever was not checked; without it the command stays until the next reload.
    if type(_G.hash_SlashCmdList) == "table" then
      self:UnregisterChatCommand(OPT_ALIAS)
      optAliasRegistered = false
    else
      ns.print("/opt stays until the next /reload.")
    end
  end
end

---Called by AceAddon on ADDON_LOADED for this addon, when the saved variables are available.
function addon:OnInitialize()
  -- `true` selects one "Default" profile shared by all characters of the account
  ns.db = LibStub("AceDB-3.0"):New("OOOOguildcompanionDB", defaults, true)
  -- The layout version and the migration steps are in Database.lua
  if ns.database.migrate(ns.db, math.random) then
    ns.sync:Initialize(ns.db.global.sync, GetServerTime, math.random)
  else
    ns.dbIsNewer = true
    self:Print("The saved data is from a newer version of the addon. Update the addon; the shared database is off.")
  end

  ns.optionsWindow:Register()
  self:RegisterChatCommand("oooo", "OnSlashCommand")
  self:SetOptAliasEnabled(ns.db.profile.general.optAlias)
end

---Called by AceAddon on PLAYER_LOGIN. By now every file has registered its guild callbacks.
function addon:OnEnable()
  ns.guildState:Start()
end

---Handles `/oooo <command>`: the first word selects a handler in `ns.slash` (Slash.lua).
---@param input string Text after the slash command
function addon:OnSlashCommand(input)
  ns.slash:Dispatch(input)
end
