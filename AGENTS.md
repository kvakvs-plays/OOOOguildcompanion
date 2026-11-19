# Agent Instructions for OOOOguildcompanion

## Project Context

- This repository is a Lua addon for **World of Warcraft: Forever** (patch
  1.60.x, internal name Camelot). Forever is the only target client. Do not add
  Classic Era, TBC, or Retail TOC files or code paths.
- It is a guild-only addon for the guild **OO OO** on the EU Normal (PvE) realm
  of WoW: Forever. It is not published for the general public, so there is one
  guild, one region, and one ruleset to support.
- The guild name is exactly `OO OO`: four capital letters O with one space in
  the middle, shown in the game as `<OO OO>`. The addon folder name has no
  space.
- The addon folder and the TOC file must both be named `OOOOguildcompanion`.
- The `Addon` folder is the addon root: it holds the TOC and is installed as
  `OOOOguildcompanion`. Paths below are relative to it unless they start with
  `scripts`.
- The addon logo is a dark digital clock with glowing white 00:00. The icons are
  `Icons\Logo32.png`, `Logo64.png`, `Logo128.png`, and `Logo256.png`. Use
  `Logo64.png` for the TOC `## IconTexture` line and a minimap button, and the
  larger ones for window headers.
- Do not edit the icons by hand. `Art\clock.png` is the source;
  `pwsh Art\make-icons.ps1` rebuilds all sizes with ImageMagick. The `Art`
  folder is not part of the installed addon.
- `Icons\Emoji\<guild id>\<name>.png` holds the custom emoji of Discord guilds
  as 64x64 textures. They are imported by hand with
  `python scripts/import_discord_emoji.py [guild id ...]`, which replaces the
  PNG files of each imported guild; do not edit them. The script needs a bot
  token in `DISCORD_BOT_TOKEN` (environment or the git-ignored `.env`) and a bot
  that is a member of each guild. Never commit or print the token.
- The game cannot list a folder, so the same script generates
  `Src\Emoji\EmojiIndex.lua`, the list of emoji names that the addon loads. Do
  not edit it; `python scripts/import_discord_emoji.py --index-only` rebuilds it
  from the PNG files without a token.
- The addon's own Lua files live under `Src\` (`Src\Core.lua`, `Src\Emoji\`,
  `Src\Options\`). Put new source files there and add them to
  `toc_template.toc`; libraries and assets stay outside `Src`.
- Ace3 is embedded in `Ace3\` and loaded through `embeds.xml`, which lists only
  the libraries in use. Add a line there before the first use of another Ace
  library.
- The addon is written in Lua with LuaLS type annotations (`---@class`,
  `---@param`, `---@return`). Specify types wherever they can be known, and add
  a documentation comment to public or non-obvious functions.

**IMPORTANT** When committing, do not add a "Co-Authored-By" line to the commit
message.

## Install And Release

- `python scripts/release_tool.py --dst=<AddOns folder> install` copies the addon
  into a client, and `--dst=<folder> zip` writes
  `OOOOguildcompanion-<version>.zip`. `install.bat` and `release.bat` are local,
  git-ignored copies of `install.bat.txt` and `release.bat.txt` with the paths
  of one machine.
- The script packages only what `COPY_DIRS` and `COPY_FILES` name, and stops
  when the `Addon` folder has an entry that no list names. Add every new
  top-level file or folder of `Addon` to one of the lists.
- The release version is `VERSION` in `scripts/release_tool.py`, in the form
  `<year>.<month>.<build>`: start each month with build 0 and add 1 with every
  release.
- `OOOOguildcompanion.toc` is generated and git-ignored. Edit `toc_template.toc`
  in the `Addon` folder; both commands of the script write the TOC from it, with
  the interface number, the title, and `<version>-<git hash>` filled in. A fresh
  checkout has no TOC until the script runs once.
- `CHANGELOG.md` is the source of the "What's new" window (`/oooo new`). Both
  commands of the script write the git-ignored
  `Src\Changelog\ChangelogData.lua` from it, with `VERSION`. Keep its form: a
  release is `## <version> (<date>)`, a section is `### <title>`, and every
  item starts with a `**bold heading**` followed by the explanation; the script
  stops on anything else. Backticks mark commands; the window has no other
  inline formatting.
- The script keeps the other game versions as commented-out lines. Leave them
  commented: Forever is the only target.

## Game Facts

