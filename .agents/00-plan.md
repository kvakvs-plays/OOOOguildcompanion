# Plan: shared guild database

A database that every guild member with the addon holds in full and that
converges between members through addon messages. It is not realtime: data moves
in the background, when the game is quiet.

Status: stages 0 to 7 are finished, and stage 8 except for the hour-long
client session, which is postponed to step 10.2 (`00-finished.md`). Stage 9
is postponed. The code of stage 10 is finished; its client checks (10.2,
10.3) are open. The probes of stage 1
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
  `guildchat`.
- Every record carries a version id. Every table carries a table version, so two
  members can tell with one short message whether their copies of a table
  differ.
- A member who logs in finds the other members, compares table versions, and
  fetches only the records that they lack, from the member with the most recent
  data.
- A local change is shared later, by a per-table policy (out of combat, out of
  raid, or only when resting).
- Messages from other members are untrusted input.

Out of scope for this plan: the code that scans professions and equipment and
writes the records. Each of those gets its own plan. This plan delivers the
engine and an API for them. The table `guildchat` (5.3, stage 10) is the
exception: it is part of this plan. The chat history window with the
mentions of `user-wishes.md` reads it and is stage 11. A bridge to Discord, if it comes,
gets its own plan.

Not planned:

- A guild bank table. The guild bank is expected as a standard feature of the
  game, so the addon does not copy it.
- Tables that only officers may write. The guild bank was their only use, so
  the officer rules, member relay, and the trust flag are dropped for now. The
  old design is in the git history of this file (before this change: section
  7.5 and the stage steps 7.2 and 7.3).

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
      freshAt = 1795000000,       -- server time of the last contact, see 4.4
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
- Assumption on concurrent writes: no planned table has a key that two players
  write. In an owner table a key is written by its owner alone. Last writer
  wins therefore never has to decide between two players; only the `debug`
  table (`writers = "anyone"`) lets two players write one key.
  - A key of an owner table can still have writes of two origins: one player
    with two installs. These are not concurrent, because one account is
    logged in once.
  - The clock rest above is needed for that case: a second install that
    replaces the first one's record.
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
- A replica whose last contact for a table (`freshAt`) is older than 60 days
  empties that table and its clock before its next pull, so that it cannot keep
  records whose tombstones are already gone.
  - `freshAt` is set when the replica completes a pull, when a peer announces
    a table version that the replica holds (it then holds all that the peer
    holds), when the table is emptied, and when a table without contact takes
    its first records from others. The time of the last pull alone would not
    do: a replica in a healthy guild gets everything by push and never pulls.
    A table without `freshAt` falls back to `syncedAt`.
  - A table that never had contact has neither value and is not emptied: it
    holds only own writes.
  - Until its pull, a stale table answers a pull request with `B` `busy`, so
    no other replica takes the old records from it.
  - The reset also removes own writes that were never pushed. A feature that
    scans again writes them again, because `Put` then finds no equal record.
  - Known cost: two replicas that both return after 60 days and differ both
    empty their tables. What only those two held is lost, except the own
    records that their features write again.
- For tables keyed by character name, each replica also drops records of
  characters that are no longer in the guild roster. This is a local rule and
  sends nothing. It runs once per stay in the guild, after discovery, and only
  when the roster cache lists every member (`guildState:IsRosterComplete`):
  the roster read gave an entry for each index, and the own character is in
  it. A roster entry that is secret makes the cache incomplete, and the
  cleanup waits for a later roster update. A read while
  `GetGuildRosterShowOffline()` is not `true` is incomplete too: the client
  may then leave the offline members out.
- A table with `maxAge` (5.3) drops records whose id is older than that age.
  This is also a local rule: it sends nothing and leaves the clock and `fp` as
  they are. Two replicas with equal clocks can then hold different numbers of
  old records, which is intended.

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
                                      -- "anyone": every member writes every key (the debug table)
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
| `guildchat` | the record's own id | anyone; by rule the sender, or one witness (5.3) | anyone |

Rules for `writers = "owner"`:

- The key starts with a character name. `Put` and `Delete` succeed only when
  that name is the character that is logged in. A player therefore writes only
  their own data, one character at a time.
- Any member may pass the records on: every peer is a valid source for pull and
  push.
