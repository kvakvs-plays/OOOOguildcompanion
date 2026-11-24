# Design of the shared guild database

The design of what is built: the sync engine and the features on it (guild
chat, mentions, professions). It was sections 1 to 8 and 11 of `00-plan.md`
until 2026-11-21 and keeps their numbers. A code comment that says "plan
section N" or "00-plan.md, section N" with N from 1 to 11 means this file.

Change this file when the built engine changes. The open work is in
`00-plan.md`, whose sections are numbered from 12. The history of the steps
is in `00-finished.md`; client facts are in `AGENTS.md`. This file holds the
rules and their reasons, not constants that the code names or facts that
`AGENTS.md` lists.

## 1. Goals and limits

- Each member holds a full copy, stored in the account-wide saved variables.
- The database has named **tables**. Every record carries a version id, and
  every table a table version, so two members can tell with one short message
  whether their copies of a table differ.
- A member who logs in finds the other members, compares table versions, and
  fetches only the records that they lack, from the member with the most
  recent data.
- A local change is shared later, by a per-table policy (out of combat, out
  of raid, or only when resting).
- Messages from other members are untrusted input.

Built on the engine: the table `guildchat` (5.3) with the chat history window
and the mentions, the professions (5.4), and the protected tables (5.5). The
scan of equipment gets its own plan.

Not planned: a guild bank table (the guild bank is expected as a standard
feature of the game), and officer tables with member relay and a trust flag
(the old design is in the git history of this file; 5.5 replaced it).

## 2. Terms

| Term | Meaning |
| --- | --- |
| Replica | One installed copy of the database: one player's account-wide saved variables. |
| Origin | A 4-character id of the player (not the character) who wrote a record. It is characters 6 to 9 of every version id. In a self table it is the character origin instead: one per install and character (5.5). |
| Record | `key -> { v = versionId, d = payload }` inside a table. |
| Clock | Per table: `origin -> greatest version id received from that origin`. |
| Table version | `maxId .. fingerprint`, 16 characters. See 4.3. |
| Peer | An online guild member whose addon has announced itself. |

## 3. Version id

An 11-character string over the 94 printable ASCII characters `!` (33) to `~`
(126). A plain `<` on two ids gives their order in time.

```
TTTTT OOOO RR
|     |    +-- small random; +1 for each id made in the same second
|     +------- origin: random, made once at install and stored
+------------- timestamp in seconds, big-endian base 94 (until the year 2202)
```

- **Requirement: ids are strongly ordered by time.** Three rules give this:
  - Time comes from `GetServerTime()`, so the local PC clock does not matter.
    The server clocks of all members are assumed to be close; a small
    difference only decides which of two near writes wins.
  - Within one replica: in the same second the random part is the previous
    one plus 1 (on overflow the timestamp moves 1 second ahead); otherwise it
    is a random value in the lower half of the range.
  - Across replicas: a new id must be greater than the `maxId` of its table.
    If the current second does not give that, the timestamp is `maxId`'s
    second plus 1. A new write is always newer than all that the replica has
    seen.
- Two ids of one second from replicas that do not know of each other are
  ordered by origin: arbitrary, but the same for everybody.
- The origin is stored in `db.global.sync.origin` and never changes. The
  saved variables are account-wide, so all characters of the player share it;
  this makes alt detection possible (5.1).
  - A deleted saved variables file gives a new origin; the old records stay
    valid. A second computer gets its own origin.
  - Do not copy the file between computers that are both in use: two replicas
    with one origin break the clock rule of 4.2.
- The hash is an arithmetic-only 32-bit string hash. It must not use the
  `bit` library, so that the same file runs in the host tests on Lua 5.4.
- A received id is valid when it has length 11, every byte in 33 to 126, and
  a timestamp not more than 5 minutes ahead of `GetServerTime()`. A record
  with an invalid id is dropped.
- Costs of base 94: AceSerializer escapes `^` and `~` (2 bytes each on the
  wire), and `|` must be written as `||` before an id is printed to chat.

## 4. Data model

### 4.1 Storage