- WoW: Forever launched on November 4, 2026. It runs beside Retail and Classic
  as its own branch. The beta has ended; the release client is still patch
  1.60.1.
- The level cap is 60. The classes are the nine Classic ones (Druid, Hunter,
  Mage, Paladin, Priest, Rogue, Shaman, Warlock, Warrior). The races are the
  eight Classic ones and the new Skyborne (Alliance Skyborne can be Mages, Horde
  Skyborne can be Shamans).
- A party has up to 5 players. A raid has up to 8 parties, 40 players. The
  launch raids are Barrow Deeps (10), Hyjal Summit (20), and Onyxia's Lair (40);
  they unlock on December 9, 2026.
- A player belongs to one of several servers with a long internal name, such
  as `CAMWOW EU4 Realm 7 PvE`. The game does not normally show that name, and
  the player cannot select a server. All servers of a region are joined into
  one mega-realm with layers that keep PvE, PvP, and RP players apart; players
  of different rulesets can meet but mostly do not. Hardcore comes later.
- Names have no realm suffix, also between characters of different home
  servers: tested with two guild members on Realm 5 and Realm 7, in the
  roster and as the sender of addon messages. Do not build features on realm
  names.
- Forever has systems that Classic Era lacks: dual talent specialization (from
  level 40), the Legacy system in place of achievements, camping, reagent bags,
  account-wide Collections, and first and last names for characters.
- Reference: https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever

## Target Runtime

- TOC: `## Interface: 16001`. Do not use Classic Era interface numbers (115xx).
- Lua 5.1 with the WoW additions. Do not use `goto`, `//`, bitwise operators,
  `bit32`, or `_ENV`. Use the `bit` library (`bit.band`, `bit.bor`,
  `bit.lshift`).
- There is no `require`, `dofile`, `loadfile`, `io`, or `os`. The TOC file sets
  the load order, and shared state lives on the addon namespace.
- The development host has Lua 5.4, so a file that runs under `lua` on the host
  can still fail in the game. Keep the code within Lua 5.1.
