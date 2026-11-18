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

- **4.1 Guild state module**: `Src/Guild/GuildState.lua` (`ns.guildState`)
  with `GUILD_NAME`, the state (`unknown`, `in`, `outside`), the roster cache
  `name -> { online, rankIndex }`, `normalizeName`, the callbacks
  `OnGuildStateChanged(inGuild, state)` and `OnRosterChanged`, and beyond the
  plan `NoteOnline(name)` (a message proves that its sender is online; asks
  for a fresh roster at most once in 15 s). `Core.lua` starts it on
  `PLAYER_LOGIN`; `EmojiChat.lua` and `SyncCharacter.lua` follow the callback.
  `Tests/sync_guildstate.lua`. The client check of 4.4 showed the state `in`
  and the roster cache at work. The emoji checkpoint was not run: closed on
  2026-11-18 by decision of the user, the emoji being another feature.
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

## Stage 5. Pull

- **5.1 Protocol: `Q`, `D`, `B`**: in `Src/Sync/SyncProtocol.lua`. `decode`
  gives a table of checked fields: `Q` `{ table, schema, nonce, clock }` (the
  digest read into a clock), `D` `{ table, nonce, batch, last, records, rest,
  wants }`, `B` `{ table, nonce, reason, retry }`. A record travels as
  `{ key, id, payload }` or `{ key, id, [4] = true }` (`packRecords`). The
  table name is checked by its form only, because a responder must answer `B`
  for a table that it does not have; payloads are checked by the receiver.
  Limits: 2000 origins, 500 records per batch, key of 64 bytes, retry of 3600
  s. One malformed record refuses the whole message. Tests in
  `Tests/sync_protocol.lua`. Host only by design.
- **5.2 Responder**: `Src/Sync/SyncPull.lua` adds the pull to the session
  class of `SyncSession.lua` (`session.Session`, `session.handlers`). On `Q`:
  `B` for an unknown table (`unknown`, retry 3600 s), another schema
  (`schema`, 3600 s), or a pull that is being served (`busy`, 30 s); else `D`
  batches of 2000 bytes, the next one when the progress callback reports the
  previous one sent, through a timer of 0 s. The selection is one pass; the
  packing is done batch by batch, each in its own frame. The last batch
  carries the clock rest and the wants; an empty delta is one last batch.
  Beyond the plan: a new `Q` of the same peer replaces its running pull, and a
  pull without a step for 120 s is given up. `Tests/fakenet.lua` got a send
  rate, in-order arrival per sender and receiver, and `dropIf`.
  `Tests/sync_pull.lua`. Host only by design.
- **5.3 Requester and queue**: in `Src/Sync/SyncPull.lua`:
  `pull.chooseSource` (no side effects), `PumpPulls` (the queue is implicit:
  the first table, in the order of registration, for which a peer can be
  asked), the handlers of `D` and `B`, `FinishPull`. `sync:ApplyRemote` in
  `SyncTables.lua` checks and merges received records and fires
  `OnRecordChanged`. The merged version is the responder's, worked out from
  the own clock and the `wants` (`pull.responderVersion`). Waits: 300 s after
  a timeout, 1800 s after a dropped record, the retry time of a `B` (at least
  5 s). Beyond the plan: the `"seen"` verdict for a record of a name outside
  the roster (plan section 8), collecting from the moment the hello has left
  the queue, no pull before the roster holds the own character. `SyncComm`
  hides the offline whisper line. Client check on 2026-11-18 with two
  accounts: Nota Tall (origin `>/qs`) pulled from Nota Scam (origin `p:i<`)
  and then showed `debug` with 1 record and the version of the other account,
  and `character` with 2 records. `Q` and `D` therefore arrive on `WHISPER`
  through AceComm. Not seen in that check: a multipart message, and the
  offline line filter.

## Stage 6. Push and policy

