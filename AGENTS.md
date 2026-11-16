# Agent Instructions for OOOOguildcompanion

## Project Context

- This repository is a Lua addon for **World of Warcraft: Forever** (patch 1.60.x, internal name Camelot).
  Forever is the only target client. Do not add Classic Era, TBC, or Retail TOC files or code paths.
- It is a guild-only addon for the guild **OO OO** on the EU Normal (PvE) realm of WoW: Forever. It is not
  published for the general public, so there is one guild, one region, and one ruleset to support.
- The guild name is exactly `OO OO`: four capital letters O with one space in the middle, shown in the game as
  `<OO OO>`. The addon folder name has no space.
- The addon folder and the TOC file must both be named `OOOOguildcompanion`.
- The `Addon` folder is the addon root: it holds the TOC and is installed as `OOOOguildcompanion`. Paths
  below are relative to it unless they start with `scripts`.
- The addon logo is a dark digital clock with glowing white 00:00. The icons are `Icons\Logo32.png`,
  `Logo64.png`, `Logo128.png`, and `Logo256.png`. Use `Logo64.png` for the TOC `## IconTexture` line and a
  minimap button, and the larger ones for window headers.
- Do not edit the icons by hand. `Art\clock.png` is the source; `pwsh Art\make-icons.ps1` rebuilds all sizes
  with ImageMagick. The `Art` folder is not part of the installed addon.
- `Icons\Emoji\<guild id>\<name>.png` holds the custom emoji of Discord guilds as 64x64 textures. They are
  imported by hand with `python scripts/import_discord_emoji.py [guild id ...]`, which replaces the PNG files
  of each imported guild; do not edit them. The script needs a bot token in `DISCORD_BOT_TOKEN` (environment
  or the git-ignored `.env`) and a bot that is a member of each guild. Never commit or print the token.
- The addon is written in Lua with LuaLS type annotations (`---@class`, `---@param`, `---@return`). Specify
  types wherever they can be known, and add a documentation comment to public or non-obvious functions.

**IMPORTANT** When committing, do not add a "Co-Authored-By" line to the commit message.

## Game Facts

- WoW: Forever launched on November 4, 2026. It runs beside Retail and Classic as its own branch. The beta has
  ended; the release client is still patch 1.60.1.
- The level cap is 60. The classes are the nine Classic ones (Druid, Hunter, Mage, Paladin, Priest, Rogue,
  Shaman, Warlock, Warrior). The races are the eight Classic ones and the new Skyborne (Alliance Skyborne can
  be Mages, Horde Skyborne can be Shamans).
- A party has up to 5 players. A raid has up to 8 parties, 40 players. The launch raids are Barrow Deeps (10),
  Hyjal Summit (20), and Onyxia's Lair (40); they unlock on December 9, 2026.
- Each region has one mega-realm per ruleset: Normal (PvE), PvP, RP, RP-PvP, and later Hardcore.
- Forever has systems that Classic Era lacks: dual talent specialization (from level 40), the Legacy system
  in place of achievements, camping, reagent bags, account-wide Collections, and first and last names for
  characters.
- Reference: https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever

## Target Runtime

- TOC: `## Interface: 16001`. Do not use Classic Era interface numbers (115xx).
- Lua 5.1 with the WoW additions. Do not use `goto`, `//`, bitwise operators, `bit32`, or `_ENV`. Use the
  `bit` library (`bit.band`, `bit.bor`, `bit.lshift`).
- There is no `require`, `dofile`, `loadfile`, `io`, or `os`. The TOC file sets the load order, and shared
  state lives on the addon namespace.
- The development host has Lua 5.4, so a file that runs under `lua` on the host can still fail in the game.
  Keep the code within Lua 5.1.
