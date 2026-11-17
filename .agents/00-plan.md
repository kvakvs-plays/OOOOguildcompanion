# Plan: shared guild database

A database that every guild member with the addon holds in full and that converges between members through
addon messages. It is not realtime: data moves in the background, when the game is quiet.

Status: design only. Nothing here is implemented. Items marked **PROBE** are unverified on the Forever
release client and must be tested there before code depends on them.

- Implementing this plan - commit after each task. Commit title shall be "[plan] <task title>".
- New code (functions, data structures, types) shall have one-line explanation of intent behind it.
- Done task steps shall be removed from 00-plan and moved into a new file `00-finished.md` as compacted 1-2 line bullet points.

## 1. Goals and limits

- Each member holds a full copy, stored in the account-wide saved variables.
- The database has named **tables** (sections). Examples: `profession_id[name]`,
  `profession_skills[name][id]`, `equipment[name]`, `guildbank`.
- Every record carries a version id. Every table carries a table version, so two members can tell with one
  short message whether their copies of a table differ.
- A member who logs in finds the other members, compares table versions, and fetches only the records that
  they lack, from the member with the most recent data.
- A local change is shared later, by a per-table policy (out of combat, out of raid, or only when resting).
- Messages from other members are untrusted input.

Out of scope for this plan: the code that scans professions, equipment, and the guild bank and writes the
records. Each of those gets its own plan. This plan delivers the engine and an API for them.

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

An 11-character string over the 94 printable ASCII characters `!` (33) to `~` (126). A plain byte-order
string comparison of two ids gives their order in time.

```
TTTTT OOOO RR
|     |    +-- small random; +1 for each id made in the same second (2 chars, 8836 values)
|     +------- origin: random, made once at install and stored (4 chars, 94^4 = 78 million values)
+------------- timestamp in seconds, big-endian base 94 (5 chars, enough until the year 2202)
```

- The component order is fixed: timestamp, origin, random. The origin is at a fixed position, so it can be
  read from any id.
- **Requirement: ids are strongly ordered by time.** Three rules give this:
  - Time comes from `GetServerTime()`, so all members share one clock and the local PC clock does not matter.
  - Within one replica: when the second is the same as for the previous id, the random part is the previous
    one plus 1; otherwise it is a random value in the lower half of the range. If it would overflow, the
    timestamp moves 1 second ahead. Ids made by one replica therefore always increase.
  - Across replicas: a new id must be greater than the `maxId` of its table (4.1). If the current second
    does not give that, the timestamp is `maxId`'s second plus 1. A new write is then always newer than
    everything the replica has seen, also when another origin wrote in the same second.
- Two ids from different replicas in the same second, written without knowledge of each other, are ordered
  by origin. That order is arbitrary but the same for everybody, which is all that the merge rule needs.
- Origin: 4 random base-94 characters, made at the first run and stored in `db.global.sync.origin`. It never
  changes after that. The saved variables are account-wide, so all characters of the player share it; this
  is what makes alt detection possible (5.1).
  - It is lost only when the saved variables file is deleted. The player then gets a new origin, and the
    old records stay valid under the old one.
  - A second computer gets its own origin unless the saved variables file is copied there. Do not copy the
    file between computers that are both in use: two replicas with one origin break the clock rule in 4.2.
  - With 500 players the chance that any two origins are equal is about 0.2%.
- Hash: an arithmetic-only 32-bit string hash (`h = (h * 33 + byte) % 2^32` plus a final mix). It must not use
  the `bit` library, so that the same file runs in the host tests on Lua 5.4.
- Validation of a received id: length 11, every byte in 33-126, timestamp not more than 5 minutes ahead of
  `GetServerTime()`. A record with an invalid id is dropped.
- Known costs of base 94: AceSerializer escapes `^` and `~` (2 bytes each on the wire), and `|` must be
  escaped as `||` before an id is printed to chat.
- **PROBE**: Lua compares strings with `strcoll`. Check in the client that `"!" < "A"`, `"Z" < "a"`, and
  `"a" < "~"` hold. If they do not, compare ids with a byte-wise helper everywhere.

## 4. Data model

