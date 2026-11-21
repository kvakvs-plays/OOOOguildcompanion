# Project map

Where things are. Update this file when a directory or source file is added,
moved, or removed.

## Repository root

| Path | Contents |
| --- | --- |
| `AGENTS.md` | Rules for agents: target client, API facts, style, checks. |
| `CHANGELOG.md` | User-facing changes of each release, newest first; the source of the "What's new" window, in a fixed form (see `AGENTS.md`). |
| `.luacheckrc` | luacheck config for the whole repository: `lua51+wow` for `Addon`, `lua54` for `Tests`; `Addon/Ace3` excluded. |
| `.agents/00-plan.md` | Plan of the protected tables (officer tables, self tables) and of the gambling engine: sections 12 to 18, stages 13 to 15. |
| `.agents/sync-design.md` | Design of what is built: the sync engine, guild chat, mentions, professions. Sections 1 to 8 and 11 of the earlier plan; code comments cite them as "plan section N". |
| `.agents/00-finished.md` | Finished steps of the plans, compacted. |
| `.agents/project-map.md` | This file. |
| `install.bat.txt`, `release.bat.txt` | Templates of the local, git-ignored `install.bat` and `release.bat`. |
| `.env` | Git-ignored; holds `DISCORD_BOT_TOKEN`. |

## `scripts/`

