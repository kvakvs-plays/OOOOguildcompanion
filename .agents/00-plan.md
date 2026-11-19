# Plan: shared guild database

A database that every guild member with the addon holds in full and that
converges between members through addon messages. It is not realtime: data moves
in the background, when the game is quiet.

Status: stages 0 to 8 are finished (`00-finished.md`). Stage 9
is postponed. Stages 10 and 11 are finished. Stage 12 (professions: the
tables of 5.4, the scan, and the search window) is open. The probes of stage 1
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
  `profession[name][profession id]`, `recipe[recipe id]`, `equipment[name]`,
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

Out of scope for this plan: the code that scans equipment and writes its
records; it gets its own plan (stage 9). This plan delivers the engine and an
API for it. Two features are part of this plan: the table `guildchat` (5.3,
stage 10) with the chat history window and the mentions of `user-wishes.md`
(stage 11), and the professions (5.4, stage 12; added on 2026-11-19 by
decision of the user). A bridge to Discord, if it comes, gets its own plan.

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
| `profession` | name, profession id | owner | anyone |
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
  policy = { when = "nocombat", pushDelay = 60, minInterval = 60 },
})
```

- **Not real time.** An online member reads the chat in the game, so the table
  does not have to follow the chat closely. A writer collects its lines for 1
  minute and sends them in one push, at most once per minute (first 5 and
  10 minutes; shortened after the client check, where the wait looked like
  a lost line). The member
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

### 5.4 Table `profession`

Who in the guild can craft what. Every character with the addon shares the
recipes that it knows; every member can search them (stage 12). The table
replaces the earlier names `profession_id` and `profession_skills`: one
record per character and profession says both that the character has the
profession and what it knows.

**Numbers only.** The table holds ids and levels, never a name: members play
clients of different languages. Every replica turns the ids into names of its
own language when it shows or searches them.

- **Recipe id.** A recipe is named by the id of its craft spell. The item
  that it makes and its reagents are not shared: every client knows them
  (below, "No table `recipe`").
  - Why not the item id as the name: an enchant makes no item, and two
    recipes can make the same item.
- **Profession id.** The skill line id of the profession (Classic data:
  164 Blacksmithing, 165 Leatherworking, 171 Alchemy, 197 Tailoring,
  202 Engineering, 333 Enchanting, 185 Cooking, 129 First Aid, 186 Mining,
  182 Herbalism, 393 Skinning, 356 Fishing). Confirmed on Forever by step
  12.1; there are no child skill lines.

```lua
ns.sync:RegisterTable({
  name = "profession",
  schema = 1,
  keyKind = "character",              -- key "First Last:<profession id>"; roster cleanup applies (4.4)
  validate = ...,
  maxRecordBytes = 2000,              -- about 480 recipes; the largest Classic profession has about 300
  writers = "owner",
  policy = { when = "nocombat", pushDelay = 300, minInterval = 900 },
})
-- payload
{ l = 275,              -- skill level, 1 to 450 (the range is wide on purpose)
  m = 300,              -- highest level of the learned rank
  s = 9788,             -- specialization spell id; absent when none (deferred: not written yet)
  r = "....",           -- the known recipe ids, packed (below); absent for a profession without recipes
}
```

- **Packed recipe list.** `r` is the recipe ids in ascending order, each as
  4 base-94 characters (`ns.base94`, 78 million values): 300 recipes are
  1200 bytes, against about 2400 as a list of numbers. `validate` checks the
  length (a multiple of 4), the characters, and the strict ascending order,
  so one set of recipes has one text and `Put` can skip an equal scan.
  - A record can be near the size of one batch (2000 bytes). Step 12.2
    checks with a host test that `splitBatches`, a pull, and a push carry
    such a record. AceComm then sends it as a multipart message, which
    AGENTS.md lists as not yet checked in the client; step 12.3 checks it.
- **Gathering and secondary professions** get a `profession` record too
  (level only, or with the few recipes of Mining, Cooking, and First Aid).
- **Level changes.** Every skill point changes the record, and a change
  sends the whole record again. The policy collects them: one push at most
  every 15 minutes per crafter. If this proves too much traffic, the level
  moves to a record of its own.
- **No table `recipe`** (decided by step 12.1, 2026-11-19). The plan had a
  second shared table with the item and the reagents of every recipe, in
  case a client could not tell them for a recipe that its character does
  not know. The client can: right after a login, with no profession window
  opened in the session, `GetRecipeInfo` and `GetRecipeSchematic` gave the
  name, the item, and the reagents of recipes of professions that the
  character lacks (2660 and 18560). So every replica reads the facts of a
  recipe from its own client, and nothing but the id is shared.
  - `ns.professionRecipes` (step 12.5) is the one place that asks the
    client: `Facts(recipeId)` gives the name, the icon, the item made, the
    number made, and the reagents (item id and count), or nil when the
    client says that the id is no recipe (`recipeID` is not the id). The
    answers are kept in memory for the session.
  - An id that a foreign record lists and that the client does not know is
    shown as `#<id>` and has no reagents. A modified addon can list such
    ids, but it cannot give a recipe wrong reagents.
  - Checked only for two Classic recipes. If daily play shows recipes whose
    facts the client lacks until some window was open, the table comes
    back; the name is free.