- The client is installed at `F:\SSDGames\World of Warcraft\_forever_\`. Addons go into
  `Interface\AddOns\OOOOguildcompanion\`. A new addon folder needs a client restart to appear; changes to
  existing files need `/reload`.

## Forever API Rules

Forever uses the Mainline (Retail 12.x) UI architecture with Classic content. Most 12.1.5 APIs exist, and
Midnight's addon restrictions, including secret values, are active. The facts below were checked on beta
builds of 1.60.1 (69913 to 70205). The release client is also 1.60.1 but a later build, so a beta defect may
be fixed there. Test a claim on the release client before relying on it.

- **Detecting the client.** `WOW_PROJECT_ID` changed between builds (1 on build 69913, 18 on 70205). Never
  branch on it alone. Use `select(4, GetBuildInfo())` (16xxx) and `LE_EXPANSION_LEVEL_CURRENT == 0`.
- **Removed globals.** `GetSpellInfo`, `GetItemInfo`, `GetSpellBookItemName`, `GetNumTalentTabs`,
  `GetTalentInfo`, `GetNumSkillLines`, and `GetAddOnMetadata` are absent. Use `C_Spell`, `C_Item`, and
  `C_AddOns`. `C_Spell.GetSpellInfo` returns a table. `C_Item.GetItemInfo` returns multiple values. Both return
  nil until the data is cached: request the load and wait for `SPELL_DATA_LOAD_RESULT` or
  `ITEM_DATA_LOAD_RESULT`.
- **No combat log.** Registering `COMBAT_LOG_EVENT_UNFILTERED` throws, and `CombatLogGetCurrentEventInfo`
  is unavailable. Do not build damage meters, healing meters, or boss mods based on the combat log.
- **Secret values.** `UnitHealth` can return a secret number: `type()` says `"number"`, but arithmetic and
  comparison throw. Unit names can be secret strings, and `UnitCanAttack` and `UnitExists` can return secret
  booleans. Guard with `issecretvalue` before any comparison, branch, concatenation, or print. Pass health
  values straight into `StatusBar:SetMinMaxValues` and `StatusBar:SetValue`.
- **Protected calls.** `pcall` does not make a protected call safe. The client records "Interface action
  failed because of an AddOn" without a Lua error, and the counter clears only on a client restart. Do not
  call `ChatFrame_OpenChat`, `ChatEdit_ActivateChat`, or `C_SuperTrack.SetSuperTrackedUserWaypoint`. Do not
  write secure attributes onto Blizzard unit frames. Shift-click links go through `HandleModifiedItemClick`.
  Map pins go through `C_Map.SetUserWaypoint` with a `UiMapPoint`.
- **Secure snippets** failed to compile on build 69913. Do not depend on click-casting or action-bar paging
  snippets; use the addon's own buttons.
- **Unknown events.** Registering an event that does not exist throws. Check an uncertain event with
  `C_EventUtils.IsEventValid` first.
- **Sounds.** Use `PlaySound` with a `SOUNDKIT` id, not `PlaySoundFile` on `Sound\Interface` paths.
- **Bags.** Bags are `0`-`4`, the reagent bag is `5`, character bank tabs are `6`-`14`, and account bank tabs
  are `15`-`23`. The Warband bank is unusable (`C_Bank.CanUseBank(Enum.BankType.Account)` is false).
- **Group buffs** (Prayers, Gift of the Wild, Arcane Brilliance, Battle Shout) cover the whole raid, and all
  blessings last 60 minutes.
- If you are not sure that an API exists on Forever, say so and write a capability probe. Do not invent `C_`
  functions. The Blizzard UI source at `F:\Projects\WowAddons\BlizzardInterfaceCode\` is for Classic, not
  Forever, so an API found there may be missing in the game.
- Skin and inform. Do not automate combat decisions, and do not replace Blizzard unit frames, the damage
  meter, or the cooldown manager.

## Guild-Only Behaviour

- Guild features run only when the character is in `OO OO`. Check the guild name after `PLAYER_GUILD_UPDATE` or
  `GUILD_ROSTER_UPDATE`, because `GetGuildInfo("player")` returns nil for some seconds after login. A
  character outside the guild gets one message and no guild functions.
- Roster data arrives asynchronously. Request it with `C_GuildInfo.GuildRoster()` and read it on
  `GUILD_ROSTER_UPDATE`. Do not request it on a timer; the server throttles the request.
- Addon-to-addon communication uses the `"GUILD"` addon channel and one registered prefix. A message from
  another guild member is untrusted input: validate the type and range of every field, and never run
  received text as code. Verify on the live client whether addon messages are restricted in instances and in
  combat before a feature depends on them.
- Put a protocol version in every message so that members with different addon versions do not break each
  other.

## Combat Lockdown And Taint

- Protected functions cannot be called while `InCombatLockdown()` is true. Before you show, hide, or move a
  protected frame, check it; in combat, queue the closure and run it on `PLAYER_REGEN_ENABLED`.
- Avoid tainting Blizzard frames. When a hook is necessary, use `hooksecurefunc`.

## Events And Performance

- Use one event frame and a handler table keyed by event name. Do not grow an `if`/`elseif` chain.
- Use `RegisterUnitEvent` when the set of units is known. Unregister events that are no longer needed.
- Do not poll with `OnUpdate` when an event exists. If `OnUpdate` is required, throttle it with an accumulator.
- In hot paths, reuse tables (`wipe(t)`) and avoid string concatenation.

## Saved Variables

- Declare saved variables in the TOC (`## SavedVariables`, `## SavedVariablesPerCharacter`).
- They are populated after the addon's files run. Read and create them in `ADDON_LOADED` for this addon,
  never at file scope.
- Migrate the schema by a version field. Do not silently overwrite user data.

## Frames And Libraries

- Name a frame only when external code needs `_G["FrameName"]` access.
- A frame with a backdrop needs `BackdropTemplate`. Do not use the `TOOLTIP` strata for normal UI.
- Access libraries through LibStub and embed them in the addon. Ace3, LibDataBroker-1.1, and LibDBIcon-1.0
  are acceptable; third-party library folders are excluded from luacheck.

## Lua Style

- Every Lua file starts with `local addonName, ns = ...`. Export through `ns`; create a global only for
  saved variables, slash commands, and key binding labels.
- Local by default. 2-space indentation, no tabs, lines up to 120 characters.
- Function signatures use standard spacing: `function foo(a, b, c)`.
- Comments explain a non-obvious why: a lockdown workaround, a Forever quirk, taint avoidance.

## Quality Checks

- `luacheck` must report 0 warnings with the committed `.luacheckrc`. Prefix intentionally unused values
  with `_`. Add a new WoW API global to `stds.wow` in `.luacheckrc` only after you know it exists on Forever.
- luacheck is installed through luarocks and has no Windows launcher. Run it through `lua` from the
  repository root (PowerShell):

  ```powershell
  $env:LUA_PATH = "$env:APPDATA\luarocks\share\lua\5.4\?.lua;$env:APPDATA\luarocks\share\lua\5.4\?\init.lua;;"
  $env:LUA_CPATH = "$env:APPDATA\luarocks\lib\lua\5.4\?.dll;;"
  lua "$env:APPDATA\luarocks\bin\luacheck" . --codes
  ```

- Run tests, when they exist, with `lua Tests/<name>.lua` from the repository root. Tests run on host Lua 5.4
  without the game, so they cover only logic that does not call the WoW API.
- luacheck and host tests do not prove that the addon works in the game. Say which parts were checked only
  on the host and need a test in the client.