- Check on receive: in a push of local changes, each key must name the sender or
  a character that the `character` table lists under the same origin. A record
  that fails is dropped by the rule in section 8.
  - A push can carry an unsent write of an alt (written, then logged out
    before the push). A receiver that does not yet hold the `character`
    records of both characters drops it; its versions then still differ, and
    the pull that follows brings the record.
  - The first `character` record of a name is therefore accepted in a push
    only from that name itself.
- Records that arrive through a third member (pull, or the push after a pull)
  cannot be checked this way. This is the accepted risk in section 8.

### 5.3 Table `guildchat`

A copy of the guild chat that every replica holds for the last days. Its
purpose is the time in which a member was offline: a member who logs in gets
the lines that they missed. It has no UI in this plan. Officer chat is not
recorded.

```lua
ns.sync:RegisterTable({
  name = "guildchat",
  schema = 1,
  keyKind = "free",
  validate = ...,                     -- s: a string of 1 to 48 bytes; t: a string of 1 to 255 bytes
  maxRecordBytes = 400,
  writers = "anyone",
  maxAge = KEEP_DAYS * 86400,         -- new field, see below; KEEP_DAYS = 14
  policy = { when = "nocombat", pushDelay = 300, minInterval = 600 },
})
```

- **Not real time.** An online member reads the chat in the game, so the table
  does not have to follow the chat closely. A writer collects its lines for 5
  minutes and sends them in one push, at most once in 10 minutes. The member
  who logs in pulls what is missing (7.2); that is the path that matters.
  - Known gap: a member who writes a line and logs out before the push keeps
    that line alone. It reaches the others when that member logs in again
    (the push after a pull, 7.3).
- **Record.** One chat line is one record that is written once and never
  changed or deleted. Payload: `{ s = sender name, t = text }`.
  - `t` is the text as the `CHAT_MSG_GUILD` event gives it, with item links
    and other escape sequences. The emoji replacement is a chat frame filter
    and changes only what the chat frame shows, so the event text is the
    original.
  - The time of the line is the timestamp inside the record id (section 3).
    The payload carries no time.
- **Key and order.** The key is the record's own id. Sorting the keys with `<`
  gives the lines in the order of time. The engine gets
  `ns.sync:Append(tableName, payload)` for this: it makes the id and stores the
  record under it.
  - Two lines within one second from different writers are ordered by origin,
    not by arrival. A reader must accept that.
  - An id can be ahead of the real time: by 1 second or more when the replica
    has already seen a later id (section 3), at most 5 minutes.
- **Who writes a line.** Every online member hears the same line, but the
  game gives the line no id that all clients share. If every replica stored
  what it hears, one line would become one record per listener. So exactly one
  replica writes it:
  - The sender's addon writes its own lines.
  - A line of a member who is not a peer (no addon, or not yet announced) is
    written by the **witness**: the replica whose character name is the first
    in byte order among itself and its online peers.
  - Replicas can disagree for a short time about who is a peer. Then a line
    is written twice or not at all. Twice is repaired on reading: records with
    the same sender and the same text whose ids are within 3 minutes count as
    one line (`DUPLICATE_WINDOW = 180`); the earliest one is shown. The window
    is wide because an id can be minutes ahead of the real time (above). A
    member who repeats a text within the window is therefore shown once; that
    is accepted. A lost line is accepted too.
  - A replica is not a witness before its first discovery is complete (7.1
    step 5). Until then it knows no peers and would write every line that it
    hears, also the lines of members who have the addon.
  - **A peer list without holes.** The witness rule needs to know who has
    the addon, and the summaries do not tell: a replica whose tables equal
    those of the others, the normal case after a `/reload` or a short
    absence, gets no summary as answer to its hello. Without more it would
    know no peer, take itself for the witness, and write every line that it
    hears, also the lines of members with the addon (found in step 10.3).
    So every peer answers a hello with the whisper `A` "here" (6.1, 7.1
    step 4). A whisper that is lost still leaves a hole; then a line is
    written twice until the replica hears another message of that peer.
  - Every other replica gets the line through the push and the pull. It does
    not store what it hears itself.