### 4.1 Storage

In AceDB `global` (one copy per account, not per profile). `SCHEMA_VERSION` in `Src\Core.lua` rises to 2 and
`migrate` creates the empty structure.

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

- Keys are flat strings. A nested section such as `profession_skills[name][id]` uses a joined key
  (`"Name:id"`); the table definition owns the join and split.
- Prefer coarse records. One record per character and profession with a list of recipe ids costs far less
  than one record per recipe, because every record pays 11 bytes of id plus its key.

### 4.2 Merge rule and the clock

- **Last writer wins per key**: a received record replaces the local one when its id is greater.
- The clock is updated for every received record, also for one that lost to a newer local record.
- **Invariant**: for each origin `O`, the replica has seen every record that `O` wrote up to `clock[O]`: it
  holds either that record or a newer one for the same key.
- To keep the invariant, records always travel **sorted by id, ascending**, and a batch is applied whole. A
  transfer that stops halfway then leaves a valid, shorter state.
- Why a clock and not one "newer than X" mark per table: a replica can hold a new record from origin A and
  still lack an older one from origin B. A single mark would skip B's record forever.

### 4.3 Table version

`tableVersion = maxId .. base94(fp, 5)`, 16 characters.

- `fp` is the sum, modulo 2^32, of `hash(id)` over all ids in the clock. It is updated in place when one clock
  entry changes (subtract the old hash, add the new one) and does not depend on order.
- Equal fingerprints mean equal clocks, and by the invariant equal data. Different fingerprints mean that at
  least one side lacks something.
- `maxId` tells which side has the most recent write and is used to pick a source.
- The fingerprint covers the clock, not the records, so local cleanup (4.4) never makes two tables look
  different.

### 4.4 Deletes and cleanup

- A delete is a tombstone record (`x = true`) with a new id. It spreads like any record.
- Tombstones older than 90 days are removed locally.
- A replica whose `syncedAt` for a table is older than 60 days empties that table and its clock before its
  next pull, so that it cannot keep records whose tombstones are already gone.
- For tables keyed by character name, each replica also drops records of characters that are no longer in
  the guild roster. This is a local rule and sends nothing.

## 5. Table definitions and API

`Src\Sync\SyncTables.lua` holds a registry. A feature module registers its table at file scope:

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

- `ns.sync:Put(tableName, key, payload)`: writes a record with a new id and marks the table dirty. It skips
  the write when the payload equals the stored one, so a repeated scan sends nothing.
- `ns.sync:Delete(tableName, key)`, `ns.sync:Get(tableName, key)`, `ns.sync:Iterate(tableName)`.
- `ns.sync.RegisterCallback(owner, "OnRecordChanged", fn)` (CallbackHandler): fires for local and remote
  changes, for UI refresh.

### 5.1 Built-in table `character` and alt detection

- Key: character name. Payload: class, level, and other small facts about the character. Each character
  writes its own record at login when the payload has changed.
- The origin inside the record's id is the player. Characters whose records have the same origin are alts
  of one player. `ns.sync:GetAlts(name)` returns them; a later feature shows them in the UI.
- Showing alts to all members is intended; it is one of the purposes of the addon.
- A player with two installs appears as two origins. Both write the same character names, so the alt query
  joins origins that share a character.

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

- The key starts with a character name. `Put` and `Delete` succeed only when that name is the character
  that is logged in. A player therefore writes only their own data, one character at a time.
- Any member may pass the records on: every peer is a valid source for pull and push.
- Check on receive: in a push of local changes, each key must name the sender or a character that the
  `character` table lists under the same origin. A record that fails is dropped by the rule in section 8.
- Records that arrive through a third member (pull, or the push after a pull) cannot be checked this way.
  This is the accepted risk in section 8.

## 6. Transport

