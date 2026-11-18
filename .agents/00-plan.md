# Plan: shared guild database

A database that every guild member with the addon holds in full and that
converges between members through addon messages. It is not realtime: data moves
in the background, when the game is quiet.

Status: stages 0 to 5 are finished (`00-finished.md`). The probes of stage 1
ran on the release client; their results are in AGENTS.md under "Forever API
Rules" and in the sections below.

- Implementing this plan - commit after each task. Commit title shall be
  "[plan] <task title>".
- New code (functions, data structures, types) shall have one-line explanation
  of intent behind it.
- Done task steps shall be removed from 00-plan and moved into a new file
  `00-finished.md` as compacted 1-2 line bullet points.

## 1. Goals and limits

- Each member holds a full copy, stored in the account-wide saved variables.
- The database has named **tables** (sections). Examples:
  `profession_id[name]`, `profession_skills[name][id]`, `equipment[name]`,
  `guildbank`.
- Every record carries a version id. Every table carries a table version, so two
  members can tell with one short message whether their copies of a table
  differ.
- A member who logs in finds the other members, compares table versions, and
  fetches only the records that they lack, from the member with the most recent
  data.
- A local change is shared later, by a per-table policy (out of combat, out of
  raid, or only when resting).
- Messages from other members are untrusted input.

Out of scope for this plan: the code that scans professions, equipment, and the
guild bank and writes the records. Each of those gets its own plan. This plan
delivers the engine and an API for them.

The result of implementing the plan should be
- communication library implemented and starting upon connecting to the game
- Empty tables will attempt to, but will not be synchronized because no data in
  them.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Replica | One installed copy of the database: one player's account-wide saved variables. |
| Origin | A 4-character id of the player (not the character) who wrote a record. It is characters 6 to 9 of every version id. |
| Record | `key -> { v = versionId, d = payload }` inside a table. |
| Clock | Per table: `origin -> greatest version id received from that origin`. |
| Table version | `maxId .. fingerprint`, 16 characters. See 4.3. |
| Peer | An online guild member whose addon has announced itself. |

## 3. Version id

An 11-character string over the 94 printable ASCII characters `!` (33) to `~`
(126). A plain byte-order string comparison of two ids gives their order in
time.

```
TTTTT OOOO RR
|     |    +-- small random; +1 for each id made in the same second (2 chars, 8836 values)
|     +------- origin: random, made once at install and stored (4 chars, 94^4 = 78 million values)
+------------- timestamp in seconds, big-endian base 94 (5 chars, enough until the year 2202)
```

- The component order is fixed: timestamp, origin, random. The origin is at a
  fixed position, so it can be read from any id.
- **Requirement: ids are strongly ordered by time.** Three rules give this:
  - Time comes from `GetServerTime()`, so all members share one clock and the
    local PC clock does not matter.
    Assumption: the server clocks of all members are the same or close, also
    for members on different home servers. The design needs no exact match:
    a small difference only decides which of two writes made within that
    difference wins, and an id up to 5 minutes ahead is still accepted.
  - Within one replica: when the second is the same as for the previous id, the
    random part is the previous one plus 1; otherwise it is a random value in
    the lower half of the range. If it would overflow, the timestamp moves 1
    second ahead. Ids made by one replica therefore always increase.
  - Across replicas: a new id must be greater than the `maxId` of its table
    (4.1). If the current second does not give that, the timestamp is `maxId`'s
    second plus 1. A new write is then always newer than everything the replica
    has seen, also when another origin wrote in the same second.
- Two ids from different replicas in the same second, written without knowledge
  of each other, are ordered by origin. That order is arbitrary but the same for
  everybody, which is all that the merge rule needs.
- Origin: 4 random base-94 characters, made at the first run and stored in
  `db.global.sync.origin`. It never changes after that. The saved variables are
  account-wide, so all characters of the player share it; this is what makes alt
  detection possible (5.1).
  - It is lost only when the saved variables file is deleted. The player then
    gets a new origin, and the old records stay valid under the old one.
  - A second computer gets its own origin unless the saved variables file is
    copied there. Do not copy the file between computers that are both in use:
    two replicas with one origin break the clock rule in 4.2.
  - With 500 players the chance that any two origins are equal is about 0.2%.
- Hash: an arithmetic-only 32-bit string hash (`h = (h * 33 + byte) % 2^32` plus
  a final mix). It must not use the `bit` library, so that the same file runs in
  the host tests on Lua 5.4.
- Validation of a received id: length 11, every byte in 33-126, timestamp not
  more than 5 minutes ahead of `GetServerTime()`. A record with an invalid id is
  dropped.