**Scan.** The scanner reads the professions of the logged-in character and
writes its records. It uses the Retail API `C_TradeSkillUI`; the Classic
functions (`GetNumTradeSkills`, the `Craft` functions) do not exist on
Forever (step 12.1; the facts are in AGENTS.md).

- **The list of professions** (which, level) is readable without a window
  through `GetProfessions()`, which gave its indexes 1.5 seconds after
  `PLAYER_LOGIN`, together with the first `SPELLS_CHANGED`; and
  `GetProfessionInfo(index)`, which gives the level, the maximum, and as
  7th value the skill line id. Every non-nil value of `GetProfessions()` is
  a profession (the third was First Aid).
  - Not `C_TradeSkillUI.GetProfessionInfoBySkillLineID`: in a fresh session
    it showed no level for any profession (60 seconds after a login, and in
    the run `fresh`); it showed the levels only after a profession window
    had been open.
  - To confirm from the stored report `professions:fresh`: that
    `GetProfessionInfo(index)` gives the levels in a fresh session. The
    chat lines of that run do not show it.
  - It is read after the guild check, on `SPELLS_CHANGED` and
    `SKILL_LINES_CHANGED` (at most once in 5 seconds), and at every scan of
    a window.
- **The recipes** are readable only with the profession window open. After
  a login `GetAllRecipeIDs()` gives nothing. With a window open it gives
  the recipes of that profession; after the window closes it still gives
  them, but the client no longer says which profession they belong to. The
  scanner therefore scans only while `IsTradeSkillReady()` is true: the
  profession is `GetBaseProfessionInfo().professionID`, and the known
  recipes are the ids of `GetAllRecipeIDs()` whose `GetRecipeInfo(id)` has
  `learned == true` and `recipeID == id`. A filter in the window does not
  change `GetAllRecipeIDs()`. It scans on `TRADE_SKILL_SHOW`,
  `TRADE_SKILL_LIST_UPDATE`, and `TRADE_SKILL_DATA_SOURCE_CHANGED`. Until a
  profession with recipes has its first record the addon prints once per
  session: "Open your <profession> window once, so that the guild can see
  what you craft." The profession name comes from the client
  (`professionName`), in the user's language.
  - The scan writes only the ids. The facts of a recipe are read when
    they are shown, from `GetRecipeSchematic(id, false)`: `outputItemID`,
    `quantityMin`, and per entry of `reagentSlotSchematics`
    `reagents[1].itemID` and `quantityRequired`.
  - The addon does not open the window itself: opening it from code is not
    known to be safe (taint, protected call), and a window that opens by
    itself at login is unwanted.