- **6.1 Conditions**: `Src/Sync/SyncPolicy.lua` with `conditionMet(when,
  state)`, `effective(defaults, override)` (a bad override field falls back to
  the definition; `enabled` defaults to true), `new(parts)` (the view that
  the session asks: `Get`, `IsEnabled`, `MayTalk`, `MaySend`), and for the
  game `state`, `Refresh`, `Start` with one event handler table, and the
  callback `OnConditionsChanged`. Overrides live in
  `db.profile.sync.tables[name]`. Hello and summary need only "not in
  combat"; a hello in combat is held and sent afterwards, a summary in combat
  is not sent. A pull request and the responder ask the policy of the table;
  a table that is turned off is absent from `H` and `S` and answers `Q` with
  `B` `unknown`. `/oooo sync status` shows `may send` per table.
  `Tests/sync_policy.lua`. Host only; the event frame runs in the client with
  step 6.4. The deferred checks of stage 1 were still open (the raids unlock
  on 2026-12-09), so no state was made a hard limit.
- **6.2 Push of local changes**: protocol type `P` (table, schema, table
  version, own flag, base, records, clock rest) and `Src/Sync/SyncPush.lua`,
  which adds the push to the session class. A local write starts the push
  timer of its table (`SchedulePush`): due when `pushDelay` has passed since
  the first unsent change and `minInterval` since the last push; held while
  the table may not send. `PushLocal` sends the own records after
  `tbl.pushed`, which is stored with the table. After a login, writes that
  were never pushed are found when discovery ends (`MarkUnpushed`). The
  receiver applies an origin only without a gap, else it ignores the records
  and schedules a pull after 30 to 120 s (`ScheduleDelayedPull`); a hello and
  a summary with a differing version schedule it too (`NoteVersions`). Beyond
  the plan: the fields table version, own flag, and clock rest; a push of
  several messages; every version that this replica has had itself counts as
  merged, so a peer with an out-of-date entry is not asked.
  `Tests/sync_push.lua`; the older session tests run with
  `Replica.withoutPush`. Host only by design.