- The client is installed at `F:\SSDGames\World of Warcraft\_forever_\`. Addons
  go into `Interface\AddOns\OOOOguildcompanion\`. A new addon folder needs a
  client restart to appear; changes to existing files need `/reload`.

## Forever API Rules

Forever uses the Mainline (Retail 12.x) UI architecture with Classic content.
Most 12.1.5 APIs exist, and Midnight's addon restrictions, including secret
values, are active. The facts below were checked on beta builds of 1.60.1 (69913
to 70205). The release client is also 1.60.1 but a later build, so a beta defect
may be fixed there. Test a claim on the release client before relying on it.

- **Detecting the client.** `WOW_PROJECT_ID` changed between builds (1 on build
  69913, 18 on 70205). Never branch on it alone. Use `select(4, GetBuildInfo())`
  (16xxx) and `LE_EXPANSION_LEVEL_CURRENT == 0`.
- **Removed globals.** `GetSpellInfo`, `GetItemInfo`, `GetSpellBookItemName`,
  `GetNumTalentTabs`, `GetTalentInfo`, `GetNumSkillLines`, and
  `GetAddOnMetadata` are absent. Use `C_Spell`, `C_Item`, and `C_AddOns`.
  `C_Spell.GetSpellInfo` returns a table. `C_Item.GetItemInfo` returns multiple
  values. Both return nil until the data is cached: request the load and wait
  for `SPELL_DATA_LOAD_RESULT` or `ITEM_DATA_LOAD_RESULT`.
- **No combat log.** Registering `COMBAT_LOG_EVENT_UNFILTERED` throws, and
  `CombatLogGetCurrentEventInfo` is unavailable. Do not build damage meters,
  healing meters, or boss mods based on the combat log.
- **Secret values.** `UnitHealth` can return a secret number: `type()` says
  `"number"`, but arithmetic and comparison throw. Unit names can be secret
  strings, and `UnitCanAttack` and `UnitExists` can return secret booleans.
  Guard with `issecretvalue` before any comparison, branch, concatenation, or
  print. Pass health values straight into `StatusBar:SetMinMaxValues` and
  `StatusBar:SetValue`.
- **Protected calls.** `pcall` does not make a protected call safe. The client
  records "Interface action failed because of an AddOn" without a Lua error, and
  the counter clears only on a client restart. Do not call `ChatFrame_OpenChat`,
  `ChatEdit_ActivateChat`, or `C_SuperTrack.SetSuperTrackedUserWaypoint`. Do not
  write secure attributes onto Blizzard unit frames. Shift-click links go
  through `HandleModifiedItemClick`. Map pins go through `C_Map.SetUserWaypoint`
  with a `UiMapPoint`.
- **Secure snippets** failed to compile on build 69913. Do not depend on
  click-casting or action-bar paging snippets; use the addon's own buttons.
- **Unknown events.** Registering an event that does not exist throws. Check an
  uncertain event with `C_EventUtils.IsEventValid` first.
- **Sounds.** Use `PlaySound` with a `SOUNDKIT` id, not `PlaySoundFile` on
  `Sound\Interface` paths.
- **Bags.** Bags are `0`-`4`, the reagent bag is `5`, character bank tabs are
  `6`-`14`, and account bank tabs are `15`-`23`. The Warband bank is unusable
  (`C_Bank.CanUseBank(Enum.BankType.Account)` is false).
- **Group buffs** (Prayers, Gift of the Wild, Arcane Brilliance, Battle Shout)
  cover the whole raid, and all blessings last 60 minutes.
- **Checked on the release client** (1.60.1, November 17, 2026, with
  `/oooo sync probe`):
  - `<` on strings follows the byte order for the characters 33 to 126, and
    `table.sort` gives the byte order. Version ids can be compared with `<`.
  - `GetServerTime()` and `time()` return plain numbers, not secret values.
    The local clock was 2 seconds ahead of the server.
  - Guild ranks: `GetGuildRosterInfo` gives the rank index from 0. Index 0 is
    the guild master (one member). Indexes can have gaps: `OO OO` uses 0 to 5
    and 9. Roster names, rank names, and rank indexes were not secret.
  - A roster name has a space in it: the first and the last name
    (`Nota Scam`). Do not split a character name on whitespace.
  - These exist: `GetServerTime`, `IsResting`, `IsInRaid`, `IsInInstance`,
    `InCombatLockdown`, `C_ChatInfo.SendAddonMessage`,
    `C_ChatInfo.RegisterAddonMessagePrefix`, `C_Timer.After`,
    `C_Timer.NewTimer`, `C_GuildInfo.GuildRoster`,
    `ChatFrame_AddMessageEventFilter`, `Enum.SendAddonMessageResult`.
  - These events are valid: `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`,
    `PLAYER_UPDATE_RESTING`, `GROUP_ROSTER_UPDATE`, `PLAYER_ENTERING_WORLD`,
    `PLAYER_GUILD_UPDATE`, `GUILD_ROSTER_UPDATE`, `CHAT_MSG_ADDON`,
    `CHAT_MSG_SYSTEM`.
  - Addon messages (`C_ChatInfo.SendAddonMessage`, two accounts): all 94
    characters from byte 33 to 126 arrive unchanged on `GUILD` and on
    `WHISPER`. A whisper to a name with a space arrives. A `GUILD` message
    also comes back to its sender.
  - Send results: 0 is success. Of 30 messages of 255 bytes sent at once, 10
    got 0 and 20 got 3 (throttled). The raw API drops a throttled message;
    it does not queue it. After the burst, about 1 message per second is
    accepted (measured: 1.02). A send can therefore fail with 3 right after
    other traffic of the addon.
  - An addon whisper to an offline member returns 0 and prints the system
    line `No player named '<name>' is currently playing.` in the chat frame.
    The `CHAT_MSG_SYSTEM` text was not secret.
  - Character names: `UnitName("player")`, `UnitFullName("player")`, and
    `UnitNameUnmodified("player")` return the first and the last name as two
    values (`'Nota', 'Scam'`); the second value is not a realm. The roster,
    the sender of `CHAT_MSG_ADDON`, and `GetUnitName("player")` give
    `'Nota Scam'`. The sender had no realm suffix. To find the own character
    in the roster or in a message, join the two values with a space.
  - Out of combat, a `GUILD` addon message returns 0 and is delivered, both
    outside an instance and inside a dungeon (instance type `party`). From
    inside the dungeon, `GUILD` and `WHISPER` messages reach a member outside
    and the replies come back unchanged.
  - In combat inside a dungeon, a `GUILD` addon message returns 0 and is
    delivered. Whether that fight was a boss encounter was not recorded.
  - AceComm-3.0 (with ChatThrottleLib) and AceSerializer-3.0 work
    (November 18, 2026): serialized messages on `GUILD` arrived between two
    accounts through `RegisterComm` and `SendCommMessage`. AceComm calls
    the global `Ambiguate` on every addon message, so that global exists.
    `WHISPER` through AceComm works too: a pull between two accounts
    completed. Multipart messages (over 255 bytes) are not yet checked.
  - `CHAT_MSG_GUILD` is a valid event (November 18, 2026). Its second
    argument, the sender, is the roster name with the first and the last
    name and no realm suffix (`Nixia Ameldus`, also with a UTF-8 letter:
    `Æz Clap`). The text and the sender were not secret, also for own
    lines written in combat and for own lines written inside a dungeon.
  - The text of a `CHAT_MSG_GUILD` line with an item link carries the link
    as `|cnIQ1:|Hitem:4603::::::::45:1485:::::::::|h[Raw Spotted Yellowtail]|h|r`:
    the colour is the named form `|cn<name>:`, not `|cffRRGGBB`. Code that
    keeps or strips colour codes must know both forms.
  - These globals exist (November 18, 2026, `/oooo sync probe chatframe`):
    `SetItemRef`, `HandleModifiedItemClick`, `date` (functions),
    `ItemRefTooltip`, `UISpecialFrames`, `EventRegistry` (tables).
  - `CreateFrame("ScrollingMessageFrame")` works, and the frame has every
    method that the chat history window uses. `SetScrollOffset(n)` counts
    messages from the bottom (0 is the bottom) and clamps: with 40 messages,
    `SetScrollOffset(1000)` gives offset 39 and `AtTop()` true.
  - A click on a custom hyperlink `|Haddon:<addon name>:<data>|h[text]|h` in
    the chat frame reaches
    `EventRegistry:RegisterCallback("SetItemRef", fn, owner)`. The callback
    gets the owner, the link data (`addon:OOOOguildcompanion:probe`), the
    whole link text with its colour code, the button (`LeftButton`), and the
    chat frame. Checked with `/oooo sync probe chatlink`.
  - Professions (November 19, 2026, build 70959, `/oooo sync probe
    professions`). Forever has the Retail profession API. These exist:
    `GetProfessions`, `GetProfessionInfo`, `IsPlayerSpell`, `IsSpellKnown`,
    `C_SpellBook.IsSpellKnown`, `C_SpellBook.IsSpellInSpellBook`,
    `C_Spell.GetSpellName`, `C_Spell.DoesSpellExist`,
    `C_Spell.RequestLoadSpellData`, `C_Item.GetItemNameByID`,
    `C_Item.DoesItemExistByID`, `C_Item.RequestLoadItemDataByID`,
    `strcmputf8i`, `strlenutf8`, `debugprofilestop`, the frame
    `ProfessionsFrame`, and in `C_TradeSkillUI`: `GetAllRecipeIDs`,
    `GetFilteredRecipeIDs`, `GetRecipeInfo`, `GetRecipeSchematic`,
    `GetRecipeItemLink`, `GetRecipeOutputItemData`, `GetBaseProfessionInfo`,
    `GetChildProfessionInfo`, `GetProfessionInfoBySkillLineID`,
    `GetAllProfessionTradeSkillLines`, `GetTradeSkillDisplayName`,
    `IsTradeSkillReady`, `IsTradeSkillLinked`, `IsTradeSkillGuild`,
    `IsNPCCrafting`, `OpenTradeSkill`.
  - These are missing: `GetNumTradeSkills`, `GetTradeSkillInfo`,
    `GetTradeSkillItemLink`, `GetTradeSkillRecipeLink`,
    `GetTradeSkillNumReagents`, `GetTradeSkillReagentItemLink`,
    `GetNumCrafts`, `GetCraftInfo`, and the frames `TradeSkillFrame` and
    `CraftFrame`. The events `CRAFT_SHOW` and `CRAFT_UPDATE` are invalid.
  - These events are valid: `TRADE_SKILL_SHOW`, `TRADE_SKILL_CLOSE`,
    `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_DATA_SOURCE_CHANGED`,
    `NEW_RECIPE_LEARNED`, `SKILL_LINES_CHANGED`, `SPELLS_CHANGED`,
    `GET_ITEM_INFO_RECEIVED`, `ITEM_DATA_LOAD_RESULT`,
    `SPELL_DATA_LOAD_RESULT`.
  - Profession ids are the Classic skill line ids (164 Blacksmithing,
    165 Leatherworking, 171 Alchemy, 197 Tailoring, 202 Engineering,
    333 Enchanting, 185 Cooking, 129 First Aid, 186 Mining, 182 Herbalism,
    393 Skinning, 356 Fishing).
    `C_TradeSkillUI.GetProfessionInfoBySkillLineID(id)` always returns a
    table (`professionID`, `professionName`, `skillLevel`, `maxSkillLevel`,
    `isPrimaryProfession`); `skillLevel` and `maxSkillLevel` are 0 for a
    profession that the character lacks. There are no child skill lines:
    `GetChildProfessionInfo()` is empty and `expansionName` is `'Unknown'`.
    Do not read the levels from it in a fresh session: for 60 seconds
    after a login, and before any profession window was open, it showed
    level 0 for every profession. It showed the levels only after a
    profession window had been open.
  - `GetProfessions()` returns indexes (`7, 9, 5, 8, 6`), and
    `GetProfessionInfo(index)` returns the name, icon, level, maximum, and
    as 7th value the skill line id. `GetProfessions()` gave its indexes
    1.5 seconds after `PLAYER_LOGIN`, without a profession window. In the
    60 seconds after a login `SPELLS_CHANGED` came once (at 1.5 seconds)
    and `SKILL_LINES_CHANGED` never. Whether `GetProfessionInfo(index)`
    gives the levels in a fresh session is not yet read from the report.
  - Recipes need the profession window. After a login
    `C_TradeSkillUI.GetAllRecipeIDs()` gave nothing for 60 seconds. Once a
    window was open it returns the recipes of the profession that was
    opened last, also after the window is closed.
    `GetBaseProfessionInfo()` names that profession only while the window
    is open (`professionID` is 0 afterwards), and `IsTradeSkillReady()` is
    true only then. A filter in the window changes only
    `GetFilteredRecipeIDs()`, not `GetAllRecipeIDs()`.
  - A recipe id is the craft spell id. `GetRecipeInfo(id)` gives `recipeID`,
    `name`, `learned`, `icon`, `hyperlink`; `GetRecipeSchematic(id, false)`
    gives `outputItemID`, `quantityMin`, `quantityMax`, and
    `reagentSlotSchematics[i]` with `quantityRequired` and
    `reagents[1].itemID`. Both also answered for recipes of professions
    that the character lacks (2660, 18560), also right after a login with
    no profession window opened in the session.
    For an id that is no recipe they return a table with `recipeID = 0`
    and an empty name, not nil. That was so for 2330, the Classic craft
    spell of Minor Healing Potion, which also has no spell name: Forever
    moved that recipe from Alchemy to First Aid (said by the user, not
    probed), so a Classic recipe id is not always valid. Forever's own
    recipes have ids above 1.2 million (1229737 Basic Campfire, in
    Cooking; 1230117 First Aid Kit).
  - Item names (`/oooo sync probe nameload`, right after a client start):
    `C_Item.GetItemNameByID` named few items at once (6 of 50, 5 of 200,
    85 of 800). `C_Item.RequestLoadItemDataByID` for all the others in one
    frame (up to 715 requests) was answered completely within 0.25
    seconds, each by `ITEM_DATA_LOAD_RESULT` (item id, success);
    `GET_ITEM_INFO_RECEIVED` never came. The client stayed connected. A
    load can fail for an id that `C_Item.DoesItemExistByID` accepts (an
    unused item); such an id has no name. `C_Spell.GetSpellName` named 50
    of 50 spells at once.
  - `string.lower` handles UTF-8: `ÄÖÜ ПРИВЕТ Æ` gives `äöü привет æ`.
  - No profession value was secret (out of combat, outside an instance).
  - Profession links in chat cannot be clicked, so the window never showed
    the profession of another player. `IsTradeSkillLinked()` returned
    `false, nil`, and `IsTradeSkillGuild()` and `IsNPCCrafting()` false,
    for the own window. How they answer for foreign data is not checked.
  - Not yet checked: addon messages in a raid group and in a raid instance
    (the raids unlock on December 9, 2026), and during a boss encounter.
- If you are not sure that an API exists on Forever, say so and write a
  capability probe. Do not invent `C_` functions. The Blizzard UI source at
  `F:\Projects\WowAddons\BlizzardInterfaceCode\` is for Classic, not Forever, so
  an API found there may be missing in the game.
- Skin and inform. Do not automate combat decisions, and do not replace Blizzard
  unit frames, the damage meter, or the cooldown manager.

## Guild-Only Behaviour

- Guild features run only when the character is in `OO OO`. Check the guild name
  after `PLAYER_GUILD_UPDATE` or `GUILD_ROSTER_UPDATE`, because
  `GetGuildInfo("player")` returns nil for some seconds after login. A character
  outside the guild gets one message and no guild functions.
- Roster data arrives asynchronously. Request it with
  `C_GuildInfo.GuildRoster()` and read it on `GUILD_ROSTER_UPDATE`. Do not
  request it on a timer; the server throttles the request.
- Addon-to-addon communication uses one registered prefix (`OOOO`) on two
  addon channels: `"GUILD"` for what every member needs, and `"WHISPER"` for a
  transfer between two members. Whisper only to a member that the roster shows
  online: a whisper to an offline name prints a system line. A message from another guild member is untrusted input:
  validate the type and range of every field, and never run received text as
  code. Verify on the live client whether addon messages are restricted in
  instances and in combat before a feature depends on them.
- Put a protocol version in every message so that members with different addon
  versions do not break each other.

## Combat Lockdown And Taint

- Protected functions cannot be called while `InCombatLockdown()` is true.
  Before you show, hide, or move a protected frame, check it; in combat, queue
  the closure and run it on `PLAYER_REGEN_ENABLED`.
- Avoid tainting Blizzard frames. When a hook is necessary, use
  `hooksecurefunc`.

## Events And Performance

- Use one event frame and a handler table keyed by event name. Do not grow an
  `if`/`elseif` chain.
- Use `RegisterUnitEvent` when the set of units is known. Unregister events that
  are no longer needed.
- Do not poll with `OnUpdate` when an event exists. If `OnUpdate` is required,
  throttle it with an accumulator.
- In hot paths, reuse tables (`wipe(t)`) and avoid string concatenation.

## Saved Variables

- Declare saved variables in the TOC (`## SavedVariables`,
  `## SavedVariablesPerCharacter`).
