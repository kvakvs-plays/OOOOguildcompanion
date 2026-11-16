-- Lint: lua "%APPDATA%\luarocks\bin\luacheck" . --codes  (LUA_PATH must be set, see AGENTS.md)
std = "lua51+wow"
max_line_length = 120
-- Type annotations cannot be wrapped usefully; the limit applies to code
max_comment_line_length = false
-- `function module:Method()` without touching self is the normal module style
self = false
ignore = {
  "21[123]/_.*", -- a leading underscore marks a value as unused on purpose
  "211/addonName", "211/ns", -- every file starts with `local addonName, ns = ...` (see AGENTS.md)
}

exclude_files = {
  "Libs/**",
  "Ace3/**",
}

-- Written by the addon: saved variables, slash commands, binding labels. Add them here as they appear.
globals = {
  "SlashCmdList",
}

-- WoW API and client Lua extensions that exist on WoW: Forever (interface 16001).
-- Add a name here only after you know that it exists on Forever.
stds.wow = { read_globals = {
  "bit", "C_AddOns", "C_ChatInfo", "C_EventUtils", "C_GuildInfo", "C_Item", "C_Map", "C_Spell", "C_Timer",
  "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "GameFontHighlight", "GameTooltip", "GetBuildInfo", "GetGuildInfo",
  "GetGuildRosterInfo", "GetLocale", "GetNumGuildMembers", "GetTime", "hooksecurefunc", "InCombatLockdown",
  "IsInGuild", "issecretvalue", "LE_EXPANSION_LEVEL_CURRENT", "LibStub", "PlaySound", "RAID_CLASS_COLORS",
  "SOUNDKIT", "strsplit", "strtrim", "tContains", "tinsert", "UIParent", "UnitClass", "UnitExists",
  "UnitFullName", "UnitGUID", "UnitLevel", "UnitName", "wipe",
} }

files["Tests/**"] = { read_globals = { "setfenv", "loadfile" } }
