# Finished steps of 00-plan.md

Summaries only. The details of each step (design notes, client check
records) are in the git history of this file, before 2026-11-19.

## Stage 0. Groundwork

- **0.1 Lint and host test harness**: `.luacheckrc` at the repository root,
  `Tests/harness.lua`, `Tests/run_all.lua`, `.agents/project-map.md`.

## Stage 1. Probes

- **1.1 Slash command dispatch and the probe module**: `Src\Slash.lua` and
  `Src\Sync\SyncProbe.lua` (`/oooo sync probe <name>`).
- **1.2 Local probes**: `strings`, `time`, `ranks`, `api`; all passed on the
  release client (2026-11-17). Results are in AGENTS.md.
- **1.3 Message probes**: `listen`, `echo`, `burst`, `offline`, `state`,
  `names`; run with two accounts. Raid and boss checks are deferred (plan).

## Stage 2. Core logic with host tests

- **2.1 `Base94`**: `encode`, `decode`, `isValid`, `hash`, `compare`.
- **2.2 `VersionId`**: `make`, `parse`, validation, `newOrigin`,
  `newGenerator`, `ZERO`.
- **2.3 `SyncStore`: records, clock, fingerprint**: `newTable`, `apply`,
  `tableVersion`, `rebuild`.
- **2.4 `SyncStore`: digest, delta, batches**: `digest`, `selectDelta`,
  `splitBatches`, `applyBatch`, `wants`, and the clock rest (plan 4.2).

## Stage 3. Storage and API

- **3.1 Saved variables schema 2 and the origin**: `Src/Database.lua` with
  `migrate`; checked in the client.
- **3.2 Table registry**: `ns.sync:RegisterTable`, `Initialize`, `GetTable`,
  `GetOrigin` in `Src/Sync/SyncTables.lua`.
- **3.3 `Put`, `Get`, `Delete`, `Iterate`, callbacks**: with `Count` and the
  callback `OnRecordChanged`.
- **3.4 The `character` and `debug` tables and the slash commands**:
  `SyncCharacter.lua` (`GetAlts`), `SyncCommands.lua`; checked in the client.

## Stage 4. Transport and discovery

- **4.1 Guild state module**: `Src/Guild/GuildState.lua` with the guild
  check, the roster cache, and its callbacks.
- **4.2 Protocol: envelope, `H`, `S`**: `Src/Sync/SyncProtocol.lua` with
  `encode` and `decode`; AceComm and AceSerializer embedded.
- **4.3 Comm wiring and sender checks**: `Src/Sync/SyncComm.lua` and the
  fake network `Tests/fakenet.lua`.
- **4.4 Discovery**: `Src/Sync/SyncSession.lua` (hello, answers, peer list);
  checked in the client with two accounts.

## Stage 5. Pull

- **5.1 Protocol: `Q`, `D`, `B`**: the messages of a pull with their checks
  and limits.
- **5.2 Responder**: `Src/Sync/SyncPull.lua` answers `Q` with `D` batches of
  2000 bytes, or with `B`.
- **5.3 Requester and queue**: `chooseSource`, `PumpPulls`, `ApplyRemote`,
  the verdict `"seen"`; checked in the client with two accounts.

## Stage 6. Push and policy

- **6.1 Conditions**: `Src/Sync/SyncPolicy.lua` (`nocombat`, `noraid`,
  `resting`, overrides per table).
- **6.2 Push of local changes**: the message `P` and `Src/Sync/SyncPush.lua`
  (push timer, base check, delayed pull).
- **6.3 Push after a pull, and the delayed pull**: `PushWanted`, the periodic
  summary, and the convergence tests (`Tests/sync_converge.lua`).
- **6.4 Options page**: the "Sync" tab in `Src/Sync/SyncOptions.lua`; push,
  conditions, and the page checked in the client.

## Stage 7. Write rules

- **7.1 Owner tables**: `ns.sync:MayWrite` for `Put`, `Delete`, and a
  received push; `IsAltOf`.
- **7.2 Remove the officer option**: `writers` is `"owner"` or `"anyone"`
  only.

## Stage 8. Cleanup

- **8.1 Tombstones and the stale reset**: `Src/Sync/SyncCleanup.lua`, with
  staleness measured by `freshAt`.
- **8.2 Roster cleanup and size limits**: `CleanRoster`, `maxRecordBytes`,
  the developer mode for `debug`; checked in the client (probe `roster`).
- **8.2, the hour in the client**: not run; closed on 2026-11-18 by decision
  of the user.

## Stage 10. Guild chat table

- **10.1 Engine: `Append` and `maxAge`**: in `SyncTables.lua`, with the
  hourly `ExpireTables`.
- **10.2 Table `guildchat`: own lines, retention, reading**:
  `Src/Sync/SyncGuildChat.lua` with `Lines` and `/oooo sync chat`.
- **10.3 Witness for members without the addon**: `IsWitness` and the flag
  `bySender`.
- **10.4 A peer list without holes**: the whisper `A` "here" as answer to a
  hello.
- **10.2 and 10.3, client checks** (2026-11-18, two accounts): own lines,
  witness lines, and item links arrived whole and in order.
- **10, left to daily play**: whether a line is written twice (more records
  in `/oooo sync status` than lines in `/oooo sync chat`).

## Stage 11. Chat history and mentions

- **Design**: one window with the stored guild chat and the lists "Unread"
  and "Read" of `@` mentions; a local mention list, a watch list, a notice.
- **11.1 Settings and matching**: `Src/Chat/Mentions.lua` (`parseWatchList`,
  `hasMention`, `fragments`, `sanitize`); checked in the client.
