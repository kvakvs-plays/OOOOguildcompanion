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