- **No gap after login.** A member who logs in can hear a push, write an own
  line, or act as witness before the first pull has run. None of this may make
  the replica believe that it is up to date. Three rules of the engine give
  that, and no "newest line that I hold" mark may ever replace them:
  - What a replica lacks is decided per origin, by the clock (4.2), not by the
    time of its newest record. A new record of origin A says nothing about the
    records of origin B.
  - A pushed record of an origin is applied only when the own clock for that
    origin is at or beyond the `base` of the push (6.1). A replica that was
    away has an older clock value, so it ignores the records and schedules a
    pull. It never stores a late line with a hole before it.
  - An own line or a witness line raises only the clock entry of the own
    origin, and a replica holds all records of its own origin.
- **Secret values.** The sender and the text of a chat event can be secret
  (AGENTS.md). A line with a secret sender or text is not recorded. Whether
  guild chat is secret in combat or in an instance is not known; step 10.2
  checks it.
- **Retention.** Every replica keeps the last 14 days. The length is the
  constant `KEEP_DAYS` in `SyncGuildChat.lua`, the same for everybody; it is
  not a setting.
  - `maxAge` is a new, optional field of a table definition: a number of
    seconds. The engine uses it in two places. On receive, a record older
    than that age is not stored but still raises the clock (the verdict
    `"seen"`, as in the roster rule of section 8). At login and then once per
    hour, the stored records older than that age are removed (4.4).
  - All replicas keep the same length, so a pull request needs no lower limit
    (an earlier design had the field `floor` in `Q` for replicas with
    different lengths). A responder can still hold lines of up to an hour
    over the age, until its next cleanup; the requester counts them as seen.
  - A member who was away for longer than 14 days gets only the last 14 days.
- **Trust.** `writers = "anyone"` is needed for the witness, so a member with a
  modified addon can write a line under any sender name. A reader can tell the
  sender's own write from a witness write: the origin in the id belongs to the
  sender in the `character` table (5.1) or it does not. A feature that shows
  the lines may mark the second kind.
- **Size.** Assumed, not measured: 1000 lines per day at about 90 bytes on the
  wire (22 bytes of key and id, the name, the text) is about 90 KB per day. A
  first pull of 1 day takes about 6 minutes at the measured speed (section 6).
  The 14 days that are kept are then about 1.3 MB, and the first pull of a
  new member about 80 minutes of background traffic; a pull that is cut goes
  on where it stopped (4.2). If this proves too slow, LibDeflate and a
  shorter key are the first savings.
  The key repeats the id; sending it once is a later saving, like LibDeflate.

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
| `A` here | WHISPER | none | Answer to a hello: the sender has the addon. Tells nothing about tables. |

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
   - Every peer also whispers `A` "here" to the sender of the hello, after a
     random 1 to 8 seconds, so that the sender knows all peers and not only
     the one that sent a summary (5.3). The whisper is left out when
     - the peer sends a message to the guild in that time (its summary, its
       own hello, a push): the sender hears that;
     - the peer has whispered that member within the last 15 seconds
       (`whisperedAt`, the time of the last whisper of any type per member,
       and `PRESENCE_INTERVAL`).
   - The interval must stay below 20 seconds, the shortest time between a
     login and its hello: a login or a `/reload` empties the peer list of a
     replica, so a hello always comes from a replica that has forgotten every
     earlier whisper. A longer interval would bring the hole back.
   - In combat the whisper waits, like a hello, and goes afterwards.
   - Cost: one message of about 10 bytes per peer and login.
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
- The options window has a "Sync" page (AceConfig) with these fields per table
  and a status line per table: record count, last sync time, current source.
  The page is for developers: it is shown only in the developer mode
  (`/oooo sync debug on`, section 8), and the overrides apply only in that
  mode. Every other user runs each table with the preset of its definition
  and has no setting of the shared database at all. An override that was
  stored in the developer mode stays in the saved data and has no effect
  while the mode is off.

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
- The limits, in `SyncStore.lua` (shared by the registry and the protocol) and
  `SyncProtocol.lua`:

  | Limit | Value |
  | --- | --- |
  | Key of a record | 64 bytes |
  | Table name | 32 characters |
  | Tables in the registry, and in one `H` or `S` | 64 |
  | Records in one `D` or `P` | 500 |
  | Origins in a digest, a clock rest, or the wants | 2000 (a digest of 22000 bytes) |
  | Batch number of one pull | 100000 |
  | Retry time of a `B` | 3600 s |
  | Size of one batch | about 2000 bytes, by the estimate |

