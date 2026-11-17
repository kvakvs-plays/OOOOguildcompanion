# Project map

Where things are. Update this file when a directory or source file is added,
moved, or removed.

## Repository root

| Path | Contents |
| --- | --- |
| `AGENTS.md` | Rules for agents: target client, API facts, style, checks. |
| `.luacheckrc` | luacheck config for the whole repository: `lua51+wow` for `Addon`, `lua54` for `Tests`; `Addon/Ace3` excluded. |
| `.agents/00-plan.md` | Plan of the shared guild database: open steps. |
| `.agents/00-finished.md` | Finished steps of that plan, compacted. |
| `.agents/project-map.md` | This file. |
| `install.bat.txt`, `release.bat.txt` | Templates of the local, git-ignored `install.bat` and `release.bat`. |
| `.env` | Git-ignored; holds `DISCORD_BOT_TOKEN`. |

## `scripts/`

| Path | Contents |
| --- | --- |
| `release_tool.py` | `install` and `zip` commands; writes the TOC from the template; holds `VERSION`, `COPY_DIRS`, `COPY_FILES`, `NOT_PACKAGED`. |
| `import_discord_emoji.py` | Imports Discord emoji into `Addon/Icons/Emoji` and generates `Src/Emoji/EmojiIndex.lua`. |

## `Addon/` (the addon root, installed as `OOOOguildcompanion`)

| Path | Contents |
| --- | --- |
| `toc_template.toc` | Source of the generated, git-ignored `OOOOguildcompanion.toc`; sets the load order. |
| `embeds.xml` | Loads the Ace3 libraries in use. |
| `Ace3/` | Embedded Ace3 (third party, not linted). |
| `Icons/` | `Logo32/64/128/256.png`, generated from `Art/clock.png`. |
| `Icons/Emoji/<guild id>/` | Imported Discord emoji, 64x64 PNG. Generated. |
| `Art/` | `clock.png` and `make-icons.ps1`; not packaged. |

### `Addon/Src/`

| Path | Contents |
| --- | --- |
| `Slash.lua` | `ns.newDispatcher`: command dispatch by first word; `ns.slash` (`/oooo`) and `ns.syncSlash` (`/oooo sync`); `ns.print`. No WoW API. Loads before `Core.lua`. |
| `Core.lua` | AceAddon object, AceDB setup, `SCHEMA_VERSION` and `migrate`, registration of `/oooo`, LuaLS classes of the saved variables. |
| `Emoji/EmojiIndex.lua` | Generated list of emoji names per Discord guild (`ns.emojiIndex`). |
| `Emoji/EmojiAliases.lua` | Hand-edited aliases per emoji (`ns.emojiAliases`). |
| `Emoji/EmojiOptions.lua` | Hand-edited per-emoji options such as `caseSensitive`. |
| `Emoji/Emoji.lua` | `ns.emoji`: builds the emoji list from index, aliases, and options. |
| `Emoji/EmojiChat.lua` | Replaces emoji names in guild, party, and raid chat; holds the guild check (to move to `Guild/GuildState.lua`, plan step 4.1). |
| `Options/OptionsWindow.lua` | `ns.optionsWindow`: the AceConfig settings window. |
| `Sync/Base94.lua` | `ns.base94`: `encode`, `decode`, `isValid`, the 32-bit `hash`, byte-wise `compare`. Host-testable, no WoW API. |
| `Sync/VersionId.lua` | `ns.versionId`: `make`, `parse`, `originOf`, `isWellFormed`, `isValid`, `newOrigin`, `newGenerator`, `ZERO`. Host-testable, no WoW API. |
| `Sync/SyncProbe.lua` | `ns.syncProbe`: `/oooo sync probe <name>`, the probe registry, reports stored in `db.global.probeResults`, and the computing helpers of the probes. Host-loadable. |

## `Tests/` (host only, Lua 5.4, not packaged)

Run from the repository root: `lua Tests/run_all.lua` or `lua Tests/<name>.lua`.

| Path | Contents |
| --- | --- |
| `harness.lua` | `load(path, ns)` runs an addon file as the game does; `eq`, `ok`, `raises` exit with code 1 on the first failure; `newRandom(seed)`; `luaCommand(script)`; `finish()`. |
| `run_all.lua` | Runs every `Tests/sync_*.lua` in its own process and prints one summary line. |
| `sync_harness.lua` | Tests of the harness itself. |
| `sync_base94.lua` | Tests of `Sync/Base94.lua`. |
| `sync_probe.lua` | Tests of `Slash.lua` and of the computing parts of `Sync/SyncProbe.lua`. |
| `sync_versionid.lua` | Tests of `Sync/VersionId.lua`. |
| `fixtures/` | Helper files of the tests; not matched by `run_all.lua`. |