| Path | Contents |
| --- | --- |
| `release_tool.py` | `install` and `zip` commands; writes the TOC from the template and `Src/Changelog/ChangelogData.lua` from `CHANGELOG.md` (`parse_changelog`); holds `VERSION`, `COPY_DIRS`, `COPY_FILES`, `NOT_PACKAGED`. |
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
| `Slash.lua` | `ns.newDispatcher`: command dispatch by first word, and `SetDefault` for the prefix alone; `ns.slash` (`/oooo`) and `ns.syncSlash` (`/oooo sync`); `ns.print`. No WoW API. Loads before `Core.lua`. |
| `Database.lua` | `ns.database`: `SCHEMA_VERSION` (4: `db.global.gamble`), the migration steps, `migrate(db, randomFn)`, creation of the sync origin. Host-testable, no WoW API. Loads after `Sync/VersionId.lua`. |
| `Core.lua` | AceAddon object, AceDB setup and the call of `ns.database.migrate`, the start of the sync session and of the guild state on `PLAYER_LOGIN`, registration of `/oooo` (alone it opens the window of `Window/MainWindow.lua`) and of the `/opt` alias (`addon:SetOptAliasEnabled`), LuaLS classes of the saved variables. |
| `Emoji/EmojiIndex.lua` | Generated list of emoji names per Discord guild (`ns.emojiIndex`). |
| `Emoji/EmojiAliases.lua` | Hand-edited aliases per emoji (`ns.emojiAliases`). |
| `Emoji/EmojiOptions.lua` | Hand-edited per-emoji options such as `caseSensitive`. |
| `Emoji/Emoji.lua` | `ns.emoji`: builds the emoji list from index, aliases, and options. |
| `Guild/GuildState.lua` | `ns.guildState`: `GUILD_NAME`, the guild check (`state`: `unknown`, `in`, `outside`), the roster cache `name -> { online, rankIndex }`, `ns.OFFICER_RANKS` and `IsOfficer`, `normalizeName`, `NoteOnline`, `IsRosterComplete`, the callbacks `OnGuildStateChanged` and `OnRosterChanged`, `Start` with the event frame. Host-loadable. Loads after `Core.lua`. |
| `Window/MainWindow.lua` | `ns.mainWindow`: the one window of the addon (`/oooo`), an AceGUI-3.0 frame with a tab group. `RegisterTab` (`id`, `title`, `order`, `Build(container)`, `Close()`), `Create`, `Open(tabId)`, `Toggle`, `ShowTab`, `CloseTab`, `SetStatus`, `IsShown`; the AceGUI layouts `OOOOColumns`, `OOOORows`, `OOOOLine`; size, place, and last tab in `db.profile.window`. Game only. Loads after `Guild/GuildState.lua`, before every tab. |
| `Emoji/EmojiChat.lua` | `ns.emojiChat`: replaces emoji names in the kinds of chat of `CHANNELS` (guild, party, raid, officer, say, General, Trade) that `db.profile.general.emojiChannels` turns on (`IsChannelEnabled`, `SetChannelEnabled`); `GetSize`, `SetSize`; the filters follow `OnGuildStateChanged`. |
| `Options/OptionsWindow.lua` | `ns.optionsWindow`: the AceConfig settings window with the General tab (with the section "Mentions") and the Emoji tab, and the Sync tab from `Sync/SyncOptions.lua`. |
| `Sync/Base94.lua` | `ns.base94`: `encode`, `decode`, `isValid`, the 32-bit `hash`, byte-wise `compare`. Host-testable, no WoW API. |
| `Sync/VersionId.lua` | `ns.versionId`: `make`, `parse`, `originOf`, `isWellFormed`, `isValid`, `timePrefix`, `newOrigin`, `newGenerator`, `ZERO`. Host-testable, no WoW API. |
| `Sync/SyncStore.lua` | `ns.syncStore`: one table of the shared database. `newTable`, `apply` (last writer wins, clock, `fp`, `maxId`), `tableVersion`, `parseTableVersion`, `rebuild`; for transfers `digest`, `parseDigest`, `selectDelta`, `splitBatches`, `applyBatch`, `clockRest`, `mergeClock`, `wants`, `estimateSize`, `versionOfClock`; for the cleanup `isStale`, `reset`, `TOMBSTONE_SECONDS`, `STALE_SECONDS`; the shared limits `MAX_KEY_LENGTH`, `MAX_TABLE_NAME_LENGTH`, `MAX_TABLES`. Host-testable, no WoW API. |
| `Sync/SyncTables.lua` | `ns.sync`: registry of table definitions (`RegisterTable`), `Initialize` with the stored database, `GetTable`, `GetOrigin`, `OriginFor` (character origin of a self table, install origin elsewhere; one generator per origin in `generators`), `IsOfficer`, `IsBehind` (asks the session through `isBehindFn`); the API `Put`, `Append`, `Get`, `Delete`, `Iterate`, `Count`, `NewId`, `GetId`, the callback `OnRecordChanged`, and `dirtySince`; the owner rule `MayWrite` and `keyName`; the protected tables (`writers = "officer"` or `"self"`): `IsProtected`, `WriteRefusal`; `ApplyRemote` merges received records with their checks (its `sender` gives `firstHand` of `OnRecordChanged` in a self table); the local cleanup `Sweep`, `RemoveOldTombstones`, `Reset`, and for a table with `maxAge` `IsExpired` and `Expire`; `Size`. Needs LibStub and CallbackHandler-1.0; no WoW API. |
| `Sync/SyncCharacter.lua` | `ns.syncCharacter`: the table `character` (class, level, origins), `validate`, `buildPayload`, `alts`, `shareOrigin`, `hasOrigin`, `playerName`, `WriteOwn` (called on `OnGuildStateChanged`); `ns.sync:GetAlts`, `ns.sync:IsAltOf`, `ns.sync:IsOriginOf`. Host-loadable. |
| `Sync/SyncCommands.lua` | `ns.syncCommands`: the developer tables `debug` (`EnableDebugTable`), `debugofficer` and `debugself` (`EnableDeveloperTables`, called when `db.global.debugTable` is on) and `/oooo sync put|get|del [debugofficer|debugself] ...|status|debug` (a character key with its space, or `me`); the developer mode (`isDeveloper`, `policyOverrides`); `statusLines` (tables with "held by N of M officers online" for a member's own writes of a self table, discovery, peers), `escape`. Host-loadable. |
| `Sync/SyncProtocol.lua` | `ns.syncProtocol`: `new(serializer)` gives `encode` and `decode` of the messages (`H`, `S`, `Q`, `D`, `B`, `P`, the whisper `A` "here", and the whisper `K` "held") with the checks of every field; `packRecords`, `VERSION`, `CHANNELS`, `NEWER`, the limits, the refusal reasons. Host-testable, no WoW API. |
| `Sync/SyncComm.lua` | `ns.syncComm`: `new(parts)` gives a transport (`Send`, `Receive` with the sender checks, `SetActive`, `onMessage`, `drops`); `Start()` builds the transport of the game on AceComm-3.0 with the prefix `OOOO` (`ns.syncComm.transport`) and hides the system line of a whisper to an offline name (`offlineNoticeName`). Host-loadable. |
| `Sync/SyncPolicy.lua` | `ns.syncPolicy`: `conditionMet`, `effective` (table definition plus the override in `db.profile.sync.tables`), `new(parts)` (the view that the session asks), and for the game `state`, `Refresh`, `Start`, the callback `OnConditionsChanged`. Host-loadable. |
| `Sync/SyncSession.lua` | `ns.syncSession`: `new(parts)` gives a session: the hello 20 to 40 s after the guild check, the answer to a hello after 1 to 8 s with its suppression, the whisper "here" to the sender of a hello (`OwePresence`, `SendPresence`, `ToldGuild`, the last-whispered map `whisperedAt` with `Whisper`), the peer list, `StatusLines`; the rank helpers of protected tables `IsProtected`, `IsOfficerName`, `IsOfficerSelf`, `IsVouched`; `Start()` builds the session of the game (`ns.syncSession.current`); `Session` and `handlers` are open for `SyncPull.lua` and `SyncPush.lua`. Host-loadable. |
| `Sync/SyncPull.lua` | `ns.syncPull`: the pull, added to the session class of `SyncSession.lua`. Responder: the handler of `Q`, `Refuse`, `SendBatch`. Requester: `chooseSource` (with an optional source filter), `SourceFilter` (officers only for a protected table), `responderVersion`, `PumpPulls` (the queue), `StartPull`, the handlers of `D` and `B`, `FinishPull`, `CheckRecord` (the verdict `"seen"`: roster rule and age rule). The constants of batch size, timeouts, and waits. Host-loadable. |
| `Sync/SyncPush.lua` | `ns.syncPush`: the push, added to the session class. `SendPush` (one or several `P` with bases), the push marks per origin (`pushed`, `pushedBy`), `PushLocal`, `SchedulePush`, `MarkUnpushed`, `PushWanted` (after a pull), `OwnSlice`, `PushMark`, `MarkOwnPushed` (for the repeated push of `SyncDelivery.lua`), `MayPush` (no push of a member into an officer table), `PushesOwnOnly` (a member in a self table pushes only its own character's records), the periodic summary (`ScheduleSummary`, `SendSummary`), the handler of `P`, `NoteVersions` with `HoldsBack` (a member's version holds back no officer), `ScheduleDelayedPull`, `RememberOwnVersion`. Host-loadable. |
| `Sync/SyncCleanup.lua` | `ns.syncCleanup`: the local cleanup, added to the session class. `CleanUp` (old tombstones, once per stay in the guild), `CleanRoster` (records of characters who left), `ExpireTables` (records over the `maxAge` of their table, at the start and every hour), `IsStale`, `MarkFresh`, `ResetIfStale`. Host-loadable. |
| `Sync/SyncDelivery.lua` | `ns.syncDelivery`: the delivery of a member's own records of a self table to the officers (plan 14.6), added to the session class. Officer: `OweHeld` and `SendHeld` (the whisper `K` 1 to 5 s after a member's push), `SendOwedHeld`. Member: the map `held` (`NoteHeld`, `ForgetHeld` on a hello, `NoteHeldVersions`, `NoteHeldAfterPull`), the handler of `K`, `RepeatPush`, the check `CheckDelivery` every `CHECK_INTERVAL` (120 s), `MAX_REPEATS` (3); `OnlineOfficers`, `IsBehind`, `HeldStatus`; `StartDelivery`, `StopDelivery`. Host-loadable. Loads after `Sync/SyncCleanup.lua`. |
| `Sync/SyncOptions.lua` | `ns.syncOptions`: the "Sync" tab of the settings window, shown only in the developer mode (`buildTab`), `statusText`, `ago`, `setOverride`, `getValue`. Host-loadable. |
| `Sync/SyncGuildChat.lua` | `ns.guildChat`: the table `guildchat` (the guild chat of the last `KEEP_DAYS` days, one record per line under its own id), `validate`, the capture `OnChatLine` with `ShouldWrite`, the witness rule `IsWitness`, and the warning `WarnIfUnshared` for a mention that no peer can copy, the event frame (`SetListening`, `handlers`), the ordered reading `Lines(sinceTime)` with `Keys`, `Payload(id)`, and `Page(beforeId, count)` for a reader that goes back in time, `DUPLICATE_WINDOW`, and the flag `bySender`, `PrintLines`, `CaptureStatus` (the counts of the session), and `/oooo sync chat`. Host-loadable. Loads after `Sync/SyncOptions.lua`. |
| `Guild/AddonInventory.lua` | `ns.addonInventory`: the table `addon` (one record per character: addon version `v` and the server time `t` of the last write), `validate`, `needsWrite`, `WriteOwn` after the guild check and every `HEARTBEAT` seconds; the reading per player `playerRecord` (the newest record among a character and its alts), `rows`, `rowText`, `lines`; `groupNames` (party or raid units), `PrintVersions`, and `/oooo versioncheck`. Host-loadable. Loads after `Sync/SyncGuildChat.lua`. |
| `Chat/Mentions.lua` | `ns.mentions`: `@` words in guild chat (plan stage 11). `parseWatchList`, `hasMention`, `fragments` (the watched `@text` parts of a line), `sanitize` (the text of an untrusted line for the window). The mention list in `db.global.mentions` (`lines`: record id -> read, `lastOnline`): `Attach(parts)`, `Reconcile`, `OnRecordChanged`, `StartsRead`, `List`, `UnreadCount`, `MarkRead`, `NoteOnline`, `WatchChanged`, the callback `OnMentionsChanged`; the notice (`noticeText`, `CheckNotice`, `ScheduleNotice`, `ScheduleLoginNotice`, the marks in `noticed`, `LINK` with `RegisterLink`); and `Start` for the game. Host-loadable. Loads after `Sync/SyncGuildChat.lua`. |
| `Chat/ChatHistory.lua` | `ns.chatHistory`: the model of the chat history window, without frames. `Open`, `Close`, `LoadOlder`, `LoadBackTo`, `IndexOf`, `Highlight`, `OnRecordChanged` with `Refresh` and `onChanged`, `LineText`, `formatTime`, `PAGE`. Host-loadable. |
| `Chat/ChatHistoryTab.lua` | `ns.chatHistoryTab`: the tab "Guild chat" of the addon window: `Build`, `Close`, `Open`, `Fill`, `ShowLine`, `ScrollToIndex`, `LoadOlder`, `OnHyperlinkClick`; the AceGUI widget type `OOOOMessageLog` (a ScrollingMessageFrame); the lists "Unread" and "Read" of mentions (`UpdateMentions`, `OnMentionClick`); the probes `chatframe` and `chatlink`. Game only. |
| `Professions/ProfessionData.lua` | `ns.professionData`: the table `profession` (one record per character and profession: levels and the packed recipe ids). `packRecipes`, `unpackRecipes`, `isRecipeList`, `recipeCount`, `mergeRecipes` (a scan only adds), `key`, `parseKey`, `validate`. Host-testable, no WoW API. |
| `Professions/ProfessionScan.lua` | `ns.professionScan`: the scan of the own professions into the table `profession`. `new(parts)` gives a scanner on a reader of the client (`OOOOProfessionReader`): `ReadProfessions` (levels, the hint `Hint`, the delete of an unlearned profession by two reads in `CheckUnlearned`), `ScheduleRead`, `ScanWindow` (learned recipes of the open window, across frames) with `ScheduleScan`, `OnNewRecipe`, `WriteRecord`, `StatusLines`; `clientReader` (the Retail profession API), the event frame (`SetListening`, `handlers`), and `/oooo sync prof`. Host-loadable. Loads after `ProfessionData.lua`. |
| `Professions/ProfessionRecipes.lua` | `ns.professionRecipes`: `Facts(recipeId)` gives the name, icon, item, count, and reagents of a recipe from the own client (`client`: `info`, `schematic`), kept for the session; nil for an id that is no recipe. `ProfessionName(id)` gives the name of a profession in the language of the client. Host-loadable. |
| `Professions/ProfessionNames.lua` | `ns.professionNames`: item names for the session. `new(parts)` gives a loader: `Name(itemId)`, `Prepare(itemIds)`, `OnAnswer`, `Progress`, `StatusLine`, the callback `OnNamesChanged`; requests wait 10 s after the login and go out 40 per 0.2 s (`Pump`), a lost one fails after `TIMEOUT`. `Start()` makes the loader of the game (`current`). Host-loadable; needs CallbackHandler-1.0. |
| `Professions/ProfessionSearch.lua` | `ns.professionSearch`: the model of the window "Guild professions", without frames. `new(parts)` gives a model: `Open`, `Close`, the index `recipe id -> record keys` (`SetRecord`, `OnRecordChanged`, `onChanged`), `Search(recipeText, materialText)` (rows and the total), `Detail(recipeId)`, `Crafters`, `PrepareNames`, `RecipeCount`; `needle`, `MAX_ROWS`. Host-loadable. |
| `Professions/ProfessionSearchTab.lua` | `ns.professionSearchTab`: the tab "Recipes" of the addon window, AceGUI widgets over `ProfessionSearch.lua`: `Build`, `Close`, `CreateModel`, `RunSearch`, `ScheduleSearch`, `UpdateRows`, `UpdateStatus`, `UpdateDetail`, `OnRowClick`, `OnCraftLinkClick`. Game only. |
| `Professions/ProfessionRoster.lua` | `ns.professionRoster`: the model of the tab "Members", without frames. `rows(parts, professionId)` lists the members of the table `profession` with their professions (in the order of the names that `parts.professionName` gives), levels, recipe counts, and the class of the table `character`; with a profession only its members, highest level first. Host-testable, no WoW API. |
| `Professions/ProfessionRosterTab.lua` | `ns.professionRosterTab`: the tab "Members" of the addon window: the profession dropdown and one line per member with an icon per profession (the AceGUI widget type `OOOOProfessionIcon`: icon, skill and highest skill at the bottom right, name in the tooltip; `PROFESSION_ICONS`). `Build`, `Close`, `Update`, `ScheduleUpdate`, `UpdateDropdown`. Game only. |
| `Professions/ProfessionProbe.lua` | `ns.professionProbe`: the probes of plan step 12.1. `professions [label]` (existence of the profession API, the list of professions, the window, the recipes, specializations, `lowerVerdict`; one report `professions:<label>` per label), `StartLoginWatch` (armed by `professions login`, called by `Core.lua`), and `nameload <count> [spells]` (many name requests at once; cursor in `db.global.probeCursor`); `dump`. Host-loadable. |
| `Gamble/GambleData.lua` | `ns.gambleData`: the tables `gamble` (`writers = "officer"`: events, the book, the dues) and `gamble_player` (`writers = "self"`: bets, receipts) of plan section 15.2. Constants (`TABLE`, `PLAYER_TABLE`, `KEEP_DAYS`, `MAX_GOLD`, `CAP_BELOW`, the states), `eventKey`, `bookKey`, `dueKey`, `betKey`, `receiptKey`, `parseKey(tableName, key)` (by position), `validateGamble`, `validatePlayer`. Host-testable, no WoW API. |
| `Gamble/GambleSettle.lua` | `ns.gambleSettle`: the settlement of plan section 15.5 on plain tables. `BANK_SHARE`, `claim(stake, outcome)` (with the cap `x`), `settle(outcomes, results, bets)` (nets, `won`, `paid`, `bank`), `dues(settlement, banker)`. Host-testable, no WoW API. |
| `Gamble/Gamble.lua` | `ns.gamble`: the model of the gambling events, without frames (plan sections 15.3, 15.4). `new(parts)` gives a model: for officers `Open(spec)`, `Lock`, `Cancel`; for everybody `PlaceBet(eventId, stakes)`, `TakeBack`; the reading `Events()` (groups `open`, `waiting`, `toPay`, `done`), `Detail(eventId)` (booked sums only after the close), `BetState(eventId)`, `BookedBets(eventId)`, `Event(eventId)`. `Start()` makes the model of the game (`current`). Host-loadable. Loads after `GambleData.lua`. |
| `Gamble/GambleBook.lua` | `ns.gambleBook`: the booking of bets by the officers (plan section 15.4). `new(parts)` gives a booker that listens to `OnRecordChanged`: a first-hand bet gets a book entry with its time of receipt after a random delay, a first-hand take-back deletes it, a bet without its event waits; `Stop`, `Start()` (`current`), `BOOK_DELAY_MAX`, `MAX_WAITING`. Host-loadable. Loads after `Gamble.lua`. |
| `Changelog/ChangelogData.lua` | Generated and git-ignored: `ns.version` and `ns.changelog` (the release notes), written by `scripts/release_tool.py` from `CHANGELOG.md`. |
| `Changelog/ChangelogWindow.lua` | `ns.changelogWindow`: the frame "What's new" (`/oooo new`): `Create`, `Open`, `Toggle`, `Select`, `UpdateList`, `RenderPage`; position in `db.profile.changelog`; the line after the guild check with the link (`noticeText`, `db.global.changelogSeen`). Game only. |
| `Sync/SyncProbe.lua` | `ns.syncProbe`: `/oooo sync probe <name>`, the probe registry, reports stored in `db.global.probeResults`, and the computing helpers of the probes (`rosterVerdict` of the probe `roster` for plan step 8.2). Host-loadable. |