- **A scan only adds.** The new recipe list is the union of the stored list
  and what the scan found. A recipe cannot be unlearned alone, and a scan
  can be partial (a filter or a search text in the window, data not loaded).
  A list that only grows cannot lose recipes to a bad scan. The whole record
  goes when the profession is unlearned.
- **Never scan foreign data.** The window can show the profession of another
  player (a chat link), of the guild, or of an NPC. The scanner writes only
  when `IsTradeSkillLinked()`, `IsTradeSkillGuild()`, and `IsNPCCrafting()`
  are all false, and when the skill line of the window is one of the
  character's professions. Each recipe must also be `learned`.
  - Step 12.1 could not open foreign data: profession links in chat cannot
    be clicked on Forever. The three functions exist and are false for the
    own window; their answer for foreign data is unchecked.
- **New recipe.** A learned recipe is added on the event that the client
  sends for it (Retail: `NEW_RECIPE_LEARNED` with the recipe id), without a
  window. If no such event is valid, the next scan finds it.
- **Specialization** is deferred (2026-11-19): no character with a
  specialization was at hand for step 12.1. The field `s` stays in the
  schema and `validate` accepts it, but the scan does not write it and the
  window does not show it until the check is done. The design, for then:
  (Armorsmith, Weaponsmith and its three, Gnomish and
  Goblin Engineering, the three of Leatherworking). Each is a spell that a
  quest teaches. The code holds the list of these spell ids per profession
  (Classic data: 9788, 9787, 17039, 17040, 17041, 20219, 20222, 10656,
  10658, 10660; to confirm) and asks the client whether the character knows
  each, at the scan and when the known spells change. A Weaponsmith with a
  second specialization stores the more specific one.
- **Unlearned profession.** When the list of professions no longer has a
  profession for which the character has a record, the record is deleted
  (a tombstone, 4.4). An empty answer of the client right after login must
  not delete anything: a delete needs two reads of the list, at least 5
  seconds apart and both after the first read that showed any skill line,
  that lack the profession.
- **Secret values.** A value of the scan that is secret ends that scan
  without a write.
- **Only the logged-in character.** The owner rule (5.2) allows nothing
  else; an alt is scanned when the user plays it.

**Search window** (stage 12). A floating window "Guild professions", opened
with `/oooo prof`; an own frame like the chat history window, its position
in `db.profile.professions`.

```
+---------------------------------------------------------------+
| Recipe: [ bag          ]     Material: [ mooncloth    ]       |
+--------------------------------------+------------------------+
| [icon] Mooncloth Bag     Tailoring   | Mooncloth Bag          |
|        Nota Scam, Other One          |  4x Bolt of Runecloth  |
| [icon] Bottomless Bag    Tailoring   |  1x Mooncloth ...      |
|        Third One                     | Known by               |
| ...                                  |  Nota Scam (online)    |
|                                      |  Other One  300        |
+--------------------------------------+------------------------+
```

- **Two search boxes.** "Recipe" finds recipes whose name has the typed
  text; "Material" finds recipes with a reagent whose name has the typed
  text. With both filled, a recipe must match both. The match is a plain
  substring (no patterns), without regard to letter case, in the language
  of the client.
  - Letter case: `string.lower` of the client handles UTF-8 (Cyrillic,
    umlauts; step 12.1), so it serves for all letters. On the host it
    changes only ASCII, so the host tests of the search use ASCII.
  - A search starts 0.3 seconds after the last key and needs 2 characters.
    With both boxes empty the list is empty and shows a hint.
- **Result list.** One row per recipe that at least one member knows: the
  icon and the name (of the item, or of the spell for an enchant), the
  profession, and the names of those who know it, online members first; a
  long list ends with "+3". At most 200 rows are shown, with a line that
  says so.