- Add `AceComm-3.0` and `AceSerializer-3.0` to `embeds.xml`. Both are already in `Ace3\`. The embedded
  ChatThrottleLib is version 31, which already retries on the `AddonMessageThrottle` result.
- One prefix: `OOOO`.
- Every message is `AceSerializer:Serialize(protocolVersion, type, ...)`. A receiver ignores a message with a
  greater protocol version and tells the user once that a newer addon version exists.
- Channels:
  - `GUILD` for hello, summary, and push (everybody needs them).
  - `WHISPER` for a pull request and its answer (two members only).
  - Both are hidden addon messages: `AceComm:SendCommMessage(prefix, text, distribution, target, prio)` sends
    through `C_ChatInfo.SendAddonMessage`, and no distribution (`GUILD`, `WHISPER`, `PARTY`, `RAID`) shows
    anything in a chat frame. Members never see the encoded traffic.
  - One visible side effect exists: an addon whisper to a player who has just gone offline makes the client
    print "No player named X is currently playing". Whisper only to peers that the roster shows online, and
    hide that system line for a target for a few seconds after a send with a `CHAT_MSG_SYSTEM` message
    filter. Guard the filter with `issecretvalue`.
  - AGENTS.md says that addon messages use the `GUILD` channel only. Change that line in stage 4 to allow
    `WHISPER` for transfers between two members.
- `SendCommMessage` also takes a progress callback (bytes sent, bytes total). Use it to send the next batch
  only when the previous one has left the queue, and for the status line in the options.
- All sends use AceComm priority `BULK`, except hello and summary, which use `NORMAL`.
- Sender checks: a whisper from a name that is not in the guild roster cache is ignored. On Forever a
  region has one realm per ruleset, so sender names need no realm handling; strip a realm suffix if present.
- Expected speed: about one 255-byte message per second per prefix after a burst of 10, if Forever has the
  Retail limit (**PROBE**). A full copy of 150 KB then takes about 10 minutes, which is acceptable for
  background work. LibDeflate can be added later if this proves too slow.

### 6.1 Messages

| Type | Channel | Fields | Purpose |
| --- | --- | --- | --- |
| `H` hello | GUILD | `{ table -> tableVersion }` | Sent once after login. Asks peers to answer. |
| `S` summary | GUILD | `{ table -> tableVersion }` | Answer to hello, and notice after a merge. |
| `Q` pull request | WHISPER | table, schema, nonce, digest | Digest is the clock as one string of 11-char ids. |
| `D` delta | WHISPER | table, nonce, batch number, last flag, records, wants | Records the requester lacks, ascending. |
| `P` push | GUILD | table, schema, base, records | New records for everybody. |
| `B` busy | WHISPER | table, nonce, reason, retry seconds | Refusal: busy, unknown table, or other schema. |

- A record on the wire is `key, id, payload` (or `key, id` with a tombstone marker).
- `wants`, in the last delta batch, lists the origins for which the requester is ahead, with the
  responder's clock value for each. The requester then pushes those records to the guild (7.3).
- `base` in a push is `origin -> id before the first pushed record of that origin`. A receiver applies the
  records of an origin only when its own clock for that origin is at or beyond the base. Otherwise it has a
  gap, ignores those records, and schedules a pull.
- A table with a different `schema` on the two sides is not synchronized. Unknown table names are ignored.

## 7. Flows

### 7.1 Start and discovery

1. Sync starts only after the guild check passes (guild name is `OO OO`). `EmojiChat.lua` already has this
   check; move it to one shared guild-state module in `Src\` that both use.
2. Request the roster once with `C_GuildInfo.GuildRoster()` and keep a cache of `name -> online` from
   `GUILD_ROSTER_UPDATE`. The roster gives the set of valid senders and tells when a peer goes offline.
3. After a random delay of 20 to 40 seconds, and when the sync conditions (7.4) allow, send `H`.
4. A peer that receives `H` answers with `S` for the tables whose version differs from the one in `H`. It
   waits a random 1 to 8 seconds first and drops a table from its answer when another peer has already
   announced the same table version in that time. A hundred peers in the same state give one answer.
5. The new member collects answers for 10 seconds. The roster alone cannot tell who has the addon; the
   answers can.

### 7.2 Pull

1. For each table, take the peers whose fingerprint differs from the local one and choose the one with the
   greatest `maxId`. Ties go to the peer that answered first.
2. Send `Q` with the digest. One pull runs at a time; the other tables wait in a queue.
3. The responder selects, for each origin, its records with an id greater than the digest value, sorts them
   by id, and sends them in `D` batches of about 2 KB. A large selection is cut across frames with
   `C_Timer.After` to avoid a stall.
4. The requester validates and applies each batch, then stores the new clock, `maxId`, and `fp`.
5. After the last batch, the requester marks that fingerprint as merged. Peers with a merged fingerprint are
   skipped. If other peers still differ, the next one is taken, again by the greatest `maxId`.
6. Failure handling: no batch for 60 seconds, or the peer goes offline in the roster, ends the pull. The
   applied batches stay. The table returns to the queue with another peer.
7. A responder serves one pull at a time and answers further requests with `B` and a retry time.

### 7.3 Push

Two sources of a push, one message type:

- **Local changes.** `Put` marks the table dirty. When `pushDelay` has passed since the first unsent change,
  `minInterval` has passed since the last push of that table, and the conditions allow, the replica sends
  its own new records in `P`, with the base set to its last pushed id.
- **After a pull.** The requester sends the records named by `wants` in `P`, with the responder's clock values
  as base. All peers in the same state as the responder can apply them at once.

A peer that hears `S` or `P` with a table version that differs from its own, and that could not apply the push,
schedules a pull after a random 30 to 120 seconds and checks again before it sends: in most cases a push
has closed the difference by then. This delay is what prevents many peers from pulling from one member at
the same moment.

### 7.4 Conditions and policy

Per table, with defaults from the table definition and overrides in `db.profile.sync.tables[name]`:

| Field | Values | Meaning |
| --- | --- | --- |
| `when` | `nocombat`, `noraid`, `resting` | Weakest state in which this table may send. |
| `pushDelay` | seconds | Wait after a local change, to collect several changes into one push. |
| `minInterval` | seconds | Shortest time between two pushes of the table. |
| `enabled` | boolean | Off: the table is neither sent nor requested. |

- `nocombat`: `InCombatLockdown()` is false. `noraid`: also not in a raid group and not in an instance.
  `resting`: also `IsResting()` is true.
- State changes come from `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`, `PLAYER_UPDATE_RESTING`,
  `GROUP_ROSTER_UPDATE`, and `PLAYER_ENTERING_WORLD`. Timers use `C_Timer`; there is no `OnUpdate`.
- When a condition turns false during a transfer, the sender stops after the current batch. The receiver's
  timeout (7.2 step 6) handles the rest.
- Receiving is always allowed: applying a batch is cheap and has no protected calls.
- The options window gets a "Sync" page (AceConfig) with these fields per table and a status line per table:
  record count, last sync time, current source.

### 7.5 Officer tables

A table with `writers = "officer"` (for example `guildbank`) has stricter rules. "Officer" means the
guild ranks 1 (guild master), 2, and 3. The list is a hardcoded constant in the addon
(`ns.OFFICER_RANKS`), not a setting. The roster API counts ranks from 0, so the constant holds the rank
indexes 0, 1, and 2 (**PROBE**: confirm that the guild master has index 0 on Forever). The roster gives the
rank of every sender. The rank belongs to the character that is logged in, not to the
player.

| Who | Writes | Takes data from | Serves pulls | Pushes |
| --- | --- | --- | --- | --- |
| Officer | yes | officers only | yes | yes |
| Member | no | officers; members only by the rule below | only by the rule below | never |

- **Member relay.** A member takes an officer table from another member only when the table has
  `memberRelay = true` and no officer peer is online. In every other case only an officer is a source. A
  member serves a pull for such a table under the same two conditions.
- A push of an officer table is applied only when the sender is an officer.
- In discovery (7.1), officers always answer for officer tables; an answer from a member does not suppress
  theirs. In source choice (7.2), officer peers are taken first, by the greatest `maxId`.
- `Put` and `Delete` fail on a character that is not an officer.
- **Trust flag.** A copy that has taken data through member relay is marked `trusted = false`.
  - A member with an untrusted copy replaces it when an officer is online: it empties the table and the
    clock and pulls from the officer.
  - A copy that is trusted and not empty never uses member relay, also when the player is on a member-rank
    alt. This keeps an officer's copy clean.
  - An officer character with an untrusted copy does not serve or push it. It empties the table and pulls
    from another officer, or empties it at its first own write when no other officer is online.
- A member-rank alt of an officer follows the member rules.

## 8. Trust and validation

- Deserialize with `AceSerializer:Deserialize` only; never run received text.
- Check before use: protocol version, message type, table name is registered, schema matches, every id is
  valid (section 3), key is a string within a length limit, payload passes the table's `validate`, record
  size is within `maxRecordBytes`, batch count and digest length are within limits.
- For `keyKind = "character"`, the key must be a name in the guild roster.
- One bad record drops that record and all later records of the same origin in the batch (to keep the
  invariant), not the whole session.
- Accepted risk for owner tables: a member with a modified addon can write wrong data under any key. The
  addon cannot prove who owns a character. The damage is limited to wrong shared data, which a later
  correct write replaces; a future timestamp is limited to 5 minutes.
- Officer tables do not have this risk while an officer is the source, because the sender's rank comes from
  the roster and not from the message. Member relay brings the risk back for the time until an officer is
  online; that is why it marks the copy as untrusted (7.5). `guildbank` has relay on.

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
Tests\sync_*.lua                   host tests
```