In AceDB `global` (one copy per account). `migrate` in `Src\Database.lua`
creates the empty structure.

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
      pushed = "<id>",            -- push mark: the last pushed write of the install origin (7.3)
      pushedBy = { ["xY1#"] = "<id>" },  -- push marks of the character origins of a self table (5.5)
      freshAt = 1795000000,       -- server time of the last contact, see 4.4
      records = {
        ["Charname"] = { v = "<id>", d = { ... } },
        ["Gone"] = { v = "<id>", x = true },   -- tombstone
      },
    },
  },
}
```

- Keys are flat strings. A nested section uses a joined key (`"Name:id"`);
  the table definition owns the join and split. A character name has a space,
  so a key is never split on whitespace.
- Prefer coarse records: every record pays 11 bytes of id plus its key.

### 4.2 Merge rule and the clock

- **Last writer wins per key**: a received record replaces the local one when
  its id is greater. The clock is updated for every received record, also for
  one that lost.
- **Invariant**: when the clock of a replica covers the latest write of a key
  (`clock[origin] >= id` of that write), the replica holds that write. A
  replica that lacks it therefore shows a gap in its clock, and a pull closes
  it.
- To keep the invariant, records always travel **sorted by id, ascending**,
  and a batch is applied whole. A transfer that stops halfway leaves a valid,
  shorter state.
- A stronger rule does not hold: "the replica holds every write of `O` up to
  `clock[O]`, or a newer one for the same key". A cut transfer can deliver a
  later write of `O` and not yet the write of another origin that replaced an
  earlier one of `O`. The gap then shows in the clock of the other origin.
- **Clock rest.** A write that was replaced by another origin leaves no
  record, so no record carries its clock value. The last batch of a pull
  therefore also carries the entries of the responder's clock that the
  requester still lacks (`SyncStore.clockRest`). The requester takes them
  only when it applied every batch and dropped no record. Without this, two
  replicas with equal data could keep different clocks and pull from each
  other without end.
- No planned table has a key that two players write, so last writer wins
  never decides between two players (only the `debug` table allows it). One
  player with two installs can write one key under two origins, one after the
  other; the clock rest is needed for that case.
- Why a clock and not one "newer than X" mark per table: a replica can hold a
  new record of origin A and still lack an older one of origin B. A single
  mark would skip B's record forever.

### 4.3 Table version

`tableVersion = maxId .. base94(fp, 5)`, 16 characters.

- `fp` is the sum, modulo 2^32, of `hash(id)` over all ids in the clock. It
  is updated in place when one entry changes and does not depend on order.
- Equal fingerprints mean equal clocks, and replicas with equal clocks hold
  the same data. Different fingerprints mean that one side lacks a record or
  a clock entry, and a pull settles it.
- `maxId` tells which side has the most recent write; it picks the source.
- The fingerprint covers the clock, not the records, so local cleanup (4.4)
  never makes two tables look different.

### 4.4 Deletes and cleanup

- A delete is a tombstone record (`x = true`) with a new id. It spreads like
  any record. Tombstones older than 90 days are removed locally.
- **Stale table.** A replica whose last contact for a table (`freshAt`) is
  older than 60 days empties the table and its clock before its next pull, so
  that it cannot keep records whose tombstones are gone.
  - `freshAt` is set by a completed pull, by a peer that announces a table
    version that the replica holds, by the emptying, and by the first records
    from others. The time of the last pull alone would not do: a replica in a
    healthy guild gets everything by push and never pulls.
  - A table that never had contact holds only own writes and is not emptied.
  - Until its pull, a stale table refuses pull requests with `B` `busy`.
  - The reset also removes unsent own writes; a feature that scans again
    writes them again. Two replicas that both return after 60 days lose what
    only they held.
- **Roster cleanup.** For a table keyed by character name, each replica drops
  the records of characters that are no longer in the guild. It sends
  nothing. It runs once per stay in the guild, after discovery, and only when
  the roster cache is complete (`guildState:IsRosterComplete`): every index
  gave an entry, none was secret, the own character is in it, and offline
  members were shown.
- **`maxAge`.** A table with `maxAge` drops records whose id is older than
  that age, at login and once per hour. It sends nothing and leaves the clock
  and `fp` as they are, so replicas with equal clocks may hold different
  numbers of old records.

### 4.5 Gaps below the clock

`SyncGaps.lua`, built on 2026-11-22 after guild chat showed holes between
members who were both online.

The clock tells what a table has **seen**, not what it **holds**. The engine
keeps both the same (4.2), but the outside can break it: the client writes
the saved variables at a logout and a `/reload`, not at a crash. The replica
then starts with an older file, and one own write lifts the clock entry of
the own origin over the lost ones. The table version then equals that of the
others, and no pull runs. A defect that stores a clock value without its
record has the same effect.

A table with `gapCheckHours` (48 for `guildchat`) therefore also compares the
records themselves, by their ids, for the last hours. The hours must lie
inside `maxAge`, and a protected table cannot have the check (a fill is taken
from any member).

- **Counts** (`C`, GUILD). Per hour of the record ids: the count and a
  checksum of the ids, 4 characters per hour, so 48 hours fit into one
  message part. The checksum tells apart two replicas with the same number of
  different records.
  - Only hours before a cut 20 minutes ago are counted: a younger record can
    still be on its way by push, summary, and pull.
  - The counts go out some minutes after discovery and then about every 20
    to 30 minutes. A replica that has heard its own counts from a peer skips
    its turn.
  - Nothing is sent or compared while the table may not send, or while a pull
    of it runs or is due: what the clock shows as missing is the work of the
    pull.
- **Comparing.** For an hour that differs: when the sender holds as many
  records or more, the receiver notes a want for that hour. When the sender
  holds fewer, the receiver sends its own counts after a short random wait
  (unless another peer sends the same first), so that the sender asks.
- **Gap request** (`G`, WHISPER), one at a time: a time range inside one
  settled hour and the ids that the requester holds in it. A requester with
  more than 200 ids in the range halves it first.
- **Fill** (`F`, WHISPER). The responder sends the records of the range that
  the requester did not name, as one batch.
  - **Halving.** When they are more than one batch, the responder refuses
    with `B` `split`; the requester halves the range and asks for both
    halves, until an answer is one batch. Every exchange stays short, and a
    lost message costs one small request. Only the records of a single second
    come as several batches.
  - The ids of the request also show the responder its own holes; it then
    asks the requester in turn for the same hour.
- **A fill never moves the clock.** A received record is stored only when it
  lies in the range that was asked for, passes the checks of a pulled record,
  and its id is at or below the clock value of its origin. Taking a record
  above the clock would lift the clock over writes that may be missing, which
  is the defect that the check repairs. So `clock`, `fp`, and the table
  version do not change, nothing is announced, and a bad record stops no
  other. "OnRecordChanged" fires as for a pulled record.
- **Limits.** A request is tried at most twice per table, hour, and state of
  that hour on the other side, so a difference that cannot be closed is not
  asked for again and again. A peer that does not answer 3 times in a row is
  left alone for the session. A busy responder refuses with `B` `busy`, and
  the hour waits.
- **Older addons.** The protocol version stays 1. An older addon drops `C`,
  `G`, and `F` as unknown types and never sends counts, so it is never asked.
- **What it cannot repair:** a line that no replica wrote (5.3), and a hole
  older than `gapCheckHours`.
- `/oooo sync gaps` sends the counts at once; `/oooo sync status` shows the
  numbers of the session.

## 5. Table definitions and API

`Src\Sync\SyncTables.lua` holds a registry. A feature module registers its
table at file scope:

```lua
ns.sync:RegisterTable({
  name = "equipment",
  schema = 1,
  keyKind = "character",              -- or "free"; "character" enables the roster cleanup and key checks
  validate = function(key, payload) ... end,  -- returns boolean; rejects wrong types and ranges
  maxRecordBytes = 2000,
  writers = "owner",                  -- "owner": a player writes only records of their own characters (5.2)
                                      -- "anyone": every member writes every key
                                      -- "officer": only an officer writes; keyKind "free" (5.5)
                                      -- "self": only the character that the key names; keyKind "character" (5.5)
  policy = { when = "nocombat", pushDelay = 300, minInterval = 600 },   -- 7.4
  maxAge = 14 * 86400,                -- optional: records older than this are not kept (4.4)
  gapCheckHours = 48,                 -- optional: compare the records of the last hours themselves (4.5)
})
```

API for feature modules:

- `ns.sync:Put(tableName, key, payload)` writes a record with a new id and
  marks the table dirty. It skips the write when the payload equals the
  stored one, so a repeated scan sends nothing.
- `ns.sync:Delete(tableName, key)`, `ns.sync:Get(tableName, key)`,
  `ns.sync:Iterate(tableName)`, `ns.sync:GetId(tableName, key)`.
- `ns.sync:Append(tableName, payload)` makes an id and stores the record
  under it as its key (5.3). `ns.sync:NewId(tableName)` gives a fresh id for
  a key that must be unique. `ns.sync:OriginFor(tableName)` is the one place
  that decides the origin of a local write (5.5).
- `ns.sync.RegisterCallback(owner, "OnRecordChanged", fn)` fires for local
  and remote changes as `fn(event, tableName, key, payload, isRemote,
  firstHand)`. `firstHand` is true for a local write, and for a record of a
  self table from a push of the character that the key names (5.5).

### 5.1 Built-in table `character` and alt detection

- Key: character name. Payload: class, level, and other small facts. Each
  character writes its own record at login when the payload has changed.
- The origin in the record's id is the player, so characters whose records
  have the same origin are alts. `ns.sync:GetAlts(name)` returns them.
  Showing alts to all members is intended.
- A player with two installs has two origins. A record keeps only the id of
  its last writer, so the payload carries `origins`, the list of all origins
  that have written the character, and the alt query joins origins that share
  a character.

### 5.2 Planned tables and write rules

| Table | Key | `writers` | Who may be a source |
| --- | --- | --- | --- |
| `character` | name | owner | anyone |
| `profession` | name, profession id | owner | anyone |
| `equipment` | name | owner | anyone |
| `attunement` | name | owner | anyone |
| `guildchat` | the record's own id | anyone; by rule the sender, or one witness (5.3) | anyone |
| `debugofficer` | free (developer mode) | officer (5.5) | an officer |
| `debugself` | name (developer mode) | self (5.5) | an officer |

Rules for `writers = "owner"`:

- The key starts with a character name. `Put` and `Delete` succeed only when
  that name is the character that is logged in.
- Any member may pass the records on: every peer is a valid source.
- Check on receive: in a push of local changes, each key must name the sender
  or a character that the `character` table lists under the same origin. A
  record that fails is dropped by the rule of section 8.
  - A push can carry an unsent write of an alt. A receiver that does not yet
    hold the `character` records of both drops it; the pull that follows
    brings it.
  - The first `character` record of a name is accepted in a push only from
    that name itself.
- Records that arrive through a third member cannot be checked this way. This
  is the accepted risk of section 8.

The rules for `"officer"` and `"self"` are in 5.5.

### 5.3 Table `guildchat`

A copy of the guild chat of the last 14 days (`KEEP_DAYS` in
`SyncGuildChat.lua`; `maxAge`, the same for everybody, not a setting). Its
purpose is the time in which a member was offline. Officer chat is not
recorded. `writers = "anyone"`, `keyKind = "free"`, `gapCheckHours = 48`.

- **Not real time.** A writer collects its lines for 1 minute and sends them
  in one push. The member who logs in pulls what is missing; that is the path
  that matters. A member who writes a line and logs out before the push keeps
  that line alone until the next login.
- **Record.** One chat line is one record, written once and never changed.
  Payload: `{ s = sender name, t = text }`. `t` is the text of the
  `CHAT_MSG_GUILD` event, with links and escape sequences. The time of the
  line is the timestamp in the record id.
- **Key and order.** The key is the record's own id (`Append`), so sorting
  the keys gives the order of time. Two lines of one second from different
  writers are ordered by origin, and an id can be up to 5 minutes ahead of
  the real time (section 3).
- **Who writes a line.** The game gives a line no id that all clients share,
  so exactly one replica writes it:
  - The sender's addon writes its own lines.
  - A line of a member who is not a peer is written by the **witness**: the
    replica whose character name is the first in byte order among itself and
    its online peers.
  - Replicas can disagree for a short time about who is a peer. Then a line
    is written twice or not at all. Twice is repaired on reading: records
    with the same sender and text within 3 minutes count as one line. A lost
    line is accepted.
  - A replica is not a witness before its first discovery is complete (7.1
    step 5); it would write every line that it hears.
  - **A peer list without holes.** A replica whose tables equal those of the
    others gets no summary as answer to its hello, and would take itself for
    the witness. So every peer answers a hello with the whisper `A` "here"
    (7.1 step 4).
  - Every other replica gets the line through push and pull, and does not
    store what it hears.
- **No gap after login.** A member who logs in can hear a push, write a line,
  or act as witness before the first pull. Three rules keep the replica from
  believing that it is up to date, and no "newest line that I hold" mark may
  replace them:
  - What a replica lacks is decided per origin, by the clock (4.2).
  - A pushed record is applied only when the own clock for its origin is at
    or beyond the `base` of the push (6.1). Otherwise the replica ignores it
    and schedules a pull. It never stores a late line with a hole before it.
  - An own line raises only the clock entry of the own origin.
- **Holes** below the clock are found and filled by the gap check (4.5). A
  line is written once, so two replicas hold the same lines of a settled
  hour, or one of them has a hole.
- **Secret values.** A line with a secret sender or text is not recorded.
- **Retention.** On receive, a record older than `maxAge` is not stored but
  still raises the clock (verdict `"seen"`, section 8). All replicas keep the
  same length, so a pull request needs no lower limit.
- **Trust.** A member with a modified addon can write a line under any sender
  name. A reader can tell the sender's own write from a witness write by the
  origin in the id (5.1).
- **Size.** Assumed: 1000 lines per day at about 90 bytes is about 90 KB per
  day; the first pull of a new member (14 days) is about 80 minutes of
  background traffic, and a cut pull goes on where it stopped. LibDeflate and
  a shorter key are the first savings.

### 5.4 Table `profession`

Who in the guild can craft what. One record per character and profession
(key `"First Last:<profession id>"`, `writers = "owner"`). The API facts of
professions on Forever are in `AGENTS.md`.

- **Numbers only.** The table holds ids and levels, never a name: members
  play clients of different languages. Every replica names the ids in its own
  language.
- **Payload:** `{ l = level, m = maximum, s = specialization spell id, r =
  recipes }`. The profession id is the skill line id. A recipe is named by
  the id of its craft spell (an enchant makes no item, and two recipes can
  make the same item).
- **Packed recipe list.** `r` is the recipe ids in ascending order, each as 4
  base-94 characters. `validate` checks the length, the characters, and the
  strict order, so one set of recipes has one text and `Put` can skip an
  equal scan. A record can be near the size of one batch.
- Gathering and secondary professions get a record too.
- Every skill point changes the record and sends it whole. The policy
  collects them: one push at most every 15 minutes per crafter.
- **No table `recipe`.** The client gives the name, the item, and the
  reagents of any recipe, also of a profession that the character lacks. So
  nothing but the id is shared. `ns.professionRecipes` is the one place that
  asks the client (`Facts(recipeId)`, kept for the session). An id that the
  client does not know is shown as `#<id>`; a modified addon can list such
  ids but cannot give a recipe wrong reagents.