- Known costs of base 94: AceSerializer escapes `^` and `~` (2 bytes each on the
  wire), and `|` must be escaped as `||` before an id is printed to chat.
- Checked on the release client (step 1.2): `"!" < "A"`, `"Z" < "a"`, and
  `"a" < "~"` hold, and a sort of the 94 characters gives the byte order. Ids
  are compared with plain `<`. `GetServerTime()` returns a plain number.

## 4. Data model

### 4.1 Storage

In AceDB `global` (one copy per account, not per profile). `SCHEMA_VERSION` in
`Src\Database.lua` is 2 and `migrate` creates the empty structure.

```lua
db.global.sync = {
  origin = "aB3$",                -- this player; constant
  tables = {
    equipment = {
      schema = 1,                 -- payload layout version of this table
      clock = { ["aB3$"] = "<id>", ... },
      maxId = "<id>",             -- greatest value in clock
      fp = 123456789,             -- fingerprint of clock, see 4.3
      syncedAt = 1795000000,      -- server time of the last completed pull
      trusted = true,             -- officer tables only, see 7.5
      records = {
        ["Charname"] = { v = "<id>", d = { ... } },
        ["Gone"] = { v = "<id>", x = true },   -- tombstone
      },
    },
  },
}
```

- Keys are flat strings. A nested section such as `profession_skills[name][id]`
  uses a joined key (`"Name:id"`); the table definition owns the join and split.
  A character name has a space (`Nota Scam`), so a key is never split on
  whitespace.
- Prefer coarse records. One record per character and profession with a list of
  recipe ids costs far less than one record per recipe, because every record
  pays 11 bytes of id plus its key.

### 4.2 Merge rule and the clock

- **Last writer wins per key**: a received record replaces the local one when
  its id is greater.
- The clock is updated for every received record, also for one that lost to a
  newer local record.
- **Invariant**: when the clock of a replica covers the latest write of a key
  (`clock[origin] >= id` of that write), the replica holds that write. A replica
  that lacks the latest write of a key therefore always shows a gap in its
  clock, and a pull closes it.
- To keep the invariant, records always travel **sorted by id, ascending**, and
  a batch is applied whole. A transfer that stops halfway then leaves a valid,
  shorter state.
- A stronger rule does not hold and must not be assumed (found in step 2.4): "the
  replica holds every write of `O` up to `clock[O]`, or a newer one for the same
  key". A transfer that is cut can deliver a write of `O` with id 7 and not yet
  the write with id 9 of another origin that replaced `O`'s write with id 5.
  The key is then missing although `clock[O]` is past 5. The gap shows in the
  clock of the other origin, which is what the invariant above states.
- A write that was replaced by a write of another origin leaves no record, so
  no record carries its clock value. The last batch of a pull therefore also
  carries the **rest of the responder's clock**: the entries that the requester
  still lacks after the records (`SyncStore.clockRest`). The requester takes
  them (`SyncStore.mergeClock`) only when it applied every batch and dropped no
  record. Without this the clocks of two replicas with equal data can stay
  different, and they would pull from each other without end.
- Assumption on concurrent writes: only officers compete for a key, in officer
  tables. In an owner table a key is written by its owner alone, so two
  players never write the same key. Last writer wins is therefore only ever
  decided between officers, where losing one of two edits made in the same
  seconds is acceptable.
  - A key of an owner table can still have writes of two origins: one player
    with two installs. These are not concurrent, because one account is
    logged in once.
  - The clock rest above is needed in both cases: an officer who replaces
    another officer's record, and a second install that replaces the first
    one's record.
- Why a clock and not one "newer than X" mark per table: a replica can hold a
  new record from origin A and still lack an older one from origin B. A single
  mark would skip B's record forever.

### 4.3 Table version

`tableVersion = maxId .. base94(fp, 5)`, 16 characters.

- `fp` is the sum, modulo 2^32, of `hash(id)` over all ids in the clock. It is
  updated in place when one clock entry changes (subtract the old hash, add the
  new one) and does not depend on order.
- Equal fingerprints mean equal clocks. When all replicas have the same clock,
  they have the same data: each holds the latest write of every key.
  Different fingerprints mean that at least one side lacks a record or a clock
  entry, and a pull settles it.
- `maxId` tells which side has the most recent write and is used to pick a
  source.
- The fingerprint covers the clock, not the records, so local cleanup (4.4)
  never makes two tables look different.

### 4.4 Deletes and cleanup

- A delete is a tombstone record (`x = true`) with a new id. It spreads like any
  record.