## `Tests/` (host only, Lua 5.4, not packaged)

Run from the repository root: `lua Tests/run_all.lua` or `lua Tests/<name>.lua`.

| Path | Contents |
| --- | --- |
| `harness.lua` | `load(path, ns)` runs an addon file as the game does; `eq`, `ok`, `raises` exit with code 1 on the first failure; `newRandom(seed)`; `loadLibraries()` (LibStub and CallbackHandler-1.0 on the host); `loadAll(paths, ns)`; `luaCommand(script)`; `finish()`. |
| `fakenet.lua` | In-memory guild network for the session tests: fake clock and timers (`After`, `Advance`), endpoints (`Join`, `Send`, `receive`, `onRosterChanged`), delay, loss, `dropIf`, a send queue with `sendRate`, in-order arrival, `SetOnline`, `SetRank`, `Leave`, the roster view `net.guild` (`rosterIncomplete`), the message `log`. |
| `run_all.lua` | Runs every `Tests/sync_*.lua` in its own process and prints one summary line. |
| `sync_harness.lua` | Tests of the harness itself. |
| `sync_guildchat.lua` | Tests of `Sync/SyncGuildChat.lua`: capture, `validate`, `Lines`, retention, the member who was offline (the race after login, a cut pull), and the witness. |
| `sync_mentions.lua` | Tests of `Chat/Mentions.lua`: the watch list, `hasMention`, `fragments`, `sanitize`; the mention list with replicas (read and unread at arrival, `MarkRead`, expiry, the check at login); the notice; a click on a mention in the model of the window; the warning for a mention that nobody can copy. |
| `sync_chathistory.lua` | Tests of `ns.guildChat:Page` and of `Chat/ChatHistory.lua`. |
| `sync_guildstate.lua` | Tests of `Guild/GuildState.lua`, with stubbed guild and roster functions. |
| `sync_alts.lua` | Tests of `Sync/SyncCharacter.lua` and `Sync/SyncCommands.lua`. |
| `sync_api.lua` | Tests of `Put`, `Get`, `Delete`, `Iterate`, and the callback in `Sync/SyncTables.lua`. |
| `sync_cleanup.lua` | Tests of the local cleanup: old tombstones, `Sweep`, the reset of a stale table, the roster cleanup; the size limit of a record and the size estimate. |
| `sync_comm.lua` | Tests of `Sync/SyncComm.lua` and of `fakenet.lua`. |
| `sync_base94.lua` | Tests of `Sync/Base94.lua`. |
| `sync_profdata.lua` | Tests of `Professions/ProfessionData.lua`: packing, the union, `validate`, the owner rule on the joined key; and of the engine with a record near and over the batch size (push and pull). |
| `sync_profscan.lua` | Tests of `Professions/ProfessionScan.lua` with a stub reader: the list of professions, the hint, the window scan (equal, partial, foreign, secret, across frames), a learned recipe, unlearning. |
| `sync_profnames.lua` | Tests of `Professions/ProfessionNames.lua` (direct answers, the queue and its pace, failed and lost requests, `OnNamesChanged`) and of `Professions/ProfessionRecipes.lua` (`Facts`). |
| `sync_profsearch.lua` | Tests of `Professions/ProfessionSearch.lua` with stub facts and names: the search by recipe, by material, by both; plain text; the index that follows the table; late names; the cut at 200. |
| `sync_profroster.lua` | Tests of `Professions/ProfessionRoster.lua`: the members with their professions, the order of members and of professions (by name), the filter by profession, the class. |
| `sync_inventory.lua` | Tests of `Guild/AddonInventory.lua`: `validate`, `needsWrite`, the owner rule, the rows and lines of `/oooo versioncheck`, the newest record among alts. |
| `sync_maxage.lua` | Tests of `Append`, `maxAge`, `Expire`, and the hourly expiry of the session. |
| `sync_gambledata.lua` | Tests of `Gamble/GambleData.lua`: keys built and read back, `validate` of every kind of record, the write rules with an officer and a member replica. |
| `sync_gamble.lua` | Tests of `Gamble/Gamble.lua` with an officer and member replicas: opening, bets and their refusals, lock, cancel, the groups, sanitized texts, hidden sums, every bet state. |
| `sync_gamblebook.lua` | Tests of `Gamble/GambleBook.lua`: one entry with two officers, a bet after the close, a bet under another name, a change before and after the close, a vouched bet, no officer online, a bet before its event. |
| `sync_gamblesettle.lua` | Tests of `Gamble/GambleSettle.lua`: the example of the plan, the cap, 500 random events, the dues. |
| `sync_migrate.lua` | Tests of `Database.lua`: migration and origin. |
| `sync_protocol.lua` | Tests of `Sync/SyncProtocol.lua`, with the stub serializer and with AceSerializer-3.0. |
| `sync_pull.lua` | Tests of `Sync/SyncPull.lua`, with replicas and hand-made messages on the fake network. |
| `sync_owner.lua` | Tests of the owner rule: `Put` and `Delete` in `Sync/SyncTables.lua`, and the receiver of a push. |
| `sync_self.lua` | Tests of the self tables: character origins and push marks per origin (step 13.3); the write rule, pushes and deltas of members, `firstHand`, a writer without an officer online, an alt's unsent write, no repeated pulls, the `debugself` commands, convergence of 3 officers and 5 members (step 13.4). |
| `sync_delivery.lua` | Tests of `Sync/SyncDelivery.lua` (step 13.5): the checks of `K`, a lost push sent again, an officer with a gap, a `K` from a member, the repeat limit and a hello, an officer login with an equal or older version, no officer online, `IsBehind`, the status line, delivery under 30% loss. |
| `sync_officer.lua` | Tests of the officer tables (step 13.2): the write rule, pushes and deltas of members, sources, held-back answers, a demotion, convergence of 3 officers and 5 members. |
| `sync_policy.lua` | Tests of `Sync/SyncPolicy.lua` and of what the session does with the conditions. |
| `sync_push.lua` | Tests of `Sync/SyncPush.lua`: push timer, conditions, gaps, chained pushes. |
| `sync_probe.lua` | Tests of `Slash.lua` (also the default handler) and of the computing parts of `Sync/SyncProbe.lua`. |
| `sync_discovery.lua` | Tests of discovery in `Sync/SyncSession.lua`, with replicas on the fake network. |
| `sync_converge.lua` | Tests of the whole exchange: push after a pull, periodic summary, convergence of 10 replicas with loss and offline periods. |
| `sync_delta.lua` | Tests of `Sync/SyncStore.lua`: digest, delta, batches, cut transfers, convergence of three replicas. |
| `sync_store.lua` | Tests of `Sync/SyncStore.lua`: merge, clock, fingerprint, table version. |
| `sync_tables.lua` | Tests of the registry in `Sync/SyncTables.lua`. |
| `sync_versionid.lua` | Tests of `Sync/VersionId.lua`. |
| `fixtures/` | Helper files of the tests; not matched by `run_all.lua`. `stub_serializer.lua`: a serializer with the interface of AceSerializer-3.0. `replica.lua`: builds a full replica (own namespace, database, transport, policy with `state` and `overrides`, session) on a `fakenet` network; `Replica:Hear` plays a line of guild chat; `Login` connects the mention list (`mentionStore`, `watch`); the option `developerTables` registers the protected developer tables; the option `data` shares the stored database of another replica (an alt of the same install); `Replica.withoutPush` turns the push and the periodic summary off for tests of discovery and pull alone. |