**Scan** (`ProfessionScan.lua`), of the logged-in character only:

- **The list of professions** and their levels come from `GetProfessions()`
  and `GetProfessionInfo(index)`, without a window; not from
  `GetProfessionInfoBySkillLineID`, which shows no levels in a fresh session.
  Not yet confirmed: that `GetProfessionInfo(index)` gives the levels in a
  fresh session.
- **The recipes** are readable only with the profession window open, and only
  then does the client say which profession they belong to. The scanner scans
  while `IsTradeSkillReady()` is true and takes the recipes that are
  `learned`. Until a profession has its first record the addon asks once per
  session to open the window. It does not open the window itself: that is not
  known to be safe, and unwanted at login.
- **A scan only adds.** The new list is the union of the stored list and the
  scan: a scan can be partial, and a recipe cannot be unlearned alone.
- **Never scan foreign data.** The scanner writes only when the window shows
  neither a linked, a guild, nor an NPC profession, and its skill line is one
  of the character's. How the client answers for foreign data is unchecked.
- A new recipe is added on `NEW_RECIPE_LEARNED`, without a window.
- **Unlearned profession.** The record is deleted (a tombstone) only after
  two reads of the list, at least 5 seconds apart and both after the first
  read that showed any skill line, lack the profession. An empty answer right
  after login must not delete anything.