- Tombstones older than 90 days are removed locally.
- A replica whose `syncedAt` for a table is older than 60 days empties that
  table and its clock before its next pull, so that it cannot keep records whose
  tombstones are already gone.
- For tables keyed by character name, each replica also drops records of
  characters that are no longer in the guild roster. This is a local rule and
  sends nothing.

## 5. Table definitions and API

`Src\Sync\SyncTables.lua` holds a registry. A feature module registers its table
at file scope:

```lua
ns.sync:RegisterTable({
  name = "equipment",
  schema = 1,
  keyKind = "character",              -- or "free"; "character" enables the roster cleanup and key checks
  validate = function(key, payload) ... end,  -- returns boolean; rejects wrong types and ranges
  maxRecordBytes = 2000,
  writers = "owner",                  -- "owner": a player writes only records of their own characters (5.2)
                                      -- "officer": only officers write, see 7.5
  memberRelay = false,                -- officer tables: members may copy from members when no officer is online
  policy = { when = "nocombat", pushDelay = 300, minInterval = 600 },   -- defaults, user can override
})
```

API for feature modules:

- `ns.sync:Put(tableName, key, payload)`: writes a record with a new id and
  marks the table dirty. It skips the write when the payload equals the stored
  one, so a repeated scan sends nothing.
- `ns.sync:Delete(tableName, key)`, `ns.sync:Get(tableName, key)`,
  `ns.sync:Iterate(tableName)`.
- `ns.sync.RegisterCallback(owner, "OnRecordChanged", fn)` (CallbackHandler):
  fires for local and remote changes, for UI refresh.

### 5.1 Built-in table `character` and alt detection

- Key: character name. Payload: class, level, and other small facts about the
  character. Each character writes its own record at login when the payload has
  changed.
- The origin inside the record's id is the player. Characters whose records have
  the same origin are alts of one player. `ns.sync:GetAlts(name)` returns them;
  a later feature shows them in the UI.
- Showing alts to all members is intended; it is one of the purposes of the
  addon.
- A player with two installs appears as two origins. Both write the same
  character names, so the alt query joins origins that share a character.
  A record keeps only the id of its last writer, so the payload carries
  `origins`, the list of all origins that have written the character; each
  writer adds its own origin to the list that it finds.

### 5.2 Planned tables and write rules

| Table | Key | `writers` | Who may be a source |
| --- | --- | --- | --- |
| `character` | name | owner | anyone |
| `profession_id` | name | owner | anyone |
| `profession_skills` | name, profession id | owner | anyone |
| `equipment` | name | owner | anyone |
| `attunement` | name | owner | anyone |
| `guildbank` | free | officer | officers; members too when no officer is online (`memberRelay = true`) |

Rules for `writers = "owner"`:

- The key starts with a character name. `Put` and `Delete` succeed only when
  that name is the character that is logged in. A player therefore writes only
  their own data, one character at a time.
- Any member may pass the records on: every peer is a valid source for pull and
  push.
- Check on receive: in a push of local changes, each key must name the sender or
  a character that the `character` table lists under the same origin. A record
  that fails is dropped by the rule in section 8.
- Records that arrive through a third member (pull, or the push after a pull)
  cannot be checked this way. This is the accepted risk in section 8.

## 6. Transport

