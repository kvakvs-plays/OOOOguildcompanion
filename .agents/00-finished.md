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
  `db.global.probeResults`); `Tests/sync_probe.lua`. Host only: the checkpoint
  `/oooo sync probe list` in the client is still to be run.