- **Detail.** A click on a row shows on the right the reagents with their
  counts and all members who know the recipe, online first, each with the
  skill level (the specialization is deferred, see the scan). Hovering the recipe shows the item
  tooltip. A shift-click puts the item link into the chat box through
  `HandleModifiedItemClick`. The window does not whisper: opening a chat
  from addon code is a protected call (AGENTS.md).
- **Names.** The name of a recipe is the `name` of `GetRecipeInfo`, which
  the client gave at once in every run. A reagent is an item, and the
  search by material needs the names of all reagents of all listed recipes.
  An id without a name is shown as `#<id>` and is found by no text.
- **Item names: asked from the client, kept for the session only** (decided
  by the `nameload` runs of step 12.1, 2026-11-19). The plan had a saved
  name cache per language with an expiry and two request paces, for fear of
  slow answers and of a disconnect. The runs showed neither:

  | Run | Named at once | Loads requested in one frame | Answered | Last answer |
  | --- | --- | --- | --- | --- |
  | 50 items | 6 | 44 | 44 (21 named, 23 failed) | 0.23 s |
  | 200 items | 5 | 195 | 195 (168 named, 27 failed) | 0.24 s |
  | 800 items | 85 | 715 | 715 (664 named, 51 failed) | 0.24 s |
  | 50 spells | 50 | 0 | - | - |

  - Every answer came with `ITEM_DATA_LOAD_RESULT`; `GET_ITEM_INFO_RECEIVED`
    never came. The client stayed connected. The item data is on the disk
    of the client; a load is no question to the server that could be
    counted against the account.
  - A failed load is an id that `C_Item.DoesItemExistByID` accepts but that
    has no data (the ids of the runs were a plain range, with many unused
    items). Such an id never gets a name.
  - `ns.professionNames` therefore keeps `item id -> name` in memory, for
    the session. `Name(itemId)` asks `C_Item.GetItemNameByID`; without an
    answer it queues one `C_Item.RequestLoadItemDataByID` (the queue is
    below) and takes the name on `ITEM_DATA_LOAD_RESULT`. A failed id is remembered and not
    asked again in the session. Nothing is saved, so there is no expiry,
    no language key, and no migration.
  - `Prepare(itemIds)` asks for many names, when the search window opens.
    It is late and spread out on purpose (wish of the user, 2026-11-19):
    at a first start many other addons load their data too, and the addon
    must not add a burst to that.
    - Nothing is requested at login. The first request waits until 10
      seconds after `PLAYER_LOGIN`, and 0.5 seconds after the window
      opens.
    - Then at most 40 requests every 0.2 seconds, so 800 names take 4
      seconds. The runs of step 12.1 sent 715 in one frame without harm,
      so this is far on the safe side.
    - A single `Name(itemId)` outside `Prepare` (a tooltip, the detail
      part) joins the same queue; it is not sent at once.
    - The window shows "Loading names: 310 of 800" until the answers are
      in, and a search runs again when names arrive (`OnNamesChanged`, at
      most one call in 0.5 seconds). The event is registered only while
      requests are open.
  - Spell names (`C_Spell.GetSpellName`) answered at once for all 50; the
    window needs them only as a fallback and asks without a cache.
- **Index.** `recipe id -> members who know it` is built from the table
  `profession` when the window opens and kept current by `OnRecordChanged`
  while it is open. A recipe id that the client does not know is listed as
  `#<id>` and has no reagents.