- The size of a record is `syncStore.recordSize`: the key, the id, and the
  payload by `estimateSize`, which needs no serializer (2 bytes per value plus
  its text, 4 per table; AceSerializer writes the same, without its escapes).
  `Put` refuses a record over `maxRecordBytes` of its table with
  `"too large"`; a received one is dropped like any bad record.
- The developer mode is the setting `db.global.debugTable`, turned on with
  `/oooo sync debug on` and off by default. Only in it is the table `debug`
  (`writers = "anyone"`) registered, so a release has no table that every
  member can fill with text; and only in it is the "Sync" page shown and do
  its send settings apply (7.4).
- Accepted risk for owner tables: a member with a modified addon can write wrong
  data under any key. The addon cannot prove who owns a character. The damage is
  limited to wrong shared data, which a later correct write replaces; a future
  timestamp is limited to 5 minutes.

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
Addon\Src\Sync\SyncCleanup.lua     old tombstones, the reset of a stale table, roster cleanup (stage 8)
Addon\Src\Sync\SyncOptions.lua     options page
Addon\Src\Sync\SyncProbe.lua       /oooo sync probe commands (stage 1)
Addon\Src\Sync\SyncGuildChat.lua   the table guildchat: capture, witness rule, ordered reading (stage 10)
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

Finished; see `00-finished.md`.

### Stage 7. Write rules

Finished; see `00-finished.md`.

### Stage 8. Cleanup

The code of both steps is finished, and the client checks of step 8.2 that
were run all passed; see `00-finished.md`. One check is postponed:

- **8.2 Roster cleanup and size limits: the hour in the client** (**CLIENT**,
  two accounts). Postponed to step 10.2: until the table `guildchat` exists,
  a session has almost no writes, so an hour of it shows little.
  - Run a session of two accounts for an hour, with guild chat lines written
    in it, without a Lua error or an "Interface action failed" entry. Turn
    on `/console scriptErrors 1` and `/console taintLog 1` first; the second
    writes `Logs	aint.log`, which shows a blocked action of the addon after
    the session.
  - Done when: the result is recorded in `00-finished.md`.

### Stage 9. First real table

Postponed (2026-11-18): the guild has no use for equipment data yet. Stages
10 and 11 do not depend on it.

- **9.1 Plan for `equipment`**
  - Substeps
    - Write `.agents/01-equipment-plan.md`: the payload layout, the scan events,
      the `validate` function, the policy defaults, and the UI that reads the
      table.
    - List what the engine lacks for it, if anything, and add those steps to
      this plan.
  - Checkpoint: the new plan is reviewed.
  - Host tests: none in this step; the new plan names its own.
  - Done when: the plan is committed. Professions follow in the same way.

### Stage 10. Guild chat table

Design in 5.3. It does not depend on stage 9. The code of the three steps is
finished and checked on the host; the two client checks need two accounts.

- **10.1 Engine: `Append` and `maxAge`**: finished; see `00-finished.md`.
- **10.2 Table `guildchat`: own lines, retention, reading** (**CLIENT**, two
  accounts). The code and the host tests are finished; see `00-finished.md`.
  The client check is open:
  - Checkpoint (**CLIENT**): account B is offline. Account A writes three lines
    in guild chat, one of them with an emoji name and one with an item link.
    Account B logs in; after its pull, `/oooo sync chat` shows the three lines
    in order with the original text (the command doubles every `|`, so a
    link shows as its escape sequence). Run the postponed hour of step 8.2
    (stage 8) in this session. Record whether a line written in combat
    and one written inside a dungeon are stored, or are secret.
  - Not known before this check. The last line of `/oooo sync chat`
    ("capture: ...") shows each of them:
    - Whether `CHAT_MSG_GUILD` is a valid event on Forever. If not, the line
      reads "the client has no event CHAT_MSG_GUILD".
    - Whether the sender of the event is the roster name (`Nota Scam`, no
      realm suffix), as it is for an addon message. The line prints "own
      name" and "last sender"; when they differ for an own line, "written"
      stays 0.
    - Whether guild chat is secret in combat or in a dungeon: "secret"
      counts the lines that were not recorded for that reason.
  - First result (2026-11-18, one account, screenshot of `/oooo sync chat`):
    the event is valid and the sender is the roster name, see step 10.3.
  - Second result (2026-11-18, two accounts, screenshots): the checkpoint
    passed. `Nota Tall` wrote "test", "test kek" (an emoji name, shown as
    the emoji in chat), and "test" with an item link while `Nota Scam` was
    offline. On `Nota Tall`, `/oooo sync chat` showed the three lines
    without the mark `(witness)`. `Nota Scam` logged in and showed, 3
    minutes after the lines, all 8 stored lines in the same order with the
    original text; the link arrived as
    `|cnIQ1:|Hitem:4603::::::::45:1485:::::::::|h[Raw Spotted Yellowtail]|h|r`.
    The lines of `Nota Tall` were unmarked there too, so the origin was
    found in the table `character`. The capture line of `Nota Scam` read
    "listening; this session 0 lines heard, 0 secret, 0 written; own name
    'Nota Scam', last sender 'nil'; witness".
  - Still to see: the count "secret" after a line in combat and one in a
    dungeon, and the hour of step 8.2.
  - Done when: the client checkpoint and the hour of step 8.2 are recorded.