Also: add the files to `toc_template.toc`, add the two Ace libraries to `embeds.xml`, and add new API globals
(`GetServerTime`, `IsResting`, `C_GuildInfo`, ...) to `.luacheckrc` after each is confirmed in
the client. `Src` is already in `COPY_DIRS`; `Tests` and `.agents` are outside `Addon`, so `wowaddon.py`
needs no change.

The host-testable files take the time, the random source, and the origin as parameters and do not touch
WoW globals.

## 10. Stages

Each stage ends with luacheck at 0 warnings, and says what was tested on the host only.

1. **Probes.** A `/oooo sync probe` command that prints: string comparison order; `GetServerTime()`;
   the rank index of each roster member; whether a whisper to an offline name prints a system line; a round
   trip of all 94 characters through `GUILD` and `WHISPER` addon messages; the
   result code of a burst of 30 messages; whether sending works in combat, in a dungeon, and in a raid.
   Record the results in AGENTS.md. Later stages adjust to them.
2. **Core logic with host tests.** `Base94`, `VersionId`, `SyncStore`. Tests: id order equals time order; ids
   from one replica always increase; merge is independent of arrival order of batches from different
   peers; an interrupted transfer keeps the invariant; fingerprints are equal exactly when clocks are; three
   simulated replicas with random writes and random pulls converge.