- **Not in this stage:** a filter by profession, a list of one member's
  recipes, alts joined to one player, and a link from the game's own
  profession window.

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
Addon\Src\Chat\Mentions.lua        @ words, the watch list, the mention list, the notice (stage 11)
Addon\Src\Chat\ChatHistory.lua     model of the chat history window                      (stage 11)
Addon\Src\Chat\ChatHistoryWindow.lua  the window, its lists of mentions, two probes      (stage 11)
Addon\Src\Professions\ProfessionData.lua    the table profession, packing, validate              (stage 12, host-testable)
Addon\Src\Professions\ProfessionScan.lua    reads the client, writes the own records, the probe  (stage 12)
Addon\Src\Professions\ProfessionRecipes.lua the facts of a recipe, from the client                (stage 12, host-loadable)
Addon\Src\Professions\ProfessionNames.lua   item names of the session, loaded on demand          (stage 12, host-loadable)
Addon\Src\Professions\ProfessionSearch.lua  index, the two searches; no frames                   (stage 12, host-loadable)
Addon\Src\Professions\ProfessionWindow.lua  the window "Guild professions"                       (stage 12)
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

Finished; see `00-finished.md`.

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
  - Done when: the plan is committed.

### Stage 10. Guild chat table

Finished; see `00-finished.md`. One observation was not made in the client
checks and is left to daily play (a line written twice); it is listed there
under "10, left to daily play".

### Stage 11. Chat history and mentions

Finished; see `00-finished.md`. The full design is in the git history of
that file (before 2026-11-19). The parts of the client checks that were not
observed are left to daily play; they are listed there under "11, left to
daily play".

### Stage 12. Professions

The design is section 5.4. Step 12.1 decides the open points of that
section; change the section and the later steps when its results differ from
what they assume. The test files are named `Tests/sync_prof*.lua` so that
`run_all.lua` finds them.

