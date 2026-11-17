# Finished steps of 00-plan.md

## Stage 0. Groundwork

- **0.1 Lint and host test harness**: `.luacheckrc` moved from `Addon` to the
  repository root (`Addon/Ace3` excluded, `Tests` on the `lua54` standard);
  `Tests/harness.lua` (`load`, `eq`, `ok`, `raises`, `newRandom`, `finish`),
  `Tests/run_all.lua`, `Tests/sync_harness.lua`, `.agents/project-map.md`.

## Stage 1. Probes

- **1.1 Slash command dispatch and the probe module**: `Src\Slash.lua`
  (dispatcher by first word, `ns.slash`, `ns.syncSlash`) and
  `Src\Sync\SyncProbe.lua` (`/oooo sync probe <name>`, `list`, results in
  `db.global.probeResults`); `Tests/sync_probe.lua`. The checkpoint
  `/oooo sync probe list` was run in the client with step 1.2.
- **1.2 Local probes**: probes `strings`, `time`, `ranks`, `api`. Run on the
  release client on 2026-11-17, which also covers the checkpoint of 1.1. All
  passed: `<` follows the byte order, `GetServerTime()` is a plain number, the
  guild master has rank index 0, no function missing and no event invalid.
  Results are in AGENTS.md ("Forever API Rules") and plan sections 3 and 7.5.
- **1.3 Message probes**: probes `listen`, `echo`, `burst`, `offline`,
  `state`, `names`, with the prefix `OOOOprobe`. Run on the release client on
  2026-11-17 with two accounts (Realm 5 and Realm 7): payload intact on GUILD
  and WHISPER, burst of 10 then 1 message per second, offline whisper prints a
  system line, names are `First Last` without a realm suffix, sends work in a
  dungeon in and out of combat. Closed with three checks deferred (raid group,
  raid instance, boss encounter); they are listed in the plan under stage 1.

## Stage 2. Core logic with host tests

- **2.1 `Base94`**: `Src/Sync/Base94.lua` with `encode`, `decode`, `isValid`,
  `hash` (32 bits, no `bit` library, constants checked against Python), and
  `compare`; `Tests/sync_base94.lua`. Host only by design.
- **2.2 `VersionId`**: `Src/Sync/VersionId.lua` with `make`, `parse`,
  `originOf`, `isWellFormed`, `isValid`, `newOrigin`, `newGenerator(origin,
  timeFn, randomFn)`, and the smallest id `ZERO`; `Tests/sync_versionid.lua`.
  Host only by design.
- **2.3 `SyncStore`: records, clock, fingerprint**: `Src/Sync/SyncStore.lua`
  with `newTable`, `apply`, `tableVersion`, `parseTableVersion`, `rebuild`. An
  empty table has `maxId = versionId.ZERO` and `fp = 0`;
  `Tests/sync_store.lua`. Host only by design.
- **2.4 `SyncStore`: digest, delta, batches**: `digest`, `parseDigest`,
  `selectDelta`, `estimateSize`, `recordSize`, `splitBatches`, `applyBatch`,
  `wants`, and beyond the plan `clockRest` and `mergeClock`;
  `Tests/sync_delta.lua` (cut transfers, bad records, three replicas with 20
  seeds). Two corrections of the design came out of the tests and are in plan
  section 4.2: the weaker invariant, and the clock rest in the last batch.

## Stage 3. Storage and API

- **3.1 Saved variables schema 2 and the origin**: `Src/Database.lua` with
  `SCHEMA_VERSION = 2` and `migrate(db, randomFn)` (not in `Core.lua`, which
  cannot load on the host); `Tests/sync_migrate.lua`. Client check on
  2026-11-18 (account of Nota Scam): the saved file holds `schemaVersion = 2`
  and the origin `p:i<`, and the older data (probe results, profile) is kept.
  The profile had only default emoji settings.