3. **Storage and API.** Saved variables schema 2, origin, registry, `Put`/`Get`/`Delete`, callbacks, the
   `character` table with `GetAlts`, a test table `debug` with free keys, and `/oooo sync put|get|status`.
4. **Transport and discovery.** Change the channel rule in AGENTS.md. Guild-state module, AceComm wiring, `H` and `S`, peer list in
   `/oooo sync status`. Client test with two accounts.
5. **Pull.** `Q`, `D`, `B`, queue, timeouts. Client test: a fresh install receives the `debug` table.
6. **Push and policy.** `P`, base check, delayed pull, conditions, options page.
7. **Write rules.** The owner check of 5.2. For officer tables: `OFFICER_RANKS`, `memberRelay`, the trust flag, and the rules of 7.5, with host tests for the
   source choice and a client test with an officer and a member account.
8. **Cleanup.** Tombstone removal, the 60-day reset, roster cleanup, size limits.
9. **First real table.** `equipment`, by its own plan. Then professions and guild bank.

## 11. Decisions taken

- Transfers between two members use hidden addon whispers; broadcasts use the hidden guild addon channel.
- The origin is one random constant per player, made at install.
- Alt detection through the origin is a wanted feature.
- Officers are guild ranks 1 (guild master), 2, and 3, hardcoded in the addon.
- `guildbank` is written by officers only; everyone reads it, and members may pass it on when no officer is
  online (7.5).
- `profession_id`, `profession_skills`, `equipment`, and `attunement` are written by each player for their own
  characters only, and anyone may pass them on (5.2).