- **12.1 Probe of the profession API** (**CLIENT**)
  - Substeps
    - Add the probe `professions` (`/oooo sync probe professions`) in
      `Src\Professions\ProfessionScan.lua`. It only reads and reports.
    - Existence of functions: `GetProfessions`, `GetProfessionInfo`;
      in `C_TradeSkillUI`: `GetAllRecipeIDs`, `GetRecipeInfo`,
      `GetRecipeSchematic`, `GetRecipeItemLink`, `GetBaseProfessionInfo`,
      `GetChildProfessionInfo`, `GetProfessionInfoBySkillLineID`,
      `GetTradeSkillDisplayName`, `IsTradeSkillReady`,
      `IsTradeSkillLinked`, `IsTradeSkillGuild`, `IsNPCCrafting`,
      `OpenTradeSkill`; the Classic ones `GetNumTradeSkills`,
      `GetTradeSkillInfo`, `GetTradeSkillItemLink`,
      `GetTradeSkillRecipeLink`, `GetTradeSkillNumReagents`,
      `GetTradeSkillReagentItemLink`, `GetNumCrafts`, `GetCraftInfo`;
      for names and known spells `IsPlayerSpell`, `C_SpellBook.IsSpellKnown`,
      `C_Spell.GetSpellName`, `C_Item.GetItemNameByID`,
      `C_Item.RequestLoadItemDataByID`. These names come from Retail and
      Classic; none is confirmed on Forever.
    - Validity of events (`C_EventUtils.IsEventValid`): `TRADE_SKILL_SHOW`,
      `TRADE_SKILL_CLOSE`, `TRADE_SKILL_LIST_UPDATE`,
      `TRADE_SKILL_DATA_SOURCE_CHANGED`, `NEW_RECIPE_LEARNED`,
      `SKILL_LINES_CHANGED`, `SPELLS_CHANGED`, `CRAFT_SHOW`, `CRAFT_UPDATE`,
      `GET_ITEM_INFO_RECEIVED`, `ITEM_DATA_LOAD_RESULT`.
    - The list of professions: what it returns for the character (skill
      line ids, levels), and how many seconds after login it is first
      filled.
    - The recipes: the number of recipes and of learned ones, the id of the
      first, its item, and its reagents. Run the probe three times: after a
      login before any profession window was open, with the window open,
      and after it was closed. Run it also with a filter set in the window
      and with a linked profession of another player open.
    - A recipe that the character does not know, of a profession that it
      does not have (the id is an argument of the probe): does the client
      give its item, its reagents, and its name?
    - A specialization: `IsPlayerSpell` and `C_SpellBook.IsSpellKnown` for
      the ids of 5.4, on a character that has one.
    - `string.lower` of a text with a Cyrillic letter and an umlaut.
    - Report which values were secret.
    - A second probe, `nameload <count>`, for the name cache (5.4). It
      takes `count` item ids that the session has not touched (from a
      fixed list of Classic trade goods and crafted items in the probe),
      asks the client for each name directly, requests the load of those
      without a name all at once, and reports: how many answered at once,
      how many loads succeeded and failed, the time to the first and to
      the last answer, and which event carried the answers. Run it with
      50, 200, and 800 right after a client restart, on a test account:
      the larger runs may disconnect it, and that is the result wanted.
      The same for 50 spell ids with the spell functions.
  - State (2026-11-19): the runs `before`, `open`, `closed`, `filter`,
    `login`, `fresh`, and `nameload` are done on build 70959; their results are in
    AGENTS.md and in section 5.4. The table `recipe` is dropped. Left:
    - Read the stored report `professions:fresh` (after a `/reload`):
      does `GetProfessionInfo(index)` give the levels in a fresh session?
    - Done: the `nameload` runs (50, 200, 800 items; 50 spells); the
      saved name cache and its paces are dropped (5.4).
    - Deferred: `professions spec` on a character with a specialization,
      and with it the field `s` in the scan and in the window.
    - Not possible: the run `linked`; profession links cannot be clicked.
    - Each run of `professions <label>` keeps its own report
      `professions:<label>`. Runs to do: `professions before` (after a
      login, no window opened yet), `professions open`, `professions
      closed`, `professions filter`, `professions linked`; recipe ids after
      the label replace the three default ids (2330, 2660, 18560).
    - `professions login` arms a watch; after the next login (not
      `/reload`) the report `professions:login` says after how many seconds
      the list was first filled and which events came.
    - `nameload <count>` and `nameload 50 spells` take their ids from a
      range of Classic ids (items 2300 to 24000, spells from 2000), not from
      a list of trade goods; `C_Item.DoesItemExistByID` filters them when it
      exists. The cursor is saved (`db.global.probeCursor`), so no run
      repeats the ids of an earlier one. Reports: `nameload:items50`, ...
  - Checkpoint: the reports of the three runs, and of the `nameload` runs,
    are in `db.global.probeResults`.
  - Host tests: none; the probe has no computing part.
  - Done when: the results are in AGENTS.md under "Checked on the release
    client", the confirmed globals are in `.luacheckrc`, and section 5.4
    says which API the scan uses, whether the window must be open, whether
    the table `recipe` stays (it does not), how foreign data is told apart,
    and how names are loaded (no saved cache).

- **12.2 The table `profession`**
  - Substeps
    - `Src\Professions\ProfessionData.lua` (`ns.professionData`):
      `packRecipes(ids)` and `unpackRecipes(text)`, `mergeRecipes(text,
      ids)` (the union, for "a scan only adds"), `key(name, professionId)`
      and `parseKey(key)`, and `validate` with every check of 5.4.
    - Register the table at file scope. `validate` also checks the key: a
      name, `:`, and a profession id in digits.
    - Check the engine with a record near the batch size: `splitBatches`
      with a record of 1900 bytes and one over 2000, and a pull and a push
      of both between two replicas.
  - Checkpoint: `/oooo sync status` lists `profession` with 0 records.
  - Host tests: `Tests/sync_profdata.lua`: a round trip of the packing; the
    union; `validate` refuses a wrong length, a character outside base 94,
    a descending or repeated id, an unknown field, a fraction, a level of
    0, a key without profession id; the
    owner rule on the joined key (a name with a space); the large record.
  - Done when: the tests pass. Host only by design.