- **Specialization** is deferred: `validate` accepts `s`, but the scan does
  not write it and the window does not show it.
- A secret value ends the scan without a write.

**Search window** "Guild professions" (`/oooo prof`):

- Two search boxes: "Recipe" matches the recipe name, "Material" the name of
  a reagent; with both filled, a recipe must match both. Plain substring,
  without regard to letter case, in the language of the client.
- One row per recipe that a member knows, with those who know it, online
  first. A click shows the reagents and all members with their skill level. A
  shift-click puts the item link into the chat box through
  `HandleModifiedItemClick`. The window does not whisper (a protected call).
- **Item names** are asked from the client and kept for the session only
  (`ns.professionNames`): the client answers hundreds of loads within a
  quarter of a second, so nothing is saved. A failed id is not asked again.
  The requests are still late and spread out on purpose (wish of the user):
  nothing at login, and a paced queue when the window opens, because other
  addons load their data at a first start too. An id without a name is shown
  as `#<id>` and is found by no text.
- **Index.** `recipe id -> members who know it` is built from the table when
  the window opens and kept current by `OnRecordChanged` while it is open.
- Not built: a filter by profession, a list of one member's recipes, alts
  joined to one player, a link from the game's profession window.

### 5.5 Protected tables

A table with `writers = "officer"` or `"self"` is protected: its records are
taken only from what an officer sends. An officer is a character whose roster
rank index is in `ns.OFFICER_RANKS` (0 and 1), read when a message arrives.
Nothing inside a message proves a writer: only the sender name and its rank
do. The other tables keep every rule of sections 5 to 8.