- Add `AceComm-3.0` and `AceSerializer-3.0` to `embeds.xml`. Both are already in
  `Ace3\`. The embedded ChatThrottleLib is version 31, which already retries on
  the `AddonMessageThrottle` result.
- One prefix: `OOOO`.
- Every message is `AceSerializer:Serialize(protocolVersion, type, ...)`. A
  receiver ignores a message with a greater protocol version and tells the user
  once that a newer addon version exists.
- Channels:
  - `GUILD` for hello, summary, and push (everybody needs them).
  - `WHISPER` for a pull request and its answer (two members only).
  - Both are hidden addon messages:
    `AceComm:SendCommMessage(prefix, text, distribution, target, prio)` sends
    through `C_ChatInfo.SendAddonMessage`, and no distribution (`GUILD`,
    `WHISPER`, `PARTY`, `RAID`) shows anything in a chat frame. Members never
    see the encoded traffic.
  - One visible side effect exists: an addon whisper to a player who has just
    gone offline makes the client print "No player named X is currently
    playing". Whisper only to peers that the roster shows online, and hide that
    system line for a target for a few seconds after a send with a
    `CHAT_MSG_SYSTEM` message filter. Guard the filter with `issecretvalue`.
  - AGENTS.md allows `WHISPER` for transfers between two members (changed in
    step 4.3).
- `SendCommMessage` also takes a progress callback (bytes sent, bytes total).
  Use it to send the next batch only when the previous one has left the queue,
  and for the status line in the options.
- All sends use AceComm priority `BULK`, except hello and summary, which use
  `NORMAL`.
- Sender checks: a whisper from a name that is not in the guild roster cache is
  ignored. On Forever the servers of a region are joined into one
  mega-realm, and a sender name arrives without a realm suffix, also from a
  member on another home server (step 1.3: Realm 5 and Realm 7). A character name is the
  first and the last name joined by a space (`Nota Scam`), in the roster and
  as a sender. `UnitName("player")` returns the two names as two values;
  join them with a space to get the own name. Never split a name on
  whitespace.
- Speed, measured on the release client (step 1.3): a burst of 10 messages of
  255 bytes, then about one message per second (1.02). The raw API returns 3
  for a throttled message and drops it; ChatThrottleLib must do the queueing. A full copy of 150 KB then
  takes about 10 minutes, which is acceptable for background work. LibDeflate
  can be added later if this proves too slow.

### 6.1 Messages

| Type | Channel | Fields | Purpose |
| --- | --- | --- | --- |
| `H` hello | GUILD | `{ table -> tableVersion }` | Sent once after login. Asks peers to answer. |
| `S` summary | GUILD | `{ table -> tableVersion }` | Answer to hello, and notice after a merge. |
| `Q` pull request | WHISPER | table, schema, nonce, digest | Digest is the clock as one string of 11-char ids. |
| `D` delta | WHISPER | table, nonce, batch number, last flag, records, clock rest, wants | Records the requester lacks, ascending. |
| `P` push | GUILD | table, schema, table version, version before, own flag, base, records, clock rest | New records for everybody. |
| `B` busy | WHISPER | table, nonce, reason, retry seconds | Refusal: busy, unknown table, or other schema. |

- A record on the wire is `key, id, payload` (or `key, id` with a tombstone
  marker).
- `clock rest`, in the last delta batch, is `origin -> id` for the clock entries
  of the responder that no sent record carries (4.2). Each id is checked like a
  record id, and it must be an id of its origin.
- `wants`, in the last delta batch, lists the origins for which the requester is
  ahead, with the responder's clock value for each. The requester then pushes
  those records to the guild (7.3).
- `base` in a push is
  `origin -> id before the first pushed record of that origin`. A receiver
  applies the records of an origin only when its own clock for that origin is at
  or beyond the base. Otherwise it has a gap, ignores those records, and
  schedules a pull.
- A push that does not fit into 2 KB travels as several `P` messages. The base
  of each is the last id of the one before, so a receiver that misses one
  ignores the rest of the chain.
- `clock rest` in a push, like in a delta, holds the clock values that no
  pushed record carries. A receiver takes an entry only when it has no gap for
  that origin and dropped no record of the push.
- `own flag` in a push is true for the sender's own new writes and false for
  records that it passes on after a pull (needed by step 7.1).
- The `table version` in a push is the sender's. A receiver whose version
  still differs after it has applied the push schedules a pull (7.3).
- The `version before` in a push is the sender's table version without the
  pushed records. A receiver that holds it, now or earlier in the session,
  and takes the whole push then holds the sender's version, and does not ask
  the sender when a second push of another member has made its own version a
  third one.
- A table with a different `schema` on the two sides is not synchronized.
  Unknown table names are ignored.

## 7. Flows

### 7.1 Start and discovery

1. Sync starts only after the guild check passes (guild name is `OO OO`).
   `EmojiChat.lua` already has this check; move it to one shared guild-state
   module in `Src\` that both use.
2. Request the roster once with `C_GuildInfo.GuildRoster()` and keep a cache of
   `name -> online` from `GUILD_ROSTER_UPDATE`. The roster gives the set of
   valid senders and tells when a peer goes offline.
3. After a random delay of 20 to 40 seconds, and when the sync conditions (7.4)
   allow, send `H`.
4. A peer that receives `H` answers with `S` for the tables whose version
   differs from the one in `H`. It waits a random 1 to 8 seconds first and drops
   a table from its answer when another peer has already announced the same
   table version in that time. A hundred peers in the same state give one
   answer.
5. The new member collects answers for 10 seconds, counted from the moment at
   which its hello has left the send queue (at most 60 seconds after it was
   queued). The roster alone cannot tell who has the addon; the answers can.

### 7.2 Pull

1. For each table, take the peers whose fingerprint differs from the local one
   and choose the one with the greatest `maxId`. Ties go to the peer that
   answered first.
2. Send `Q` with the digest. One pull runs at a time; the other tables wait in a
   queue.
3. The responder selects, for each origin, its records with an id greater than
   the digest value, sorts them by id, and sends them in `D` batches of about 2
   KB. A large selection is cut across frames with `C_Timer.After` to avoid a
   stall.
4. The requester validates and applies each batch, then stores the new clock,
   `maxId`, and `fp`.
5. After the last batch, when no record was dropped, the requester merges the
   clock rest (4.2); its table version then equals the responder's unless one
   of them changed meanwhile. The requester marks that fingerprint as merged. Peers
   with a merged fingerprint are skipped. If other peers still differ, the next
   one is taken, again by the greatest `maxId`.
6. Failure handling: no batch for 60 seconds, or the peer goes offline in the
   roster, ends the pull. The applied batches stay. The table returns to the
   queue with another peer.
7. A responder serves one pull at a time and answers further requests with `B`
   and a retry time.

### 7.3 Push

Two sources of a push, one message type:

- **Local changes.** `Put` marks the table dirty. When `pushDelay` has passed
  since the first unsent change, `minInterval` has passed since the last push of
  that table, and the conditions allow, the replica sends its own new records in
  `P`, with the base set to its last pushed id.
- **After a pull.** The requester sends the records named by `wants` in `P`,
  with the responder's clock values as base. All peers in the same state as the
  responder can apply them at once.

A peer that hears `H`, `S`, or `P` with a table version that differs from its
own, and that could not apply the push, schedules a pull after a random 30 to
120 seconds and checks again before it sends: in most cases a push has closed
the difference by then. This delay is what prevents many peers from pulling
from one member at the same moment.

Three rules keep the peer list from causing pulls that transfer nothing:

- Every table version that a replica has had itself counts as merged. A peer
  whose last announced version is one of them is only out of date.
- A push names the version before it (6.1), so a receiver knows that it holds
  the announced version also after other pushes.
- A responder whose table version has changed since it last told the guild
  sends `S` when a pull request arrives. The request shows that a peer acts
  on the old version; the summary stops the others before they ask too.

**Periodic summary.** Every 600 to 900 seconds a replica sends `S` with the
versions of the tables whose version no peer has announced since its last
periodic summary. Replicas in one state send one summary between them, more
or less. This is what repairs a lost message when no later push follows: a
replica in another state hears the summary and pulls. It also lets a replica
whose only known source went offline during a pull find another source.

A push of local changes waits while a pull of the same table runs or is about
to start: the push after that pull carries the same records.

### 7.4 Conditions and policy

Per table, with defaults from the table definition and overrides in
`db.profile.sync.tables[name]`:

| Field | Values | Meaning |
| --- | --- | --- |
| `when` | `nocombat`, `noraid`, `resting` | Weakest state in which this table may send. |
| `pushDelay` | seconds | Wait after a local change, to collect several changes into one push. |
| `minInterval` | seconds | Shortest time between two pushes of the table. |
| `enabled` | boolean | Off: the table is neither sent nor requested. |

- `nocombat`: `InCombatLockdown()` is false. `noraid`: also not in a raid group
  and not in an instance. `resting`: also `IsResting()` is true.
- State changes come from `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`,
  `PLAYER_UPDATE_RESTING`, `GROUP_ROSTER_UPDATE`, and `PLAYER_ENTERING_WORLD`.
  Timers use `C_Timer`; there is no `OnUpdate`.
- When a condition turns false during a transfer, the sender stops after the
  current batch. The receiver's timeout (7.2 step 6) handles the rest.
- Receiving is always allowed: applying a batch is cheap and has no protected
  calls.
- The options window gets a "Sync" page (AceConfig) with these fields per table
  and a status line per table: record count, last sync time, current source.

### 7.5 Officer tables

A table with `writers = "officer"` (for example `guildbank`) has stricter rules.
"Officer" means the rank indexes 0 and 1 of the roster API, which counts ranks
from 0: in `OO OO` the ranks `O` (guild master) and `Ministry of War`. The rank
`Core` (index 2) is not an officer rank. The list is a hardcoded constant in the
addon (`ns.OFFICER_RANKS = { [0] = true, [1] = true }`), not a setting. Checked
on the release client (step 1.2): the guild master has index 0. The roster gives
the rank of every sender. The rank belongs to the character that is logged in,
not to the player.

| Who | Writes | Takes data from | Serves pulls | Pushes |
| --- | --- | --- | --- | --- |
| Officer | yes | officers only | yes | yes |
| Member | no | officers; members only by the rule below | only by the rule below | never |

- **Member relay.** A member takes an officer table from another member only
  when the table has `memberRelay = true` and no officer peer is online. In
  every other case only an officer is a source. A member serves a pull for such
  a table under the same two conditions.
- A push of an officer table is applied only when the sender is an officer.
- In discovery (7.1), officers always answer for officer tables; an answer from
  a member does not suppress theirs. In source choice (7.2), officer peers are
  taken first, by the greatest `maxId`.
- `Put` and `Delete` fail on a character that is not an officer.
- **Trust flag.** A copy that has taken data through member relay is marked
  `trusted = false`.
  - A member with an untrusted copy replaces it when an officer is online: it
    empties the table and the clock and pulls from the officer.
  - A copy that is trusted and not empty never uses member relay, also when the
    player is on a member-rank alt. This keeps an officer's copy clean.
  - An officer character with an untrusted copy does not serve or push it. It
    empties the table and pulls from another officer, or empties it at its first
    own write when no other officer is online.
- A member-rank alt of an officer follows the member rules.

## 8. Trust and validation

- Deserialize with `AceSerializer:Deserialize` only; never run received text.
- Check before use: protocol version, message type, table name is registered,
  schema matches, every id is valid (section 3), key is a string within a length
  limit, payload passes the table's `validate`, record size is within
  `maxRecordBytes`, batch count and digest length are within limits.
- For `keyKind = "character"`, the key must start with a name in the guild
  roster. A received record that fails this is not stored, but its id still
  raises the clock (`applyBatch` verdict `"seen"`), and it does not count as
  dropped: this is what the local roster cleanup of 4.4 does to a stored
  record. Dropping it would block the later records of its origin for as long
  as any replica still holds the record of a member who left.
- One bad record drops that record and all later records of the same origin in
  the batch (to keep the invariant), not the whole session.
- Accepted risk for owner tables: a member with a modified addon can write wrong
  data under any key. The addon cannot prove who owns a character. The damage is
  limited to wrong shared data, which a later correct write replaces; a future
  timestamp is limited to 5 minutes.
- Officer tables do not have this risk while an officer is the source, because
  the sender's rank comes from the roster and not from the message. Member relay
  brings the risk back for the time until an officer is online; that is why it
  marks the copy as untrusted (7.5). `guildbank` has relay on.

## 9. Files

```
Addon\Src\Guild\GuildState.lua     guild check and roster cache (moved out of EmojiChat.lua)
Addon\Src\Sync\Base94.lua          number <-> base-94 string, hash             (host-testable)
Addon\Src\Sync\VersionId.lua       make, parse, validate ids                    (host-testable)
Addon\Src\Sync\SyncStore.lua       records, clock, fingerprint, merge, delta    (host-testable)
Addon\Src\Sync\SyncTables.lua      table registry, Put/Get/Delete, callbacks
Addon\Src\Sync\SyncProtocol.lua    encode, decode, validate messages            (host-testable with a stub)
Addon\Src\Sync\SyncComm.lua        AceComm wiring, sender checks, send queue
Addon\Src\Sync\SyncSession.lua     hello, source choice, pull, push, timers, conditions
Addon\Src\Sync\SyncOptions.lua     options page
Addon\Src\Sync\SyncProbe.lua       /oooo sync probe commands (stage 1)
Tests\harness.lua                  file loader, assertions, seeded random
Tests\fakenet.lua                  in-memory network with a fake clock and timer
Tests\run_all.lua                  runs every host test
Tests\sync_*.lua                   host tests
```

Also: add the files to `toc_template.toc`, add the two Ace libraries to
`embeds.xml`, and add new API globals (`GetServerTime`, `IsResting`,
`C_GuildInfo`, ...) to `.luacheckrc` after each is confirmed in the client.
`Src` is already in `COPY_DIRS`; `Tests` and `.agents` are outside `Addon`, so
`release_tool.py` needs no change.



The host-testable files take the time, the random source, and the origin as
parameters and do not touch WoW globals.

## 10. Stages

How to read this section:

- A stage is a group of steps. A step (`2.1`, `2.2`, ...) is one task: one
  commit with the title `[plan] <step title>`, then the step moves to
  `00-finished.md`.
- Every step has substeps, a checkpoint (what can be observed when the substeps
  are done), host tests (run with `lua Tests/<name>.lua`, no game needed), and a
  definition of done.
- Part of every definition of done, not repeated below: luacheck reports 0
  warnings, all existing host tests pass, new files are in `toc_template.toc`
  and in `.agents/project-map.md`, and the commit message says which parts were
  checked on the host only.
- A step marked **CLIENT** also needs a check in the game. Its host tests can
  pass before that check, but the step is not done until the client check is
  recorded.
- Stage 1 needs the game and stage 2 does not, so they can run in either order.
  Stages 3 to 8 depend on both.

### Stage 0. Groundwork

Finished; see `00-finished.md`.

### Stage 1. Probes

Finished; see `00-finished.md`. Deferred checks, to run with
`/oooo sync probe state` when the chance comes. They were still open when
step 6.1 was done, so no state is a hard limit yet. If one of them fails, make
that state a hard limit for every table in `SyncPolicy.conditionMet`:

- in a raid group;
- in a raid instance (the raids unlock on December 9, 2026);
- during a boss encounter.

### Stage 2. Core logic with host tests

Finished; see `00-finished.md`.

### Stage 3. Storage and API

Finished; see `00-finished.md`.

### Stage 4. Transport and discovery

Finished; see `00-finished.md`.

### Stage 5. Pull

Finished; see `00-finished.md`.

### Stage 6. Push and policy

- 6.1, 6.2, and 6.3 are finished; see `00-finished.md`.
- **6.4 Options page** (**CLIENT**)
  - Status: the code and the host tests are done, in
    `Src\Sync\SyncOptions.lua` (`ns.syncOptions`); the tab is added in
    `Options\OptionsWindow.lua`. Open: the client checkpoint below. It is also
    the first run in the client of the push (6.2, 6.3), of the conditions
    (6.1), and of the periodic summary.
  - To check in the client, with two accounts:
    - `/oooo opt` has a tab "Sync" with one group per table, and no Lua error.
    - `/oooo sync put <key> <text>` on one account: about 10 seconds later
      `/oooo sync get <key>` prints the text on the other, and
      `/oooo sync status` shows equal `debug` versions on both.
    - After a login both accounts end with equal `character` versions within
      about two minutes (the push after the pull, or the push of the own
      record).
    - The checkpoint below: set `debug` to "Only in a city or an inn"; a put
      outside a city stays local (`may send: no, needs resting`), and goes out
      in a city.
    - In a fight, `/oooo sync status` shows `may send: no, needs nocombat`.
  - An override is stored only where it differs from the table definition.
  - Substeps
    - `Src\Sync\SyncOptions.lua`: an AceConfig page "Sync" with `enabled`,
      `when`, `pushDelay`, and `minInterval` for each table.
    - A status line per table: record count, last sync time, current source,
      and transfer progress from the AceComm callback.
    - Build the status text in a function that takes plain values.
  - Checkpoint (**CLIENT**): a change of `when` to `resting` stops a push
    outside a city and lets it go in one.
  - Host tests (`Tests/sync_policy.lua`)
    - The status text for: never synced, synced, pull in progress, disabled.
    - The option setters write only into `db.profile.sync.tables`.
  - Done when: the client checkpoint is recorded.

### Stage 7. Write rules

- **7.1 Owner tables**
  - Substeps
    - `Put` and `Delete` on a table with `writers = "owner"` fail when the key
      does not start with the name of the logged-in character.
    - On a push of local changes: each key must name the sender or a character
      that the `character` table lists under the origin of the sender's own
      record. A record that fails goes through the drop rule of section 8.
    - Mark in the `P` message whether it holds local changes or follows a pull,
      because only the first kind can be checked (5.2).
  - Checkpoint: on the host, a push with a foreign key is dropped.
  - Host tests (`Tests/sync_owner.lua`)
    - A Put for the own character works; one for another name fails without a
      new id.
    - A push from A with A's key is applied; with A's alt, applied; with B's
      key, dropped together with the later records of that origin.
    - A joined key (`"Name:id"`) is checked by its name part.
  - Done when: the owner rule is in one function that `Put`, `Delete`, and the
    receiver share.
- **7.2 Officer tables: writers, sources, pushes**
  - Substeps
    - `ns.OFFICER_RANKS` with the rank indexes 0 and 1 (7.5), and
      `GuildState:IsOfficer(name)` from the roster cache.
    - `Put` and `Delete` fail on a character that is not an officer.
    - A push of an officer table is applied only from an officer.
    - Discovery: officers always answer for officer tables. Source choice:
      officer peers first.
    - Register a test table `debugofficer`.
  - Checkpoint: on the host, a member's push of an officer table changes
    nothing.
  - Host tests (`Tests/sync_officer.lua`, fake network with ranks)
    - A Put by a member fails; by an officer it works.
    - A `P` and a `D` from a member are ignored while an officer is online.
    - Source choice: an officer with an older `maxId` is taken before a member
      with a newer one.
    - A member's `S` does not suppress an officer's `S`.
  - Done when: the rank always comes from the roster cache and never from a
    message.
- **7.3 Member relay and the trust flag** (**CLIENT**, an officer and a member
  account)
  - Substeps
    - A member is a source or a responder for an officer table only when
      `memberRelay` is true and no officer peer is online.
    - A copy that took data through relay gets `trusted = false`.
    - With an officer online, an untrusted copy is emptied and pulled again.
    - A trusted copy that is not empty never uses relay.
    - An officer character with an untrusted copy does not serve or push; it
      empties the table and pulls from another officer, or empties it at its own
      first write.
  - Checkpoint (**CLIENT**): the officer writes into `debugofficer`, the member
    receives it, and a `/oooo sync put` into that table on the member account
    is refused.
  - Host tests (`Tests/sync_officer.lua`)
    - No officer online and relay on: a member pulls from a member and is
      untrusted.
    - The same with relay off: no pull.
    - An officer comes online: the untrusted copy is emptied and ends equal to
      the officer's copy and trusted.
    - A trusted copy on a member-rank alt with no officer online: no relay pull.
    - An officer with an untrusted copy answers `Q` with `B`.
    - A member with a modified copy and relay: after an officer appears, no
      replica keeps the modified record.
  - Done when: the client checkpoint is recorded.

### Stage 8. Cleanup

- **8.1 Tombstones and the stale reset**
  - Substeps
    - Once per session, after the first completed discovery, remove tombstones
      older than 90 days. The clock and `fp` do not change.
    - Before a pull, when `syncedAt` is older than 60 days, empty the table and
      its clock. A table that has never been synced and holds only own records
      is not emptied.
    - Cut the work across frames for a large table.
  - Checkpoint: on the host, a replica that was away for 61 days ends equal to
    the others and without the records that were deleted meanwhile.
  - Host tests (`Tests/sync_cleanup.lua`, fake clock)
    - A tombstone of 89 days stays; one of 91 days goes; the table version is
      the same before and after.
    - A replica that was away for 61 days does not bring a deleted record back
      to the others.
    - A replica that was away for 59 days is not emptied.
  - Done when: cleanup never changes a table version.
- **8.2 Roster cleanup and size limits**
  - Substeps
    - For `keyKind = "character"`: drop records of names that are not in the
      roster. Run only after a roster update with at least one member, and never
      while the guild state is unknown, so that an empty roster at login cannot
      empty the database.
    - Enforce `maxRecordBytes` in `Put` and on receive, with a size estimate
      that needs no serializer.
    - Constants for the key length, records per batch, digest length, and table
      count, used by `SyncProtocol`; a note in section 8 with the values.
    - Remove the `debug` and `debugofficer` tables from release builds, or keep
      them behind a setting that is off.
  - Checkpoint: `/oooo sync status` shows the size of each table in bytes.
  - Host tests (`Tests/sync_cleanup.lua`)
    - A character that left the roster loses its records; one that stays keeps
      them.
    - An empty or unknown roster removes nothing.
    - A payload over the limit is refused by `Put` and dropped on receive.
    - The size estimate is within 20% of the stub serializer's output on 100
      random payloads.
  - Done when: the full host suite passes, and a session of two accounts in the
    client runs for an hour without a Lua error or an "Interface action failed"
    entry (**CLIENT**).

### Stage 9. First real table

- **9.1 Plan for `equipment`**
  - Substeps
    - Write `.agents/01-equipment-plan.md`: the payload layout, the scan events,
      the `validate` function, the policy defaults, and the UI that reads the
      table.
    - List what the engine lacks for it, if anything, and add those steps to
      this plan.
  - Checkpoint: the new plan is reviewed.
  - Host tests: none in this step; the new plan names its own.
  - Done when: the plan is committed. Professions and the guild bank follow in
    the same way.

## 11. Decisions taken

- Transfers between two members use hidden addon whispers; broadcasts use the
  hidden guild addon channel.
- The origin is one random constant per player, made at install.
- Alt detection through the origin is a wanted feature.
- Officers are the rank indexes 0 (`O`, guild master) and 1
  (`Ministry of War`), hardcoded in the addon. `Core` is not an officer rank.
- `guildbank` is written by officers only; everyone reads it, and members may
  pass it on when no officer is online (7.5).
- `profession_id`, `profession_skills`, `equipment`, and `attunement` are
  written by each player for their own characters only, and anyone may pass them
  on (5.2).
