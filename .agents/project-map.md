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
| `embeds.xml` | Loads the Ace3 libraries in use, among them AceComm-3.0 (with ChatThrottleLib) and AceSerializer-3.0. |
| `Ace3/` | Embedded Ace3 (third party, not linted). |
| `Icons/` | `Logo32/64/128/256.png`, generated from `Art/clock.png`. |
| `Icons/Emoji/<guild id>/` | Imported Discord emoji, 64x64 PNG. Generated. |
| `Art/` | `clock.png` and `make-icons.ps1`; not packaged. |

### `Addon/Src/`

| Path | Contents |
| --- | --- |
| `Slash.lua` | `ns.newDispatcher`: command dispatch by first word; `ns.slash` (`/oooo`) and `ns.syncSlash` (`/oooo sync`); `ns.print`. No WoW API. Loads before `Core.lua`. |
| `Database.lua` | `ns.database`: `SCHEMA_VERSION`, the migration steps, `migrate(db, randomFn)`, creation of the sync origin. Host-testable, no WoW API. Loads after `Sync/VersionId.lua`. |
| `Core.lua` | AceAddon object, AceDB setup and the call of `ns.database.migrate`, the start of the sync session and of the guild state on `PLAYER_LOGIN`, registration of `/oooo` and of the `/opt` alias (`addon:SetOptAliasEnabled`), LuaLS classes of the saved variables. |
| `Emoji/EmojiIndex.lua` | Generated list of emoji names per Discord guild (`ns.emojiIndex`). |
| `Emoji/EmojiAliases.lua` | Hand-edited aliases per emoji (`ns.emojiAliases`). |
| `Emoji/EmojiOptions.lua` | Hand-edited per-emoji options such as `caseSensitive`. |
| `Emoji/Emoji.lua` | `ns.emoji`: builds the emoji list from index, aliases, and options. |
| `Guild/GuildState.lua` | `ns.guildState`: `GUILD_NAME`, the guild check (`state`: `unknown`, `in`, `outside`), the roster cache `name -> { online, rankIndex }`, `normalizeName`, `NoteOnline`, the callbacks `OnGuildStateChanged` and `OnRosterChanged`, `Start` with the event frame. Host-loadable. Loads after `Core.lua`. |
| `Emoji/EmojiChat.lua` | Replaces emoji names in guild, party, and raid chat; the filters follow `OnGuildStateChanged`. |
| `Options/OptionsWindow.lua` | `ns.optionsWindow`: the AceConfig settings window with the General and Emoji tabs. |
| `Sync/Base94.lua` | `ns.base94`: `encode`, `decode`, `isValid`, the 32-bit `hash`, byte-wise `compare`. Host-testable, no WoW API. |
| `Sync/VersionId.lua` | `ns.versionId`: `make`, `parse`, `originOf`, `isWellFormed`, `isValid`, `newOrigin`, `newGenerator`, `ZERO`. Host-testable, no WoW API. |
| `Sync/SyncStore.lua` | `ns.syncStore`: one table of the shared database. `newTable`, `apply` (last writer wins, clock, `fp`, `maxId`), `tableVersion`, `parseTableVersion`, `rebuild`; for transfers `digest`, `parseDigest`, `selectDelta`, `splitBatches`, `applyBatch`, `clockRest`, `mergeClock`, `wants`, `estimateSize`, `versionOfClock`. Host-testable, no WoW API. |
| `Sync/SyncTables.lua` | `ns.sync`: registry of table definitions (`RegisterTable`), `Initialize` with the stored database, `GetTable`, `GetOrigin`; the API `Put`, `Get`, `Delete`, `Iterate`, `Count`, the callback `OnRecordChanged`, and `dirtySince`; `ApplyRemote` merges received records with their checks. Needs LibStub and CallbackHandler-1.0; no WoW API. |
| `Sync/SyncCharacter.lua` | `ns.syncCharacter`: the table `character` (class, level, origins), `validate`, `buildPayload`, `alts`, `playerName`, `WriteOwn` (called on `OnGuildStateChanged`); `ns.sync:GetAlts`. Host-loadable. |
| `Sync/SyncCommands.lua` | `ns.syncCommands`: the table `debug` and `/oooo sync put|get|del|status`; `statusLines` (tables, discovery, peers), `escape`. Host-loadable. |
| `Sync/SyncProtocol.lua` | `ns.syncProtocol`: `new(serializer)` gives `encode` and `decode` of the messages (`H`, `S`, `Q`, `D`, `B`) with the checks of every field; `packRecords`, `VERSION`, `CHANNELS`, `NEWER`, the limits, the refusal reasons. Host-testable, no WoW API. |
| `Sync/SyncComm.lua` | `ns.syncComm`: `new(parts)` gives a transport (`Send`, `Receive` with the sender checks, `SetActive`, `onMessage`, `drops`); `Start()` builds the transport of the game on AceComm-3.0 with the prefix `OOOO` (`ns.syncComm.transport`) and hides the system line of a whisper to an offline name (`offlineNoticeName`). Host-loadable. |
| `Sync/SyncSession.lua` | `ns.syncSession`: `new(parts)` gives a session: the hello 20 to 40 s after the guild check, the answer to a hello after 1 to 8 s with its suppression, the peer list, `StatusLines`; `Start()` builds the session of the game (`ns.syncSession.current`); `Session` and `handlers` are open for `SyncPull.lua`. The push comes with plan stage 6. Host-loadable. |
| `Sync/SyncPull.lua` | `ns.syncPull`: the pull, added to the session class of `SyncSession.lua`. Responder: the handler of `Q`, `Refuse`, `SendBatch`. Requester: `chooseSource`, `responderVersion`, `PumpPulls` (the queue), `StartPull`, the handlers of `D` and `B`, `FinishPull`, `CheckRecord` (roster rule). The constants of batch size, timeouts, and waits. Host-loadable. |
| `Sync/SyncProbe.lua` | `ns.syncProbe`: `/oooo sync probe <name>`, the probe registry, reports stored in `db.global.probeResults`, and the computing helpers of the probes. Host-loadable. |