- They are populated after the addon's files run. Read and create them in
  `ADDON_LOADED` for this addon, never at file scope.
- Migrate the schema by a version field. Do not silently overwrite user data.

## Frames And Libraries

- Name a frame only when external code needs `_G["FrameName"]` access.
- A frame with a backdrop needs `BackdropTemplate`. Do not use the `TOOLTIP`
  strata for normal UI.
- Access libraries through LibStub and embed them in the addon. Ace3,
  LibDataBroker-1.1, and LibDBIcon-1.0 are acceptable; third-party library
  folders are excluded from luacheck.

## Lua Style

- Every Lua file starts with `local addonName, ns = ...`. Export through `ns`;
  create a global only for saved variables, slash commands, and key binding
  labels.
- Local by default. 2-space indentation, no tabs, lines up to 120 characters.
- Function signatures use standard spacing: `function foo(a, b, c)`.
- Comments explain a non-obvious why: a lockdown workaround, a Forever quirk,
  taint avoidance.

## Quality Checks

- `luacheck` must report 0 warnings with the committed `.luacheckrc`. Prefix
  intentionally unused values with `_`. Add a new WoW API global to `stds.wow`
  in `.luacheckrc` only after you know it exists on Forever.
- luacheck is installed through luarocks and has no Windows launcher. Run it
  through `lua` from the repository root (PowerShell):

  ```powershell
  $env:LUA_PATH = "$env:APPDATA\luarocks\share\lua\5.4\?.lua;$env:APPDATA\luarocks\share\lua\5.4\?\init.lua;;"
  $env:LUA_CPATH = "$env:APPDATA\luarocks\lib\lua\5.4\?.dll;;"
  lua "$env:APPDATA\luarocks\bin\luacheck" . --codes
  ```

- Run all host tests with `lua Tests/run_all.lua`, or one with
  `lua Tests/<name>.lua`, from the repository root. Tests run on host Lua 5.4
  without the game, so they cover only logic that does not call the WoW API.
- luacheck and host tests do not prove that the addon works in the game. Say
  which parts were checked only on the host and need a test in the client.

## Tracking Project Structure

Use and keep updated `.agents/project-map.md` with directories and source files
designations, what those contain, for faster lookup of code locations.