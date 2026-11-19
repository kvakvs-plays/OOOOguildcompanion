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