## `Tests/` (host only, Lua 5.4, not packaged)

Run from the repository root: `lua Tests/run_all.lua` or `lua Tests/<name>.lua`.

| Path | Contents |
| --- | --- |
| `harness.lua` | `load(path, ns)` runs an addon file as the game does; `eq`, `ok`, `raises` exit with code 1 on the first failure; `newRandom(seed)`; `loadLibraries()` (LibStub and CallbackHandler-1.0 on the host); `loadAll(paths, ns)`; `luaCommand(script)`; `finish()`. |
| `fakenet.lua` | In-memory guild network for the session tests: fake clock and timers (`After`, `Advance`), endpoints (`Join`, `Send`, `receive`, `onRosterChanged`), delay, loss, `dropIf`, a send queue with `sendRate`, in-order arrival, `SetOnline`, `Leave`, the roster view `net.guild`, the message `log`. |
| `run_all.lua` | Runs every `Tests/sync_*.lua` in its own process and prints one summary line. |
| `sync_harness.lua` | Tests of the harness itself. |
| `sync_guildstate.lua` | Tests of `Guild/GuildState.lua`, with stubbed guild and roster functions. |
| `sync_alts.lua` | Tests of `Sync/SyncCharacter.lua` and `Sync/SyncCommands.lua`. |
| `sync_api.lua` | Tests of `Put`, `Get`, `Delete`, `Iterate`, and the callback in `Sync/SyncTables.lua`. |
| `sync_comm.lua` | Tests of `Sync/SyncComm.lua` and of `fakenet.lua`. |
| `sync_base94.lua` | Tests of `Sync/Base94.lua`. |
| `sync_migrate.lua` | Tests of `Database.lua`: migration and origin. |
| `sync_protocol.lua` | Tests of `Sync/SyncProtocol.lua`, with the stub serializer and with AceSerializer-3.0. |
| `sync_pull.lua` | Tests of `Sync/SyncPull.lua`, with replicas and hand-made messages on the fake network. |
| `sync_probe.lua` | Tests of `Slash.lua` and of the computing parts of `Sync/SyncProbe.lua`. |
| `sync_discovery.lua` | Tests of discovery in `Sync/SyncSession.lua`, with replicas on the fake network. |
| `sync_delta.lua` | Tests of `Sync/SyncStore.lua`: digest, delta, batches, cut transfers, convergence of three replicas. |
| `sync_store.lua` | Tests of `Sync/SyncStore.lua`: merge, clock, fingerprint, table version. |
| `sync_tables.lua` | Tests of the registry in `Sync/SyncTables.lua`. |
| `sync_versionid.lua` | Tests of `Sync/VersionId.lua`. |
| `fixtures/` | Helper files of the tests; not matched by `run_all.lua`. `stub_serializer.lua`: a serializer with the interface of AceSerializer-3.0. `replica.lua`: builds a full replica (own namespace, database, transport, session) on a `fakenet` network. |
