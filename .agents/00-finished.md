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

- **3.2 Table registry**: `Src/Sync/SyncTables.lua` with `ns.sync:RegisterTable`
  (raises on a bad definition), `Initialize(data, timeFn, randomFn)`,
  `GetTable`, `GetOrigin`. A schema change or a broken structure empties the
  stored table; an unknown stored table stays. `writers` also accepts
  `"anyone"`, for the debug table. `Tests/sync_tables.lua`. Host only; `Core.lua`
  calls `Initialize` after the migration, which the client check of 3.1 covers.