Officer tables (`keyKind = "free"`, so that the roster cleanup removes
nothing that an officer stands for):

- **Write.** `Put`, `Delete`, and `Append` work only for an officer
  character.
- **Push.** A member pushes nothing, neither own writes nor the wants after a
  pull. Unsent writes of an officer character wait until that character logs
  in.
- **Receive.** A push of a member is ignored whole: no record, no clock
  entry, no pull.
- **Sources.** Only an officer peer is the source of a pull. A member refuses
  a pull request with `B` `source`. A delta from a sender that is no officer
  at its arrival is ignored.
- **Announced versions.** A version that a member announces schedules no
  pull. An officer's answer to a hello and its periodic summary are not held
  back by a member's announcement of the same version.

Self tables (`keyKind = "character"`) follow the same rules for sources,
deltas, and announced versions, and:

- `Put` and `Delete` work only for a key that names the logged-in character;
  an alt does not count. `Append` is refused.
- A push of an officer is applied whole. Of a push of a member only the
  records whose key names the sender are applied, first hand; any other
  record is dropped with the later records of its origin, and the member's
  clock rest is ignored.
- A member pushes only the records of its character origin whose key names
  its character.
- **First hand** (`firstHand` of "OnRecordChanged"): a local write, or a
  record from a push of the character that the key names. A record from an
  officer is vouched, not first hand, unless the key names that officer.