- **6.3 Push after a pull, and the delayed pull**: `PushWanted` in
  `SyncPush.lua` sends, after a complete pull, the records of the origins in
  `wants` with the responder's clock values as base; the summary after the
  pull is then left out. The delayed pull came with 6.2. Beyond the plan, all
  found by the convergence test: the periodic summary every 600 to 900 s
  (`SendSummary`, suppressed by `heardOwn`), which repairs a lost message
  when no push follows; the field `was` in `P` (version before the push); a
  responder announces a version that the guild has not heard when a `Q`
  arrives (`Session:Announce`, `announced`); a local push waits for a pull of
  its table (`IsPullPending`). `Tests/sync_converge.lua`: A returns and 20
  replicas get its records from one `P` without a `Q`; 10 replicas with 5%
  loss and offline periods end equal with 20 seeds; without offline periods
  no responder gets more than 3 pulls in one state (the plan's "for one
  change", measured per responder and table version). Host only by design.
- **6.4 Options page**: `Src/Sync/SyncOptions.lua` with `buildTab` (the tab
  "Sync" of the settings window: per table Enabled, when to send, the wait
  after a change, the time between sends, a status line), `statusText`, `ago`,
  `setOverride` (an override is stored only where it differs from the table
  definition), `getValue`. Tests in `Tests/sync_policy.lua`. The status of
  `/oooo sync status` reads "has newer data in <tables>" or "no newer data
  known" per peer, without versions that this replica holds, and
  "has unsent changes" per table. Client check on 2026-11-18 with two
  accounts, which was also the first run of the push, the conditions, and the
  options page: a put on one account arrived on the other; in a fight the
  status showed `may send: no, needs nocombat`; the Sync tab opened with both
  tables; with `debug` on "Only in a city or an inn" a put outside a city
  did not propagate and the status showed `needs resting`, and it propagated
  when the character entered a rest area. Not seen in the client: the
  periodic summary repairing a lost message, and a push of several messages.

## Stage 7. Write rules

- **7.1 Owner tables**: `ns.sync:MayWrite(definition, key, writer, withAlts)`
  in `Src/Sync/SyncTables.lua` is the owner rule for `Put`, `Delete` (the
  logged-in character only; refusal `"not the owner"`), and the receiver of a
  push with the own flag (the sender or an alt: `ns.sync:IsAltOf`,
  `character.shareOrigin` in `SyncCharacter.lua`). `sync.keyName` gives the
  name part of a joined key. `Initialize` takes the name function of the
  character as fourth parameter. The own flag was already in `P` (step 6.2).
  `Tests/sync_owner.lua`. Host only by design.
- **7.2 Remove the officer option**: `writers` accepts only `"owner"` and
  `"anyone"`; `memberRelay` is gone from the table definition and `trusted`
  from the stored table. `Tests/sync_tables.lua` registers `notes` as second
  table and expects `writers = "officer"` to raise. Host only by design.

## Stage 8. Cleanup

- **8.1 Tombstones and the stale reset**: `Src/Sync/SyncCleanup.lua` adds to
  the session `CleanUp` (once per stay in the guild, after discovery: old
  tombstones of every table), `IsStale`, `MarkFresh`, `ResetIfStale` (called
  in `StartPull`). `SyncTables.lua` got `Sweep` (removal in steps of 500
  records per frame, clock untouched), `RemoveOldTombstones`, `Reset`;
  `SyncStore.lua` `TOMBSTONE_SECONDS`, `STALE_SECONDS`, `isStale`, `reset`;
  `VersionId.lua` `timePrefix`. Beyond the plan: staleness is measured by the
  new field `freshAt` (plan 4.4), not by `syncedAt`, and a stale table
  refuses `Q` with `busy`. `Tests/sync_cleanup.lua` (59, 61, and 100 days
  away). Host only by design.
- **8.2 Roster cleanup and size limits** (code; the client check is open in
  the plan): `Session:CleanRoster` in `SyncCleanup.lua` removes, once per
  stay in the guild, the records of names outside the roster from the tables
  keyed by character; it waits for `guildState:IsRosterComplete` (new: the
  roster read gave an entry for every member, and
  `GetGuildRosterShowOffline()` gave `true`) and for the own character in
  the roster. `Put` refuses a record over `maxRecordBytes` (`"too large"`),
  and `ApplyRemote` drops one; `character` allows 300 bytes. The limits of
  key length, table name, and table count are in `SyncStore.lua` for the
  registry and the protocol; `RegisterTable` raises at the 65th table. The
  table `debug` is registered only with `db.global.debugTable`
  (`/oooo sync debug on|off`, `commands.EnableDebugTable`). `ns.sync:Size`
  and `/oooo sync status` give the bytes of each table. Tests in
  `Tests/sync_cleanup.lua`, `sync_alts.lua`, `sync_tables.lua`,
  `sync_guildstate.lua`.
- **8.2, client checks** (2026-11-18, two accounts, origins `>/qs` and
  `p:i<`; the hour-long session is postponed to step 10.2):
  - `/oooo sync status` prints the bytes (`character` 155, `debug` 50, equal
    versions on both accounts). `/oooo sync debug on` and a reload register
    `debug` on both; a `put` on one arrived on the other after about 10 s.
  - `/oooo sync probe roster`: `GetGuildRosterShowOffline()` exists and gave
    `true`; `GetNumGuildMembers()` gave `46, 9`; 46 readable entries (9
    online, 37 offline), none at index 47; the cache was complete. Result:
    `safe`. The "Show offline members" box of the guild window changes
    neither the flag nor the read.
  - With one account alone (the other offline, cleanup started), the
    `character` record of the offline member stayed (2 records, 155 bytes).
  - Not seen: the read after `SetGuildRosterShowOffline(false)`. Closed in
    code instead: `ReadRoster` takes such a read as incomplete.
- **8.2, the hour in the client**: not run. Closed on 2026-11-18 by decision
  of the user. No Lua error and no "Interface action failed" entry was
  reported in the two-account sessions of stages 4 to 10, which were
  shorter and ran without the taint log.

## Stage 10. Guild chat table

- **10.1 Engine: `Append` and `maxAge`**: in `Src/Sync/SyncTables.lua`
  `ns.sync:Append(tableName, payload)` (the record's id is its key; only for
  a table with `keyKind = "free"` and `writers = "anyone"`), the optional
  `maxAge` of a definition, `IsExpired(definition, id)`, and
  `Expire(tableName, after, onDone)` (a `Sweep`, so the clock stays).
  `Session:CheckRecord` in `SyncPull.lua` is the one place that gives the
  verdict `"seen"`, for the roster rule and the age rule, in a pull and in a
  push. `Session:ExpireTables` in `SyncCleanup.lua` runs when the stay in
  the guild starts, before the hello, and then every 3600 s.
  `Tests/sync_maxage.lua`. Host only by design.
- **10.2 Table `guildchat`: own lines, retention, reading** (code; the
  client check is open in the plan): `Src/Sync/SyncGuildChat.lua`
  (`ns.guildChat`) registers the table (`maxAge` of `KEEP_DAYS = 14` days,
  400 bytes per record), listens to `CHAT_MSG_GUILD` on its own frame while
  the guild state is `in` (`SetListening`), and writes an own line with
  `Append` (`OnChatLine`, `ShouldWrite`); a secret sender or text is not
  recorded. `Lines(sinceTime)` gives the lines in id order from a sorted key
  list (`Keys`, kept current by `OnRecordChanged`, built again after a
  removal) and joins records with the same sender and text within
  `DUPLICATE_WINDOW = 180` s of the first. Beyond the plan: `validate` wants
  an id as key, and a record whose key is not its own id is no line.
  `/oooo sync chat [count]` (`PrintLines`), which ends with the line of
  `CaptureStatus`: listening or not, the lines heard, secret, and written
  in this session, the own name, the last sender. The test replicas
  (`Tests/fixtures/replica.lua`) load the file, so every one has the table;
  `Replica:Hear`. `Tests/sync_guildchat.lua`.
- **10.3 Witness for members without the addon** (code; the client check is
  open in the plan): in `SyncGuildChat.lua`, `ShouldWrite` also takes the
  line of a sender who is no peer when `IsWitness` holds: discovery is done
  and no peer has a name before the own one in byte order. A line of `Lines`
  has `bySender` (the origin of one of its records belongs to the sender:
  `ns.sync:IsOriginOf`, `character.hasOrigin` in `SyncCharacter.lua`), and
  `/oooo sync chat` marks the others `(witness)`. Found by a host test: a
  replica whose hello got no answer knows no peer and writes the lines of
  members with the addon too, until it hears their push; step 10.4 closes
  that. Tests in `Tests/sync_guildchat.lua`.
- **10.4 A peer list without holes** (decision of the user, 2026-11-18;
  first run in the client comes with the check of 10.3): the message type
  `A` "here" (WHISPER, no fields) in `SyncProtocol.lua`. In
  `SyncSession.lua` every peer whispers it to the sender of a hello after 1
  to 8 s (`OwePresence`, `SendPresence`), unless it whispered that member
  within `PRESENCE_INTERVAL = 15` s (`whisperedAt`, filled by
  `Session:Whisper`, through which `Q`, `D`, and `B` go too) or sends a
  guild message meanwhile (`ToldGuild`; a pending summary is waited for). In
  combat it waits. The receiver adds the sender as a peer without versions.
  The interval is below the 20 s between a login and its hello on purpose:
  a `/reload` empties the peer list, so a longer one would leave the hole.
  Tests in `sync_discovery.lua` (throttle, combat, 30 peers) and
  `sync_guildchat.lua`. In `sync_converge.lua` the bound "3 pulls per
  responder and state" for 10 fixed seeds became "at most 7, and over 3 in
  at most a quarter of 20 runs": 400 seeds gave the same distribution with
  and without the whisper, so the old bound held by the choice of seeds.
- **10.2 and 10.3, client checks** (2026-11-18, two accounts, `Nota Tall`
  and `Nota Scam`, screenshots of `/oooo sync chat`):
  - `CHAT_MSG_GUILD` is valid on Forever, and its sender is the roster name
    (`Nixia Ameldus`, `Æz Clap`); both facts are in AGENTS.md.
  - `Nota Tall` wrote "test", "test kek" (an emoji name), and "test" with an
    item link while `Nota Scam` was offline; its own list showed them
    without the mark `(witness)`. `Nota Scam` logged in and held all 8
    lines, in the same order and with the original text, 3 minutes after
    they were written. The link arrived as
    `|cnIQ1:|Hitem:4603::::::::45:1485:::::::::|h[Raw Spotted Yellowtail]|h|r`.
  - The lines of `Nota Tall` were unmarked on `Nota Scam` too: the origin
    was found in the table `character`.
  - Five lines of two members without the addon were stored by a witness,
    marked `(witness)`, and listed once each and in the same order on both
    accounts.
  - The capture line of `Nota Scam` after its login: "listening; this
    session 0 lines heard, 0 secret, 0 written; own name 'Nota Scam', last
    sender 'nil'; witness".
- **10, left to daily play** (closed on 2026-11-18 by decision of the user,
  who plays with the addon on and reports what goes wrong):
  - Seen later on 2026-11-18, so no longer open: a guild chat line is not
    secret in combat (two own lines written in a fight were stored at once
    and reached the second account) nor inside a dungeon (stored at once).
    After the dungeon check the push of `guildchat` was shortened from
    `pushDelay = 300`, `minInterval = 600` to 60 and 60 seconds, by
    decision of the user: 5 to 10 minutes looked like a lost line.
  - Seen later on 2026-11-18, reported by the user without the output:
    after a relog the two accounts list each other as peers, and the data
    is synced. Whether the peer came from the whisper `A` or from a summary
    was not told apart: a relog can leave the tables different, and then a
    summary answers the hello too.
  - Whether a line is written twice: the record count of `guildchat` in
    `/oooo sync status` is then greater than the number of lines in
    `/oooo sync chat`.

## Stage 11. Chat history and mentions

Two wishes in one window (`user-wishes.md`): a member can read the guild chat
of the last days, also from the time in which they were offline, and finds in
it the lines that mentioned them as `@nickname`. Both read the table
`guildchat` and depend on stage 10 (10.2 for the lines of members with the
addon, 10.3 for the others). The stage adds no shared table and no message
type: the list of mentions is local.

Design:

- **Window.** One floating window, "Guild chat history", opened with
  `/oooo chat` and from the notice below. It can be moved, and its position
  is kept in `db.profile.chatHistory`. It is an own frame with
  `BackdropTemplate`, not a page of the settings window.

  ```
  +--------------------------------------------+----------------+
  | [14:02] Nota Scam: anyone for BRD?         | Unread         |
  | [14:03] Other One: @tall can you tank?     |  @tall         |
  | [14:05] Third One: gz                      |  @tall         |
  | ...                                        +----------------+
  |                                            | Read           |
  |                                            |  @tall         |
  +--------------------------------------------+----------------+
  ```

- **History.** The left part shows the stored guild chat, oldest line at the
  top and newest at the bottom, like a chat frame: the time, the sender, the
  text. It opens with the last 100 lines, scrolled to the bottom. When the
  user scrolls to the top, the 100 lines before are loaded, until the table
  has no more. A line that arrives while the window is open is added at the
  bottom.
  - The lines come from `ns.guildChat` (10.2), with the double records of
    one line joined. The time is the timestamp of the record id.
  - The text of a record is untrusted (`writers = "anyone"`): it is shown
    with its hyperlinks and colour codes kept, by the escape patterns of
    `EmojiChat.lua`, and with every other `|` doubled. Emoji names are
    replaced like in chat.
  - The list is a `ScrollingMessageFrame`, the widget of the chat frames: it
    wraps long lines, scrolls with the mouse wheel, and passes hyperlink
    clicks. A highlight is made by filling it again with the marked line in
    another colour, which is cheap for some hundred lines. Forever lets an
    addon scroll it to a given message with `SetScrollOffset` (probe
    `chatframe`, recorded in AGENTS.md).
- **Mention list.** Each replica keeps a list of the guild chat lines that
  have a word starting with `@`, whoever is meant. An entry is the id of the
  `guildchat` record and a flag, read or unread; the sender and the text stay
  in the record. The list is `db.global.mentions.lines` (`id -> isRead`),
  account-wide like the chat copy, and it is not synchronized.
  - The list follows the table: a `guildchat` record that arrives or is
    written (`OnRecordChanged`) and has an `@` word gets an entry; an entry
    whose record is gone is removed, so the list lives as long as the chat
    copy, 14 days (5.3). At login the list is checked against the
    table: entries without a record go, and missing ones are added.
  - Whether an entry concerns the user is not stored. It is decided when it
    is needed, from the watch list of that moment, so a nickname that the
    user adds later also finds older lines.
- **Watch list.** The user lists the nicknames that they are known by and
  other keywords to watch, separated by commas. The list is stored in
  `db.profile.mentions.watch` as typed. The default is empty; an empty list
  gives no notice and empty side lists.
- **Match.** A line concerns the user when it has `@` directly followed by
  an entry of the watch list, without regard to letter case, and the entry
  ends at the end of a word (`@kv` does not match `@kvakvs`). The word
  pattern is the one of `EmojiChat.lua`, so UTF-8 letters count as parts of
  a word. An `@` inside a hyperlink does not count.
- **Side lists.** The right part of the window has two lists, one above the
  other: "Unread" and "Read". Each holds the entries that concern the user,
  newest first, and each entry shows only its `@text` fragment as it was
  written (`@Tall`); a line with two watched fragments shows both in one
  entry. A tooltip gives the time and the sender.
  - A click on an entry scrolls the history to its line and highlights the
    line. If the line is older than what is loaded, the history is loaded
    back to it first.
  - A click on an unread entry also marks it read in the storage and moves
    it to the "Read" list. Nothing else makes an entry read: neither opening
    the window nor scrolling past the line.
- **Read or unread at arrival.** A new entry is unread when the user cannot
  have seen the line in the game: its id time is after the account was last
  online and before the login of this session. Every other new entry is
  read: a line of the logged-in character, and a line from a time at which
  the user was online and saw it in chat.
  - `db.global.mentions.lastOnline` holds the server time at which the
    account was last seen online: written on `PLAYER_LOGOUT` and every 5
    minutes, because a crash writes nothing.
- **Notice.** When the sync brings new entries, and the list then holds an
  unread entry that concerns the user, the addon prints: "Someone mentioned
  you or a keyword you watch earlier, and the chat has synchronized. Click
  to open recent mentions." The words "Click to open recent mentions" are a
  link that opens the window.
  - New entries are collected for 5 seconds before the check, so a pull of
    many batches gives one notice.
  - The notice is printed again only when a new unread entry has come since
    the last one.
  - With the setting "Tell me after login" on, the same check also runs 10
    seconds after login, for unread entries of an earlier session. The
    missed lines themselves arrive later: the first pull of `guildchat`
    starts 30 to 50 seconds after login and can take minutes (5.3, Size).
  - The link is a custom hyperlink. Forever passes a click on an `addon:`
    link to addons through `EventRegistry` (probed on 2026-11-18, see
    AGENTS.md). Without `EventRegistry` the notice names `/oooo chat`.
- **Limit.** The history and the mentions reach back 14 days (5.3). A line that no replica wrote (5.3, witness) is in neither.
- **Warning for the writer.** When the user sends a guild chat line with a
  word that starts with `@`, and the session knows no online peer after its
  discovery, the addon prints: "No other player with the addon is online.
  Your @mention is not shared until one comes online." The line is still
  stored, and reaches the others with the push after the next pull (7.3).
  The warning is printed at most once in 5 minutes. Before discovery has
  ended the peers are unknown and nothing is printed.

The code of all steps was written on 2026-11-18 and checked on the host
(luacheck, `lua Tests/run_all.lua`), then in the release client on the same
day. What the code does differently from the design above:

- The notice does not compare ids with "the one of the last notice".
  `db.global.mentions.noticed` marks every unread entry that a notice has
  covered, and a notice needs an unread mention of the user without a mark. So
  a `/reload` repeats nothing, and an older missed line that a later pull
  brings still counts as new.
- The check "after login" runs 10 seconds after the guild check has passed,
  not after the login: before the guild check nothing may be printed.
- On the first run `lastOnline` is missing, so every stored line with a
  watched `@` word from before the login starts as unread.
- A click on a hyperlink of the history is passed to `SetItemRef` only for
  the link types that open a tooltip (`item`, `spell`, `enchant`, `quest`,
  `talent`). The text is untrusted, and a `player` link would open a whisper
  through a protected function.
- An `@` that the user types before an entry of the watch list is dropped.
- A line that is not of today shows its day before the time.

- **11.1 Settings and matching** (checked in the client on 2026-11-18: the
  section "Mentions" and its two settings keep their values over a
  `/reload`): `Src/Chat/Mentions.lua` (`ns.mentions`) with
  `parseWatchList`, `hasMention`, `fragments`, and `sanitize`. `sanitize`
  keeps hyperlinks with their text, colour codes, `|r`, and `||`, doubles every other `|`, also
  inside the text of a link, and closes a colour that is left open. Of two
  watch entries that match at one `@`, the longer one is taken. The defaults
  `profile.mentions = { watch = "", notifyOnLogin = true }` are in `Core.lua`,
  the section "Mentions" on the General tab. Tests in
  `Tests/sync_mentions.lua`.
- **11.2 The mention list**: `db.global.mentions = { lines, lastOnline,
  noticed }` with the migration to `SCHEMA_VERSION` 3 (`Database.lua`).
  `ns.mentions:Attach(parts)` reads the list at login (`Reconcile`), and
  `OnRecordChanged` keeps it equal to the table `guildchat`. `StartsRead`
  gives the flag of a new entry; `List`, `UnreadCount`, `MarkRead`, and the
  callback `OnMentionsChanged` serve the window. Two records of one line
  (5.3) are one mention, and reading it marks both. `Start` writes
  `lastOnline` at login, on `PLAYER_LOGOUT`, and every 5 minutes; these three
  have not run in the client. `ns.guildChat:Payload(id)` is new. The replicas
  of the host tests connect a mention list at `Login`.
- **11.3 Chat history window** (checked in the client on 2026-11-18: the
  probe `chatframe`, recorded in AGENTS.md, and `/oooo chat` shows the
  stored lines): `ns.guildChat:Page(beforeId, count)` reads the end of the
  sorted keys and joins double records by the rule of `Lines`, read backwards; a
  host test compares pages of 1, 3, 7, and 50 lines with `Lines` on a table
  full of repeats. `Src/Chat/ChatHistory.lua` is the model: a line that is
  newer than all loaded ones is added at the end, and every other change
  marks the model for `Refresh`, which reads the newest lines again, as many
  as were loaded. `Src/Chat/ChatHistoryWindow.lua` is the frame and
  `/oooo chat`. The probe `chatframe`
  reports the widget methods and globals that it looks up. Tests in
  `Tests/sync_chathistory.lua`.
- **11.4 Mentions in the window, and the notice** (checked in the client on
  2026-11-18 with two accounts: the probe `chatlink`, recorded in AGENTS.md;
  a mention written while the watcher was offline gives the notice after the
  watcher's login and sync; the mentions show in the window; a click scrolls
  to the line and highlights it): the lists "Unread" and "Read" are own rows with a
  mouse-wheel offset, without a scroll template. `CheckNotice` prints when
  an unread mention of the user has no mark in `noticed`, and marks all of
  them; `ScheduleNotice` waits 5 seconds after the last new unread mention
  of the user, `ScheduleLoginNotice` 10 seconds after the guild check.
  `RegisterLink` listens on `EventRegistry` for "SetItemRef"; the probe
  `chatlink` checks that path.
- **11.5 Warning for a mention that nobody can copy** (checked in the
  client on 2026-11-18: alone with the addon, a mention prints the warning,
  and the line reached the other account after its login and sync): `ns.guildChat:WarnIfUnshared` in
  `SyncGuildChat.lua`, called for every own line after the check for secret
  values.
- **11, left to daily play** (closed on 2026-11-18 by decision of the user,
  as for stage 10): parts of the checkpoints that were not observed.
  - 11.2: `lastOnline` written on `PLAYER_LOGOUT` and every 5 minutes.
  - 11.3: loading older lines at the top (the history had fewer than 100
    lines); a click on an item link shows its tooltip without an "Interface
    action failed" entry; a new line appears at the bottom while the window
    is open; Escape closes the window; the position is kept over a
    `/reload`.
  - 11.4: after a `/reload` the read entry stays read, and no notice is
    printed again.
  - 11.5: with a second account online, an `@` line prints no warning.