- **10.3 Witness for members without the addon** (**CLIENT**, two accounts and
  a member without the addon). The code and the host tests are finished; see
  `00-finished.md`. The client check is open:
  - Checkpoint (**CLIENT**): a member without the addon writes a line; it
    appears once on both accounts, marked `(witness)` in `/oooo sync chat`.
    Also record how many records `/oooo sync status` counts for `guildchat`
    after a `/reload` of one account and some lines of the other: more
    records than lines means that the whisper `A` of step 10.4 did not
    arrive (5.3). `/oooo sync status` on the reloaded account must list the
    other one as a peer about 40 seconds after the reload.
  - First result (2026-11-18, one account, screenshot of `/oooo sync chat`):
    "5 lines stored", all five marked `(witness)`: four of `Nixia Ameldus`
    and one of `Æz Clap`, 40 and 41 minutes old, in order, each once. So
    `CHAT_MSG_GUILD` is valid, its sender is the roster name, and the lines
    of members without the addon are written by a witness and marked.
  - Second result (2026-11-18, two accounts): both accounts list the same
    five witness lines, once each and in the same order.
  - Still to see: the record count of `guildchat` in `/oooo sync status`
    against the 8 lines (more records means a line was written twice); the
    peer in the status about 40 seconds after a `/reload`; a line of a
    member without the addon written while both accounts are online.
  - Done when: the client checkpoint is recorded.
- **10.4 A peer list without holes**: finished; see `00-finished.md`. The
  whisper `A` travels in the client for the first time with the check of
  step 10.3.

### Stage 11. Chat history and mentions

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
    another colour, which is cheap for some hundred lines. Whether Forever
    lets an addon scroll it to a given message was not checked: step 11.3
    probes it. If not, the fallback is a list of own rows.
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
  - The link is a custom hyperlink. Whether Forever passes an `addon:` link
    to addons was not checked: step 11.4 probes it. Without it the notice
    names `/oooo chat`.
- **Limit.** The history and the mentions reach back 14 days (5.3). A line that no replica wrote (5.3, witness) is in neither.
- **Warning for the writer.** When the user sends a guild chat line with a
  word that starts with `@`, and the session knows no online peer after its
  discovery, the addon prints: "No other player with the addon is online.
  Your @mention is not shared until one comes online." The line is still
  stored, and reaches the others with the push after the next pull (7.3).
  The warning is printed at most once in 5 minutes. Before discovery has
  ended the peers are unknown and nothing is printed.