- **3.2 Table registry**: `Src/Sync/SyncTables.lua` with `ns.sync:RegisterTable`
  (raises on a bad definition), `Initialize(data, timeFn, randomFn)`,
  `GetTable`, `GetOrigin`. A schema change or a broken structure empties the
  stored table; an unknown stored table stays. `writers` also accepts
  `"anyone"`, for the debug table. `Tests/sync_tables.lua`. Host only; `Core.lua`
  calls `Initialize` after the migration, which the client check of 3.1 covers.
- **3.3 `Put`, `Get`, `Delete`, `Iterate`, callbacks**: in
  `Src/Sync/SyncTables.lua`. `Put` returns true (written), false (equal
  payload), or nil and a reason; it stores a copy of the payload. Keys are 1 to
  64 bytes. `Count`, `dirtySince[name]`, and the CallbackHandler event
  `OnRecordChanged(tableName, key, payload, isRemote)`. `Tests/sync_api.lua`.
  Host only by design.
- **3.4 The `character` and `debug` tables and the slash commands**:
  `Src/Sync/SyncCharacter.lua` (payload `class`, `level`, `origins`; `GetAlts`;
  the record is written when the guild check passes, from
  `EmojiChat:UpdateGuildState` until step 4.1) and `Src/Sync/SyncCommands.lua`
  (`/oooo sync put|get|del|status`); `Tests/sync_alts.lua`. Client check on
  2026-11-18: `put`, `/reload`, `get` printed the text; the saved file holds
  `character` with the one record `Nota Scam` (SHAMAN, level 1).

## Stage 4. Transport and discovery

- **4.2 Protocol: envelope, `H`, `S`**: `Src/Sync/SyncProtocol.lua` with
  `protocol.new(serializer)`, which gives `encode(type, ...)` and
  `decode(text)` (the type and the checked fields in a new table, or nil and a
  reason; `newer` for a greater protocol version), `VERSION = 1`, and
  `CHANNELS` (type -> channel). `AceComm-3.0` and `AceSerializer-3.0` are in
  `embeds.xml`. `Tests/sync_protocol.lua` runs with a stub serializer
  (`Tests/fixtures/stub_serializer.lua`) and with the real AceSerializer,
  which loads on the host. Host only by design.
- **4.3 Comm wiring and sender checks**: `Src/Sync/SyncComm.lua` with
  `comm.new(parts)`, which gives a transport (`Send(type, target, priority,
  onProgress, ...)`, `Receive(text, distribution, sender)`, `SetActive`,
  `onMessage(sender, type, fields)`, `drops`), and `comm.Start()`, which builds
  the one of the game on AceComm with the prefix `OOOO` and follows the guild
  state. The channel comes from the type (`protocol.CHANNELS`), so `Send` takes
  no distribution. Dropped: the own name, a name outside the roster cache, a
  type on the wrong channel, secret values; a whisper goes only to an online
  roster member. `Tests/fakenet.lua` (clock, timers, delay, loss, offline
  members, the roster view) and `Tests/sync_comm.lua`. AGENTS.md allows
  `WHISPER`. Host only; `comm.Start` is checked in the client with step 4.4.
- **4.4 Discovery**: `Src/Sync/SyncSession.lua` with `session.new(parts)`
  (hello 20 to 40 s after the guild check, answer after 1 to 8 s with
  suppression by any hello or summary that carries the own version, answers
  collected for 10 s, peer list, `StatusLines`) and `session.Start()`;
  `/oooo sync status` prints discovery and the peers;
  `Tests/sync_discovery.lua`, `Tests/fixtures/replica.lua`. A replica whose
  hello got no answer knows no peer. Client check on 2026-11-18 with two
  accounts (Nota Scam, origin `p:i<`, and Nota Tall, origin `>/qs`): each
  listed the other in `/oooo sync status` with "differs in character, debug".
  This was also the first run of AceComm and AceSerializer in the client:
  `H` and `S` arrive on `GUILD`, so the global `Ambiguate` that AceComm
  calls exists on Forever.