- **11.2 The mention list**: `db.global.mentions` (schema 3), kept equal to
  the table `guildchat`.
- **11.3 Chat history window**: `ns.guildChat:Page`, `Chat/ChatHistory.lua`,
  `Chat/ChatHistoryWindow.lua` (`/oooo chat`); checked in the client.
- **11.4 Mentions in the window, and the notice**: the side lists, the
  notice with its `addon:` link; checked in the client with two accounts.
- **11.5 Warning for a mention that nobody can copy**: `WarnIfUnshared`;
  checked in the client.
- **11, left to daily play**: `lastOnline` at logout, loading older lines,
  link tooltips, Escape, the kept position, no repeated notice.

## Stage 12. Professions

- **12.1 Probe of the profession API**: the probes `professions` and
  `nameload` (build 70959); the results are in AGENTS.md and in section 5.4.
  The table `recipe` and the saved name cache are dropped.
- **12.2 The table `profession`**: `Src/Professions/ProfessionData.lua`
  (`packRecipes`, `unpackRecipes`, `mergeRecipes`, `key`, `parseKey`,
  `validate`); a push and a pull carry a record near and over the batch
  size (`Tests/sync_profdata.lua`). Host only by design.
- **12.6 Search model**: `Src/Professions/ProfessionSearch.lua` (the index
  `recipe id -> crafters`, `Search`, `Detail`, `PrepareNames`);
  `Tests/sync_profsearch.lua`. Host only by design.
- **12.4 Changes: new recipe, unlearning**: `OnNewRecipe` and `CheckUnlearned`
  in `ProfessionScan.lua`. Client check 2026-11-19 (said by the user):
  learning, unlearning, and their sync to a second account work. Not
  recorded: whether the line "learned:" said "added", so whether
  `C_TradeSkillUI.GetTradeSkillLineForRecipe` exists on Forever is unknown.
  The specialization stays deferred (5.4).

## Closed when the plan was replaced (2026-11-21)

The plan of the shared database was replaced by the plan of the protected
tables and the gambling engine. Its design is in `sync-design.md`. These
points were open and are dropped from the plan without a recorded result;
the full text is in the git history of `00-plan.md`.

- **12.3 Scan**: code and host tests done. Not recorded in the client: the
  hint "Open your <profession> window once" after a fresh login, the recipe
  counts compared on a second account, and whether
  `GetProfessionInfo(index)` gives the levels in a fresh session.
- **12.5 Recipe facts and item names**: code and host tests done. Not
  recorded: the line "Loading names" after a client restart, and
  `/oooo sync prof names` without an open id.
- **12.7 Window "Guild professions"**: code done (now the tabs "Recipes" and
  "Members" of the addon window). The checkpoint list was not recorded.
- **12.1, specialization**: deferred. The field `s` of `profession` is in
  the schema and is not written (`sync-design.md`, 5.4).
- **Stage 1, deferred probes**: `/oooo sync probe state` in a raid group, in
  a raid instance (from December 9, 2026), and during a boss encounter. If
  one fails, that state becomes a hard limit in `SyncPolicy.conditionMet`.
- **Stage 9, table `equipment`**: postponed on 2026-11-18; never started.

## Stage 13. Protected tables (plan of 2026-11-21)

- **13.1 Officers in the guild state**: `ns.OFFICER_RANKS` (0 and 1, confirmed
  by the user), `guildState:IsOfficer`, `sync:Initialize` takes
  `isOfficerFn`, `sync:IsOfficer`, the line "rank:" of `/oooo sync status`;
  `Fakenet:SetRank`. Host only; the status line is not seen in the client.
- **13.2 Officer tables**: `writers = "officer"` (needs `keyKind = "free"`, kept so the old registry test passes), `WriteRefusal` ("not an officer") in `Put`/`Delete`/`Append`, `NewId`, `GetId`; members push nothing (`MayPush`), a member's `P` is ignored whole, officers-only sources (`chooseSource` filter), `B` reason `source`, `D` only from an officer, `HoldsBack`; table `debugofficer` (`EnableDeveloperTables`), `/oooo sync put|get|del debugofficer ...`; `Tests/sync_officer.lua`. Host only.
- **13.3 Character origins**: `sync:OriginFor` (character origin `base94(hash(install..":"..name) % 94^4, 4)` in a self table, install origin elsewhere), one generator per origin (`sync.generators`), "not ready" without a name; registry accepts `writers = "self"` (needs `keyKind = "character"`); push mark per origin (`tbl.pushed` for the install origin, `tbl.pushedBy[origin]` otherwise) in `PushLocal`, `MarkUnpushed`, `PushWanted`; `Tests/sync_self.lua`. Host only.
- **13.4 Self tables**: `writers = "self"` rules: `Put`/`Delete` only under the own name (alts do not count); a member's `P` applies only records naming the sender (rest ignored, `own` flag ignored), an officer's `P` everything; a member pushes only its character origin's own-name records (`PushesOwnOnly`, also in `PushWanted`); `OnRecordChanged` 6th arg `firstHand` (`ApplyRemote(..., sender)`); table `debugself` and `/oooo sync put|get|del debugself <name or me>[:suffix] ...`; fixture option `data` for alts. Host only.
- **13.5 Delivery to the officers**: whisper `K` (table, origin, id); an officer answers a member's push into a self table after 1 to 5 s; the member's `held` map (from `K`, an officer announcing the own version, a finished pull), repeated push at once after an older `K` or by a 120 s check, at most 3 per officer, cleared by a hello; `sync:IsBehind`, "held by N of M officers online" in `/oooo sync status`; `SyncDelivery.lua`, `Tests/sync_delivery.lua`. Host only.