- A member can hold a first-hand record that no online officer holds; its
  version then differs from the officers'. The rule that a merged version is
  not pulled again (7.2 step 5) keeps this from causing repeated pulls. The
  delivery of 7.3 brings the record to the officers.

**Character origins.** The local writes of a self table carry the character
origin, a hash of the install origin and the character name
(`sync:OriginFor`). A clock value covers every write of its origin (4.2):
with one origin per install, an unsent write of an alt would lie below a
clock value that the others already hold, and no pull would fetch it. With
one origin per character it waits under its own clock entry until that alt
logs in.

- There is one id generator and one push mark per origin (`tbl.pushed` for
  the install origin, `tbl.pushedBy[origin]` for a character origin).
- While the name of the character is unknown, a write into a self table
  gives `nil, "not ready"`.
- Nothing checks that an origin belongs to a name: a modified addon can write
  under its own name with the origin of another character and delay that
  character's writes for up to 5 minutes.

**Limits.** Officers are trusted; an officer with a modified addon can write
anything. Without an officer online a protected table does not spread.

## 6. Transport

- `AceComm-3.0` (with ChatThrottleLib) and `AceSerializer-3.0`, one prefix:
  `OOOO`.
- Every message is `AceSerializer:Serialize(protocolVersion, type, ...)`. A
  receiver ignores a message with a greater protocol version and tells the
  user once that a newer addon version exists. An unknown type is dropped.
- `GUILD` carries what everybody needs (hello, summary, push, counts);
  `WHISPER` carries an exchange between two members. Both are hidden addon
  messages.
  - A whisper to a player who has just gone offline prints a system line.
    Whisper only to peers that the roster shows online, and hide that line
    for a few seconds after a send with a `CHAT_MSG_SYSTEM` filter, guarded
    by `issecretvalue`.
- The progress callback of `SendCommMessage` tells when a batch has left the
  queue; the next batch is sent only then.
- All sends use the priority `BULK`, except hello, summary, and "here"
  (`NORMAL`). The transport keeps `NORMAL` only for a text of one addon
  message (255 bytes); a longer text always goes as `BULK`. ChatThrottleLib
  sends from the queues of all priorities in turn, and AceComm joins the parts
  of a text in one buffer per sender and channel, so parts of two texts of
  different priorities arrive mixed and both texts are lost (reproduced with
  the real libraries in `Tests/sync_acecomm.lua`). A hello or summary of many
  tables therefore waits behind the pushes in the queue.
- A whisper from a name that is not in the roster cache is ignored. Names
  have no realm suffix; a character name is the first and the last name
  joined by a space and is never split on whitespace.
- Speed: a burst of 10 messages of 255 bytes, then about one per second. The
  raw API drops a throttled message, so ChatThrottleLib must queue. A full
  copy of 150 KB takes about 10 minutes of background work.

### 6.1 Messages

| Type | Channel | Fields | Purpose |
| --- | --- | --- | --- |
| `H` hello | GUILD | `{ table -> tableVersion }` | Sent once after login. Asks peers to answer. |
| `S` summary | GUILD | `{ table -> tableVersion }` | Answer to hello, and notice after a merge. |
| `Q` pull request | WHISPER | table, schema, nonce, digest | Digest is the clock as one string of 11-char ids. |
| `D` delta | WHISPER | table, nonce, batch number, last flag, records, clock rest, wants, optional number of batches | Records the requester lacks, ascending. The number of batches feeds the progress in the window's status line; an older addon neither sends nor reads it. |
| `P` push | GUILD | table, schema, table version, version before, own flag, base, records, clock rest | New records for everybody. |
| `B` busy | WHISPER | table, nonce, reason, retry seconds | Refusal of a pull or gap request: busy, unknown table, other schema, `source` (5.5), or `split` (4.5). |
| `A` here | WHISPER | none | Answer to a hello: the sender has the addon. |
| `K` held | WHISPER | table, origin, id | An officer tells a member up to which id it holds the member's writes in a self table (7.3). Ignored from a non-officer. |
| `C` counts | GUILD | table, cut time, counts | The records per hour of a table with `gapCheckHours` (4.5). |
| `G` gap request | WHISPER | table, schema, nonce, from, to, ids | A time range and the ids that the sender holds in it (4.5). |
| `F` fill | WHISPER | table, nonce, batch number, last flag, records | The records of the range that the requester did not name (4.5). |