- **12.3 Scan** (**CLIENT**)
  - Substeps
    - `ProfessionScan.lua` (`ns.professionScan`): the reader of the client
      behind a small interface (`readProfessions()`, `readRecipes()`,
      `isOwnWindow()`), so that the rest runs on the host with a stub.
    - `Scan`: for each profession build the payload (level, the merged
      recipe list; the specialization is deferred, 5.4) and `Put` it. A
      scan of many recipes is cut across frames with `C_Timer.After`.
    - When it runs: the list of professions after the guild check and on
      its events (5.4); the recipes on `TRADE_SKILL_SHOW`,
      `TRADE_SKILL_LIST_UPDATE`, and `TRADE_SKILL_DATA_SOURCE_CHANGED`
      while `IsTradeSkillReady()` is true, at most once in 2 seconds. Only
      while the guild state is `in`; one event frame with a handler table.
    - The hint "Open your <profession> window once ...", once per session
      and only for a profession with recipes that has no recipe list yet.
      Which professions have recipes: the six crafting ones, Cooking,
      First Aid, and Mining.
    - `/oooo sync prof`: the stored professions of the own character with
      their recipe counts, and what the last scan did.
  - Checkpoint: on a character with two professions, after opening both
    windows, `/oooo sync prof` shows both with the recipe counts of the
    game. A second account shows the same records after its sync
    (`/oooo sync status`: equal versions of `profession`).
    The largest record arrived whole; this is the first multipart message
    seen in the client, so record it in AGENTS.md.
  - Host tests: `Tests/sync_profscan.lua` with a stub reader: a first scan
    writes the records; an equal scan writes nothing; a partial scan
    removes nothing; a scan of a foreign window writes nothing; a secret
    value ends the scan; a recipe that is not `learned` is left out.
  - Done when: the client check is recorded, with no Lua error and no
    "Interface action failed" entry.

- **12.4 Changes: new recipe, unlearning** (**CLIENT**)
  - Substeps
    - Add a learned recipe on its event (5.4).
    - Deferred with the specialization (5.4): read it again when the known
      spells change, at most once in 5 seconds.
    - Read the list of professions on its events (5.4); delete the
      records of an unlearned profession by the two-reads rule of 5.4.
  - Checkpoint: learn a recipe from a trainer: the count in
    `/oooo sync prof` rises by one without a `/reload`, and the second
    account gets it. Unlearn a profession on a test character: its record
    is gone on both accounts after the sync.
  - Host tests: in `Tests/sync_profscan.lua`: the new-recipe event adds one
    id; an empty list right after login deletes nothing; one read without
    the profession deletes nothing, the second one deletes; a profession
    that is learned again starts with an empty list.
  - Done when: the client check is recorded.

- **12.5 Recipe facts and item names** (**CLIENT**)
  - Substeps
    - `Src\Professions\ProfessionRecipes.lua` (`ns.professionRecipes`):
      `Facts(recipeId)` of 5.4, with the client behind a small interface
      so that the file runs on the host.
    - `Src\Professions\ProfessionNames.lua` (`ns.professionNames`), by the
      design of 5.4: `Name(itemId)`, `Prepare(itemIds)`, `Progress()`
      (named, total), and the callback `OnNamesChanged`. The client is
      behind a small interface (`nameOf(id)`, `request(id)`, the callback
      for an answer) and the timer is a parameter, so the file runs on the
      host. Nothing is saved.
    - `/oooo sync prof names`: the counts of named, failed, and open ids.
  - Checkpoint: after a client restart, `/oooo prof` (step 12.7) shows the
    reagent names after the line "Loading names" has counted up for some
    seconds, and `/oooo sync prof names` shows no
    open id. Until 12.7 exists: `/oooo sync prof names` after
    `/oooo sync prof` has prepared the reagents of the own recipes.
  - Host tests: `Tests/sync_profnames.lua` with a stub client and the
    fake clock: a direct answer costs no request; an id is requested once;
    an answer gives the name and one `OnNamesChanged` for many answers; a
    failed id is not asked again; nothing is requested before 10 seconds after the
    login; `Prepare` of 500 ids sends at most 40 requests in every 0.2
    seconds; a single `Name` waits in the same queue; `Facts` of a recipe gives item, count, and
    reagents; `Facts` of an id that is no recipe gives nil; a secret value
    gives nil.
  - Done when: the client check is recorded.