- **11.1 Settings and matching**
  - Substeps
    - `Src\Chat\Mentions.lua` (`ns.mentions`): `parseWatchList(text)`
      (split on commas, trim, lower case, drop empty and repeated entries;
      an entry keeps its inner spaces), `hasMention(text)` (any `@` word),
      `fragments(text, watchList)` (the watched `@text` fragments of a line
      as written, in their order; empty when the line does not concern the
      user), and `sanitize(text)` for the window. No WoW API at file scope.
    - Defaults in `Core.lua`: `profile.mentions = { watch = "",
      notifyOnLogin = true }`.
    - The General tab gets a section "Mentions": an edit box "Nicknames and
      keywords to watch (comma separated)" and a checkbox "Tell me after
      login about unread mentions". The description of the edit box names
      the `@nickname` form.
    - Add the file to `toc_template.toc` and to `.agents/project-map.md`.
  - Checkpoint: on the host, `fragments` gives `@Kvakvs` for the entry
    `kvakvs` and nothing for `@kvakvsy`.
  - Host tests (`Tests/sync_mentions.lua`; the name starts with `sync_` so
    that `run_all.lua` finds it)
    - `parseWatchList`: spaces around commas, an empty list, a repeated
      entry, upper case.
    - `hasMention`: `@word` anywhere in the line; a lone `@`; an e-mail
      form `a@b`, which counts; an `@` inside an item link, which does not.
    - `fragments`: at the start, in the middle, and at the end of a line;
      before punctuation; another letter case, returned as written; an
      entry that is the start of a longer word; two watched fragments in
      one line; an entry with a UTF-8 letter; an empty watch list.
    - `sanitize`: an item link and a colour code stay, a lone `|` and a
      texture escape are doubled.
  - Done when: the options appear in the client and keep their values over a
    `/reload` (**CLIENT**).
- **11.2 The mention list**
  - Substeps
    - `db.global.mentions = { lines = {}, lastOnline = nil }` with a
      migration step (`SCHEMA_VERSION` 3). Write `lastOnline` on
      `PLAYER_LOGOUT` and with a `C_Timer` every 5 minutes; check the event
      with `C_EventUtils.IsEventValid`.
    - Follow `OnRecordChanged` of `guildchat`: add an entry for a record
      with an `@` word, with the flag by the rule above; remove the entry of
      a record that is gone (`Expire`, the stale reset).
    - At login, drop the entries without a record and add the missing ones.
    - `ns.mentions:List()`: the entries that concern the user, newest
      first, each with id, time, sender, fragments, and the flag.
      `ns.mentions:UnreadCount()` and `MarkRead(id)`.
    - The callback `OnMentionsChanged`, for the notice and the window.
  - Checkpoint: on the host, a replica that joins after three lines were
    written, two of them with a watched `@` word, lists the two as unread
    after its pull.
  - Host tests (`Tests/sync_mentions.lua`, fake network and fake clock)
    - A line with an unwatched `@` word is in the stored list and not in
      `List()`; after the word is added to the watch list it is.
    - A line of the own character and a line from a time at which the
      account was online are added as read.
    - A line from before the login and after `lastOnline` is added as
      unread; `MarkRead` makes it read, and it stays read over a new login.
    - An entry of 15 days ago is gone after `Expire`.
    - Entries without a record are dropped at login, and a record with an
      `@` word and no entry gets one.
  - Done when: the full host suite passes.
- **11.3 Chat history window** (**CLIENT**)
  - Substeps
    - `ns.guildChat:Page(beforeId, count)` in `SyncGuildChat.lua`: up to
      `count` lines older than `beforeId` (the newest ones when it is nil),
      in id order, from the sorted key list of 10.2; and whether older lines
      exist.
    - `Src\Chat\ChatHistory.lua` (`ns.chatHistory`): the model of the
      window, without frames: the loaded lines, `LoadOlder()`,
      `LoadBackTo(id)`, the line that is highlighted, and the text of a line
      (time, sender, sanitized text). It follows `OnRecordChanged` while the
      window is open.
    - `Src\Chat\ChatHistoryWindow.lua`: the frame, movable, closed with
      Escape (`UISpecialFrames`), its position saved; the
      `ScrollingMessageFrame` with hyperlink clicks passed to
      `HandleModifiedItemClick` and `SetItemRef` as a chat frame does;
      loading of older lines when the user scrolls to the top.
    - Probe in the client: whether the frame can be scrolled to a given
      message, and whether a hyperlink click from an addon frame works
      without an "Interface action failed" entry. Record the result in
      AGENTS.md. If scrolling to a message is not possible, build the list
      from own rows instead.
    - `/oooo chat` opens and closes the window. Show nothing in combat
      lockdown that needs a protected call; the frame itself is not
      protected.
  - Checkpoint (**CLIENT**): after some hundred lines of guild chat with two
    accounts, `/oooo chat` shows the last 100 with times and senders;
    scrolling to the top loads older lines; an item link in a line shows its
    tooltip on click; a new guild chat line appears at the bottom after its
    push.
  - Host tests (`Tests/sync_chathistory.lua`)
    - `Page`: the newest 100 of 250 lines; the 100 before; the last 50 with
      "no older lines"; an empty table.
    - The model: `LoadOlder` three times gives all 250 lines once, in
      order; `LoadBackTo` loads up to and with the given line; a line that
      arrives is added at the end; two records of one line (5.3) are one
      line.
    - The text of a line: the time of the id, the sender, a sanitized text.
  - Done when: the client checkpoint and the probe results are recorded.