- A record on the wire is `key, id, payload`, or `key, id` with a tombstone
  marker.
- `clock rest` (last delta batch, and a push) is `origin -> id` for the
  clock entries that no sent record carries (4.2). A receiver takes an entry
  only when it has no gap for that origin and dropped no record.
- `wants` (last delta batch) lists the origins for which the requester is
  ahead, with the responder's clock value for each. The requester then pushes
  those records to the guild (7.3).
- `base` in a push is `origin -> id before the first pushed record of that
  origin`. A receiver applies the records of an origin only when its own
  clock for that origin is at or beyond the base. Otherwise it has a gap,
  ignores those records, and schedules a pull.
- A push that does not fit into one batch travels as several `P`. The base of
  each is the last id of the one before, so a receiver that misses one
  ignores the rest of the chain.
- `own flag` is true for the sender's own new writes and false for records
  that it passes on after a pull.
- `table version` in a push is the sender's. A receiver whose version still
  differs after the push schedules a pull.
- `version before` is the sender's table version without the pushed records.
  A receiver that holds it, now or earlier in the session, and takes the
  whole push then holds the sender's version, also when another push has made
  its own version a third one.
- A table with a different `schema` on the two sides is not synchronized.
  Unknown table names are ignored.

## 7. Flows

### 7.1 Start and discovery

1. Sync starts only after the guild check passes (the shared guild-state
   module).
2. Request the roster once and keep a cache of `name -> online` from
   `GUILD_ROSTER_UPDATE`. It gives the valid senders and tells when a peer
   goes offline.
3. After a random 20 to 40 seconds, and when the conditions (7.4) allow, send
   `H`.
4. A peer that receives `H` answers with `S` for the tables whose version
   differs, after a random 1 to 8 seconds, and drops a table that another
   peer has announced with the same version in that time. A hundred peers in
   one state give one answer.
   - Every peer also whispers `A` to the sender of the hello, so that the
     sender knows all peers (5.3). The whisper is left out when the peer
     sends a guild message in that time, or has whispered that member within
     the last 15 seconds.
   - That interval must stay below 20 seconds, the shortest time between a
     login and its hello: a hello always comes from a replica that has
     forgotten every earlier whisper.
5. The new member collects answers for 10 seconds, counted from the moment at
   which its hello has left the send queue. The roster alone cannot tell who
   has the addon; the answers can.

### 7.2 Pull

1. For each table, take the peers whose fingerprint differs from the local
   one and choose the one with the greatest `maxId`. For a protected table
   only officer peers count (5.5).
2. Send `Q` with the digest. One pull runs at a time; the other tables wait.
3. The responder selects, for each origin, its records with an id greater
   than the digest value, sorts them by id, and sends them in `D` batches of
   about 2 KB. A large selection is cut across frames.
4. The requester validates and applies each batch, then stores the new clock,
   `maxId`, and `fp`.
5. After the last batch, when no record was dropped, the requester merges the
   clock rest (4.2) and marks the responder's fingerprint as merged. Peers
   with a merged fingerprint are skipped. If other peers still differ, the
   next one is taken.
6. No batch for 60 seconds, or a peer that goes offline, ends the pull. The
   applied batches stay, and the table returns to the queue with another
   peer.
7. A responder serves one pull at a time and answers further requests with
   `B` and a retry time.

### 7.3 Push

Two sources of a push, one message type:

- **Local changes.** `Put` marks the table dirty. When `pushDelay` has passed
  since the first unsent change, `minInterval` since the last push of the
  table, and the conditions allow, the replica sends its own new records,
  with the base set to its last pushed id. The push waits while a pull of the
  same table runs or is due.
- **After a pull.** The requester sends the records named by `wants`, with
  the responder's clock values as base. All peers in the state of the
  responder can apply them at once.

A peer that hears `H`, `S`, or `P` with a table version that differs from its
own, and that could not apply the push, schedules a pull after a random 30 to
120 seconds and checks again before it sends. This delay prevents many peers
from pulling from one member at the same moment.

Three rules keep the peer list from causing pulls that transfer nothing:

- Every table version that a replica has had itself counts as merged.
- A push names the version before it (6.1). Not so for a member's push into a
  self table: there the version is a claim that proves nothing.
- A responder whose table version has changed since it last told the guild
  sends `S` when a pull request arrives; this stops the others before they
  ask too.

**Periodic summary.** Every 10 to 15 minutes a replica sends `S` with the
versions of the tables whose version no peer has announced since its last
one. This repairs a lost message when no later push follows, and lets a
replica whose source went offline find another.

**Delivery to the officers** (`SyncDelivery.lua`). In a self table an officer
cannot pull a member's records, so the member makes sure that the online
officers hold its own writes:

- An officer that handles a member's push into a self table whispers `K` with
  its clock value of the member's origin, after a short random wait.
- A member keeps, for the session, the id up to which each officer holds its
  character origin. It learns it from a `K`, from an officer that announces
  the member's own table version, and from a finished pull from an officer.
- After a `K` with an id below the own top the member pushes its records
  after that id. A check every 2 minutes does the same for online officers
  that hold less, at most 3 times per officer and table in a session.
- Only an officer that has announced a version of the table counts: an
  officer with an older addon never sends a `K`, and counting it would make
  every member push for nothing.
- `ns.sync:IsBehind(table)`: for a protected table, true when some peer has
  announced newer data than any online officer has.

### 7.4 Conditions and policy

Per table, with defaults from the table definition:

| Field | Values | Meaning |
| --- | --- | --- |
| `when` | `nocombat`, `noraid`, `resting` | Weakest state in which this table may send. |
| `pushDelay` | seconds | Wait after a local change, to collect several changes into one push. |
| `minInterval` | seconds | Shortest time between two pushes of the table. |
| `enabled` | boolean | Off: the table is neither sent nor requested. |

- `nocombat`: not in combat lockdown. `noraid`: also not in a raid group and
  not in an instance. `resting`: also resting.
- State changes come from events and timers use `C_Timer`; there is no
  `OnUpdate`.
- When a condition turns false during a transfer, the sender stops after the
  current batch; the receiver's timeout (7.2 step 6) handles the rest.
- Receiving is always allowed: applying a batch is cheap and has no protected
  calls.
- Members have no settings of the shared database. The "Sync" options page,
  with these fields and a status line per table, is shown only in the
  developer mode (section 8), and the overrides in
  `db.profile.sync.tables[name]` apply only in that mode.

## 8. Trust and validation

- Deserialize with `AceSerializer:Deserialize` only; never run received text.
- Check before use: protocol version, message type, table name is registered,
  schema matches, every id is valid (section 3), key is a string within a
  length limit, payload passes the table's `validate`, record size is within
  `maxRecordBytes`, counts and lengths are within limits.
- One bad record drops that record and all later records of the same origin
  in the batch (to keep the invariant), not the whole session.
- **Verdict `"seen"`.** For `keyKind = "character"`, the key must start with
  a name in the guild roster. A record that fails this is not stored, but its
  id still raises the clock, and it does not count as dropped. Dropping it
  would block the later records of its origin for as long as any replica
  holds the record of a member who left. A record older than `maxAge` is
  treated the same way.
- The limits, in `SyncStore.lua` and `SyncProtocol.lua`:

  | Limit | Value |
  | --- | --- |
  | Key of a record | 64 bytes |
  | Table name | 32 characters |
  | Tables in the registry, and in one `H` or `S` | 64 |
  | Records in one `D` or `P` | 500 |
  | Origins in a digest, a clock rest, or the wants | 2000 |
  | Batch number of one pull | 100000 |
  | Retry time of a `B` | 3600 s |
  | Hours in one `C` | 96 |
  | Ids in one `G` | 1000 (a sender asks with at most 200) |
  | Size of one batch | about 2000 bytes, by the estimate |

- The size of a record is `syncStore.recordSize`, an estimate that needs no
  serializer. `Put` refuses a record over `maxRecordBytes` with
  `"too large"`; a received one is dropped like any bad record.
- **Developer mode** (`db.global.debugTable`, `/oooo sync debug on`, off by
  default). Only in it are the tables `debug`, `debugofficer`, and
  `debugself` registered, so a release has no table that every member can
  fill with text; and only in it is the "Sync" page shown. `/oooo sync
  put|get|del [table] <key> <text>` write them.
- Accepted risk for owner tables: a member with a modified addon can write
  wrong data under any key. The addon cannot prove who owns a character. The
  damage is limited to wrong shared data, which a later correct write
  replaces; a future timestamp is limited to 5 minutes.

## 11. Decisions taken

- Transfers between two members use hidden addon whispers; broadcasts use
  the hidden guild addon channel.
- The origin is one random constant per player, made at install. Alt
  detection through it is a wanted feature.
- `profession`, `equipment`, and `attunement` are written by each player for
  their own characters only, and anyone may pass them on (5.2).
- The shared profession data holds ids and levels only; names, items, and
  reagents come from each client (5.4). A scan only adds recipes.
- `guildchat` holds the last 14 days with the original text, a fixed length.
  It is not real time. The sender's addon writes a line; a witness writes the
  lines of members without the addon (5.3).
- There is no `guildbank` table, no member relay, and no trust flag. Tables
  that restrict writing by guild rank are the protected tables (5.5).
- Members have no settings of the shared database (7.4).