- **12.6 Search model**
  - Substeps
    - `Src\Professions\ProfessionSearch.lua` (`ns.professionSearch`), no
      frames: the index `recipe id -> crafters` from the table
      `profession`, kept current by `OnRecordChanged` while it is in use.
    - The names come from `ns.professionNames` (12.5); the lower-case
      forms are built here, and again for the names of an
      `OnNamesChanged`.
    - `Search(recipeText, materialText)`: the rows in the order of the
      names, each with the recipe id, the item, the profession, and the
      crafters (online first, by the roster cache of `ns.guildState`),
      cut at 200 with a flag. `Detail(recipeId)`: reagents and crafters
      with level.
    - The lower-case function is one local helper, so that the result of
      step 12.1 on UTF-8 changes one place.
  - Checkpoint: none in the game; the window of 12.7 shows it.
  - Host tests: `Tests/sync_profsearch.lua` with a stub name source: a
    search by recipe name, by material, by both; letter case; a text with
    pattern characters (`%`, `(`, `-`) is taken literally; fewer than 2
    characters give nothing; a name that arrives later makes its recipe
    findable; a recipe id that the client does not know is found by no
    text; a tombstone and an unlearned profession leave
    the index; a new remote record enters it; the cut at 200.
  - Done when: the tests pass. Host only by design.

- **12.7 Window "Guild professions"** (**CLIENT**)
  - Substeps
    - `Src\Professions\ProfessionWindow.lua` (`ns.professionWindow`): the
      frame of 5.4 with `BackdropTemplate`, the two edit boxes, the result
      rows (own rows with a mouse-wheel offset, like the mention lists of
      the chat history window), the detail part, the line "Loading
      names: ...", Escape closes it (`UISpecialFrames`), the position in
      `db.profile.professions`. Showing the window prepares the item
      names of all listed recipes (`ns.professionNames:Prepare`).
    - `/oooo prof` opens and closes it.
    - The item tooltip on hover; shift-click through
      `HandleModifiedItemClick`.
    - The window can open in combat: it is no protected frame and calls
      no protected function.
    - An entry in `CHANGELOG.md`, and the files in `toc_template.toc` and
      the project map.
  - Checkpoint: with the records of two accounts: a part of an item name
    in "Recipe" lists the recipe with both names; a material in
    "Material" lists the recipes that use it; both boxes narrow the list;
    a click shows reagents and crafters; the online member is listed
    first. On a client of another language, if a member has one, the same
    recipe is found by its name in that language.
  - Host tests: none new; the model is tested in 12.6.
  - Done when: the client check is recorded, with no Lua error and no
    "Interface action failed" entry.

## 11. Decisions taken

- Transfers between two members use hidden addon whispers; broadcasts use the
  hidden guild addon channel.
- The origin is one random constant per player, made at install.
- Alt detection through the origin is a wanted feature.
- `profession`, `equipment`, and `attunement` are written by each player for
  their own characters only, and anyone may pass them on (5.2). 
- Professions are part of this plan (2026-11-19). The shared data holds ids
  and counts only; every client names them in its own language. A recipe is
  named by its craft spell id; its item and its reagents come from each
  client, not from the shared data (5.4, no table `recipe`).
  A scan only adds recipes; unlearning the profession deletes its record.
- Names of items are asked from the client and kept for the session only:
  800 names loaded in a quarter of a second, without a disconnect. They are
  still requested late and spread over some seconds, because other addons
  load their data at a first start too (5.4).
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