- **11.4 Mentions in the window, and the notice** (**CLIENT**, two accounts)
  - Substeps
    - The side lists "Unread" and "Read" in `ChatHistoryWindow.lua`, each
      scrolling by itself, filled from `ns.mentions:List()` and refreshed on
      `OnMentionsChanged`.
    - A click on an entry: `LoadBackTo(id)`, scroll to the line, highlight
      it, and `MarkRead(id)` for an unread one.
    - The notice: 5 seconds after the last new entry, and 10 seconds after
      login when `notifyOnLogin` is on; only when an unread entry concerns
      the user and is newer than the one of the last notice; only in the
      guild state `in`.
    - Probe the link: an `addon:` hyperlink and the callback that the
      client gives for it. Record the result in AGENTS.md. When the link is
      not usable, the notice ends with "Type /oooo chat to open recent
      mentions."
  - Checkpoint (**CLIENT**): account B watches `tall` and is offline.
    Account A writes "@tall hello", "nothing here", and
    "look @Tall [item link]" in guild chat. Account B logs in; after its
    pull it sees one notice. The click opens the window with `@tall` and
    `@Tall` under "Unread". A click on `@Tall` scrolls to its line,
    highlights it, and moves the entry to "Read". After a `/reload` the
    entry is still read, the other still unread, and no notice is printed.
  - Host tests (`Tests/sync_mentions.lua`)
    - A pull of several batches gives one notice, not one per batch.
    - No notice for an unread entry that does not concern the user, and
      none with an empty watch list.
    - A second sync without a new unread entry gives no second notice.
    - With `notifyOnLogin` off, the login gives no notice for old unread
      entries, and a sync that brings a new one still does.
    - The model: a click on a mention older than the loaded lines loads
      back to it and sets the highlight.
  - Done when: the client checkpoint is recorded.
- **11.5 Warning for a mention that nobody can copy** (**CLIENT**)
  - Substeps
    - In the handler of own guild chat lines (`SyncGuildChat.lua`, 10.2):
      when the text has a word that starts with `@`, the session has ended
      its discovery, and its peer list is empty, print the warning, at most
      once in 5 minutes.
    - Guard the text with `issecretvalue`; a secret line gives no warning.
  - Checkpoint (**CLIENT**): alone with the addon, "@tall test" in guild
    chat prints the warning once; with the second account online it prints
    nothing.
  - Host tests (`Tests/sync_mentions.lua`)
    - No peer and discovery done: one warning; a second mention within 5
      minutes gives none.
    - A peer online: no warning.
    - Before discovery has ended: no warning.
    - A line without `@`: no warning.
  - Done when: the client checkpoint is recorded.

## 11. Decisions taken

- Transfers between two members use hidden addon whispers; broadcasts use the
  hidden guild addon channel.
- The origin is one random constant per player, made at install.
- Alt detection through the origin is a wanted feature.
- `profession_id`, `profession_skills`, `equipment`, and `attunement` are
  written by each player for their own characters only, and anyone may pass them
  on (5.2).
- `guildchat` holds the guild chat of the last 14 days, with the original
  text. The length is fixed, not a setting. It is not real time: it serves the
  member who was offline. The sender's addon writes a line; a witness writes
  the lines of members without the addon (5.3).
- There is no `guildbank` table: the guild bank is expected as a standard
  feature of the game. With it go the officer-only tables, member relay, and
  the trust flag; no table restricts writing by guild rank for now.
- Members have no settings of the shared database. The "Sync" page with the
  send settings per table is shown, and applies, only in the developer mode;
  everybody else runs the presets of the table definitions.
