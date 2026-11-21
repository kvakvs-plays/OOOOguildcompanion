# Plan: protected tables and the gambling engine

Two additions to the shared guild database, and the first feature that needs
them:

- tables that only officers can write;
- tables in which a player can write only under the name of the own
  character, so that nobody can write in the name of another;
- a gambling engine for the guild, built on both.

Status: stage 13 is in work; the finished steps are in `00-finished.md`. The earlier plan (the sync engine,
guild chat, mentions, professions) is finished or closed; its steps are in
`00-finished.md` and its design is in `sync-design.md`.

- Implementing this plan - commit after each task. Commit title shall be
  "[plan] <task title>".
- New code (functions, data structures, types) shall have one-line explanation
  of intent behind it.
- Done task steps shall be removed from 00-plan and moved into a new file
  `00-finished.md` as compacted 1-2 line bullet points.

Section numbers: sections 1 to 11 of the earlier plan are now in
`sync-design.md` under the same numbers, and code comments cite them as
"plan section N". The sections of this plan are numbered from 12 and the
stages from 13, so that a number names one place. When a step of this plan
changes the engine, also change the text of `sync-design.md` that it makes
wrong.

## 12. Goals and limits

- A table definition can say `writers = "officer"`: only an officer writes
  its records, and no member can change what the others hold.
- A table definition can say `writers = "self"`: a record is written by the
  character that its key names, and no other member can write or replace it.
- Both rules hold against a member with a modified addon. The rule
  `writers = "owner"` of today does not: it trusts what a third member
  passes on (`sync-design.md`, 5.2 and 8).
- The gambling engine: officers open an event with outcomes of known chance,
  members bet gold on outcomes until the event closes, an officer says which
  outcomes came true, the addon works out who owes whom, and each receiver
  confirms the gold that arrived.
- The addon moves no gold. It only says who shall give how much to whom;
  the players trade or mail it themselves.

Scope:

- This design applies only to the new tables that are marked as protected
  in their definition (`writers = "officer"` or `writers = "self"`): the
  developer tables of stage 13 and the gambling tables of stage 14.
- The tables that exist today (`writers = "owner"` or `"anyone"`) do not
  change their behaviour. Who may write, who pushes, who is taken as the
  source of a pull, when a hello is answered, when a summary is held back,
  and what a member relays stay as `sync-design.md` describes them. Every
  rule of section 14 is read as "for a protected table".
- No existing feature changes: the guild chat history, the mentions, the
  professions, the member list, and the version check work as before.
- Where a step touches code that all tables share (the mark of the last
  push in 14.4, the new argument of `OnRecordChanged` in 14.8), the change
  is internal: an existing table sends and accepts the same messages as
  before. The existing host tests pass without a change, and that is part
  of the definition of done of every step of stage 13.

Limits:

- Officers are trusted. An officer with a modified addon can write anything
  into both kinds of table. The rules protect against members, not against
  officers.
- Without an officer online, protected tables do not spread (14.6). A member
  who logs in then sees the state of their last contact with an officer.
- Members with an addon version before this plan do not have the new tables
  and ignore them (`sync-design.md`, 6.1).

Not planned:

- Member relay of protected tables, with or without a trust flag. It would
  bring back what the rules remove: data that nobody can vouch for.
- Signatures. A signature would let any member pass a record on, but public
  key code in the Lua of the client is large and slow.
- Automatic trades or mails, and any check that gold has really moved.
- Bets against an outcome, odds that move with the bets, and a change of an
  event after it was opened.

## 13. Terms

The terms of `sync-design.md`, section 2, and:

| Term | Meaning |
| --- | --- |
| Officer | A character whose rank index in the roster is 0 or 1 (14.2). The rank belongs to the character, not to the player. |
| Member | Here: a character that is not an officer. |
| Protected table | A table with `writers = "officer"` or `writers = "self"`. |
| First hand | A record that arrives in a push from the character that its key names. |
| Vouched | A record that arrives from an officer. |
| Character origin | The origin in the ids of a self table: one per install and character (14.4). |
| Event | One gambling event: a title, outcomes, a close time. |
| Outcome | One thing that can happen in an event, with a chance in percent. It is resolved to true or false. |
| Cap | An optional limit of an outcome with a chance under 20%: the highest profit of a winning stake, as a multiple of the stake (15.3). |
| Stake | The gold that a character bets on one outcome. |
| Book | The officers' copies of the bets that an officer's addon received before the close (15.4). |
| Due | One payment that the settlement asks for: from a character, to a character, an amount of gold. |
| Banker | The officer character that takes the share of the guild bank for an event. |

## 14. Protected tables

### 14.1 What a receiver can prove

The design rests on two facts and uses nothing else as proof:

- The game server sets the sender name of an addon message. A member cannot
  send under another name (`sync-design.md`, 6: sender checks).
- The guild roster gives the rank of every member, and it comes from the
  server too.

A field inside a message proves nothing: not the `own` flag of a push, not
the origin in an id, not the timestamp in an id. The table `character`
proves nothing either, because its records pass through third members. So:

- "This record is from X" is known only when X sent the message itself.
- "An officer stands for this record" is known only when an officer sent the
  message.
- "This record was written before time T" is known to nobody but the writer.
  What a receiver knows is when it received the record (used in 15.4).

### 14.2 Officers

- `ns.OFFICER_RANKS = { [0] = true, [1] = true }`: in `OO OO` the ranks `O`
  (guild master) and `Ministry of War`. A constant, not a setting.
  Confirmed by the user on 2026-11-21 (18).
- `ns.guildState:IsOfficer(name)` reads the roster cache. A name that the
  cache lacks is no officer. The rank is read when a message arrives; a
  record that was accepted from an officer stays when that officer is
  demoted later.
- An officer who plays a character of member rank follows the member rules
  with that character, although the saved data is the same.

### 14.3 The rules, side by side

| | `writers = "officer"` | `writers = "self"` |
| --- | --- | --- |
| Key | `keyKind` free or character | `keyKind = "character"`: the key starts with the name |
| `Put`, `Delete`, `Append` | The logged-in character is an officer | The key names the logged-in character; alts do not count |
| Ids | Install origin, as today | Character origin (14.4) |
| A push from an officer | Applied | Applied |
| A push from a member | Ignored whole | A record whose key names the sender is applied; any other record is dropped, with the later records of its origin |
| A delta from an officer | Applied | Applied |
| A delta from a member | Never asked for; ignored | Never asked for; ignored |
| A member as the source of a pull | No: answers `Q` with `B`, reason `source` | The same |
| A member pushes | Never | Only the records of the logged-in character |
| Clock rest of a member's push | Ignored | Ignored |

- The check of a push does not read the `own` flag. A modified addon would
  set it as it likes.
- "Ignored whole" changes nothing: no record, no clock entry, no pull.
- A refused write gives `nil` and the reason `"not an officer"` or
  `"not the owner"`.
- The record checks that exist stay: id, key, `validate`, size, roster rule,
  `maxAge` (`sync-design.md`, 8).
- `Append` works in an officer table. In a self table it stays refused,
  because an id as key names no character.

### 14.4 Character origins

In a self table the origin in a version id is not the install origin. It is
`base94(hash(install origin .. ":" .. character name) mod 94^4, 4)`.

- Why: the clock is kept per origin, and the engine relies on it: a clock
  value covers every write of its origin (`sync-design.md`, 4.2). In a self
  table a member may send only the records of the character that is logged
  in. With one origin per install, a write of an alt that was never sent
  would lie below a clock value that the others already hold, and no pull
  would ever fetch it. With one origin per character, the unsent writes of
  an alt are a clock entry of their own. They wait until the player logs in
  on that alt.
- `ns.sync:OriginFor(tableName)` gives the origin of local writes: the
  character origin for a self table, the install origin for every other.
  The id source is one generator per origin.
- The mark of the last pushed write (`tbl.pushed`) is one id per table
  today. It becomes one per origin (`tbl.pushedBy[origin]`); the old field
  is read as the mark of the install origin.
- The other tables keep the install origin. Alt detection (`character`) and
  the flag `bySender` of the guild chat do not change.
- Nothing checks that an origin belongs to a name. A member with a modified
  addon can write a record under the own name with the origin of another
  character and an id up to 5 minutes ahead. The clock of the receivers then
  hides the real writes of that origin from a pull for those minutes. This
  delays data; it never puts a record under another name. Accepted (14.7).

### 14.5 How the protected data moves

```
officer table:   officer --push, delta--> everybody
                 member  --nothing-->

self table:      member  --push of own records--> everybody online (first hand)
                 officer --push, delta--> everybody (vouched)
                 member  --nothing of others-->
```

Changes to the flows of `sync-design.md`, section 7, for a protected table:

- **Sources.** Only an officer peer is taken as the source of a pull, by
  the greatest `maxId` among the officers.
- **Announced versions.** A version that an officer announces (`H`, `S`,
  `P`) is handled as today: it can start a delayed pull. A version that a
  member announces starts no pull. It is kept for `IsBehind` (below).
- **Answers and summaries.** An officer's answer to a hello and an
  officer's periodic summary are not held back because a member announced
  the same version. Another officer with the same version still holds them
  back.
- **After a pull.** The `wants` of the last delta ask a member only for the
  records of its character origin in a self table, and for nothing in an
  officer table. An officer answers the `wants` as today.
- **Equal data, different versions.** A member can hold a first-hand record
  of a character that no online officer holds. Its version then differs
  from the officers' until that character meets an officer. The rule that
  a merged version is not pulled again (`sync-design.md`, 7.2 step 5) keeps
  this from causing repeated pulls; step 13.4 tests it.

### 14.6 Delivery to the officers

In a self table an officer cannot fetch a member's records: it does not
know which member has new ones, and a member is no source. So the member
makes sure that the officers hold its own records.

New message, a whisper from an officer to a member:

| Type | Channel | Fields | Purpose |
| --- | --- | --- | --- |
| `K` held | WHISPER | table, origin, id | "I hold your writes of this origin up to this id." |

- An officer that handles a push of a member in a self table whispers `K`
  for the origin of the last record that names the sender, after a random
  1 to 5 seconds: one `K` per member and table. It does so also when it already held the records, and when it
  ignored them for a gap; the id is then its older clock value, or the zero
  id.
- A `K` from a sender that is no officer is ignored. Receivers before this
  plan drop it as an unknown type; the protocol version stays 1.
- A member keeps `held[table][officer] = id` for the session. It learns it
  from:
  - a `K`;
  - an officer that announces the member's own table version: that officer
    holds everything;
  - a finished pull from an officer: the officer holds the own writes when
    the `wants` do not name the own origin.
- A member pushes its own records again when an online officer peer that
  has announced the table holds less than the member's newest own write:
  - after a `K` with an older id: at once (by the policy), from that id;
  - otherwise by a check every 120 seconds, when no pull from that officer
    is planned or running: from the smallest held id among those officers,
    or the whole own slice when one of them is unknown. At most 3 times per
    officer and session.
- A hello of an officer clears what the member knew about that officer.
- Cost: one push and one `K` per online officer for a new write, and
  nothing at a login when the versions are equal.

`ns.sync:IsBehind(tableName)` is true when a peer of any rank has announced
a version of a protected table with a greater `maxId` than the own one and
no officer online can supply it. For an officer it means: another officer
wrote something that I lack, and that officer is offline. A feature warns
before an officer decides something on old data (15.5). A member with a
modified addon can only cause a false warning.

**Known limit.** Two officers who are never online together exchange
nothing, also when members who hold the data of both are online. This is
the price of having no member relay.

### 14.7 Accepted risks

- An officer can write anything (12).
- A member can delay the data of another by the trick with the origin
  (14.4), and can fill its own keys of a self table with records that pass
  `validate`. `maxRecordBytes` and `validate` are the limit, as for every
  table.
- A record of a self table that was first hand at one member and never
  reached an officer is seen by the members who were online at that moment
  and by nobody else. A feature must not treat such a record as known to
  all (15.4 does not).

### 14.8 API

```lua
ns.sync:RegisterTable({ ..., writers = "officer" })       -- or "self", "owner", "anyone"
ns.sync:OriginFor(tableName)             -- origin of local writes in this table
ns.sync:GetId(tableName, key)            -- version id of a stored record, or nil
ns.sync:NewId(tableName)                 -- a fresh id of this table, for a key that must be unique
ns.sync:IsBehind(tableName)              -- 14.6
ns.guildState:IsOfficer(name)
-- "OnRecordChanged" gets a sixth argument:
--   function(event, tableName, key, payload, isRemote, firstHand)
--   firstHand: true for a local write, and for a record from a push of the character that the key names
```

## 15. Gambling

### 15.1 What the members see

An officer opens an event: "Who wins the duel on Friday?" with the outcomes
"Nota 60%" and "Other 40%", open until Friday 20:00. Every member with the
addon sees it and can put gold on outcomes, for example 30 on Nota. They
can change or take back the stake until the close. Nothing is paid in
advance.

After the duel an officer marks each outcome as true or false. The addon
then tells every bettor a result ("you won 20 gold", "you lost 36 gold") and
the dues: "give 20 gold to Nota Scam", "give 3 gold to Officer One for the
guild bank". The players trade the gold. Who received gold presses
"Received" on that due. Everybody sees which dues are confirmed.

### 15.2 Tables

Two tables, so that a hello carries two versions and not five.

```lua
ns.sync:RegisterTable({
  name = "gamble",                    -- events, the book, the dues
  schema = 1,
  keyKind = "free",                   -- no roster cleanup: the due of a member who left stays visible
  validate = ...,
  maxRecordBytes = 1500,
  writers = "officer",
  maxAge = KEEP_DAYS * 86400,         -- KEEP_DAYS = 90
  -- fast: a lock must reach the other officers before their bookers act on a late change (15.4)
  policy = { when = "nocombat", pushDelay = 2, minInterval = 5 },
})
ns.sync:RegisterTable({
  name = "gamble_player",             -- the bets and the receipts of each character
  schema = 1,
  keyKind = "character",
  validate = ...,
  maxRecordBytes = 300,
  writers = "self",
  maxAge = KEEP_DAYS * 86400,
  policy = { when = "nocombat", pushDelay = 5, minInterval = 15 },
})
```

| Table | Key | Payload |
| --- | --- | --- |
| `gamble` | `e:<event id>` | The event (15.3) |
| `gamble` | `b:<event id>:<name>` | Book entry: `{ g = { [outcome] = gold }, b = id of the bet record, t = server time of receipt }` |
| `gamble` | `d:<event id>:<n>` | Due number `n`: `{ q = settlement token, f = from, t = to, g = gold, k = true for the bank share }` |
| `gamble_player` | `<name>:b:<event id>` | Bet: `{ g = { [outcome] = gold } }`, 1 to 8 entries |
| `gamble_player` | `<name>:r:<event id>` | Receipts: `{ q = settlement token, n = { [due number] = true } }` |

- An event id is a version id (`ns.sync:NewId("gamble")`), 11 characters.
  It can contain `:`. A key is therefore read by position (prefix, 11
  characters, `:`, rest) and never split on `:`. The name at the start of a
  `gamble_player` key ends at its first `:` as in every character key.
- A name is at most 48 bytes, so every key fits the 64 bytes of the engine.
- Gold is a whole number of gold coins, 1 to 100000. No silver.
- `validate` checks types, ranges, and the form of the key. It cannot check
  one record against another (a stake against the outcomes of its event);
  the reader does that and ignores what does not fit.
- Every text of an event is shown through `ns.mentions.sanitize`.

### 15.3 Event

```lua
{ n = "Who wins the duel on Friday?",   -- title, 1 to 80 bytes
  o = { { n = "Nota", p = 60 },         -- 2 to 8 outcomes: name of 1 to 40 bytes,
        { n = "Other", p = 40 } },      --   chance p in whole percent, 1 to 99;
                                        --   optional cap x, a whole number from 1 to 99,
                                        --   only with p under 20: { n = "Sword", p = 2, x = 10 }
  c = 1795300000,                       -- close: server time after which no bet counts
  m = 100,                              -- highest stake of one character on one outcome
  s = 1,                                -- 1 open, 2 resolved, 3 cancelled
  by = "Officer One",                   -- who opened it
  -- with s = 2:
  r = { true, false },                  -- result per outcome
  q = "aB3$",                           -- settlement token: 4 random base-94 characters
  d = 3,                                -- number of dues
  k = "Officer One",                    -- banker
}
```

- The outcomes are independent statements. Each is resolved by itself, so
  none, one, or several can be true, and the chances need not add up to
  100. "A wins" and "B wins" are two outcomes; so are "the boss drops the
  sword" (10%) and "it does not" (90%).
- An event with one outcome would have only winners or only losers and
  would move no gold. That is why 2 is the least.
- **Cap.** A chance of 1% or 2% promises 99 or 49 times the stake. The
  officer who opens the event can cap an outcome with a chance under
  `CAP_BELOW = 20` percent: `x` is the highest profit of a winning stake as
  a multiple of the stake. With `p = 2` and `x = 10`, 5 gold claim 50 gold
  and not 245. A cap above what the chance promises changes nothing.
  (Asked for by the user on 2026-11-21.)
- The title, the outcomes, the chances, the caps, and `m` never change after
  the event was opened. A wrong event is cancelled and opened again.
- **Close.** `c` is set when the event is opened, at most 30 days ahead. An
  officer can lock the event earlier: the lock sets `c` to the current
  server time. `c` never moves later.
- **States.** Open and before `c`: bets are taken. Open and after `c`:
  locked, waits for the resolution. Resolved: the dues are valid. Cancelled:
  nothing is owed; a cancel is possible in every state and also takes back
  a resolution (the dues of its token no longer count).
- Any officer can lock, resolve, or cancel any event. Two officers who
  decide at the same time are ordered by last writer wins; the token `q`
  tells the dues of the winning resolution from the others.

### 15.4 Bets and the book

A bet is a record of the bettor in `gamble_player`. It counts only when an
officer's addon has copied it into the book before the close.

- **Why a book.** The id of a bet carries the time that the bettor's addon
  wrote into it (14.1). A modified addon could write a bet after the result
  is known, with an id from before the close. The book entry carries `t`,
  the server time at which an officer's addon received the bet, and
  officers are trusted. A bet counts when it has a book entry with
  `t <= c`.
- **Placing.** The bettor's addon writes the bet with `Put` and takes it
  back with `Delete`, only while the event is open and before `c`. A stake
  of 0 removes the outcome from the bet. The engine pushes the record and
  makes sure that the online officers hold it (14.6).
- **Booking.** An officer's addon books a bet when `OnRecordChanged` tells
  it of a `gamble_player` record with `firstHand` true, also for the
  officer's own bets:
  - It notes the time of receipt at once.
  - It checks: the event is held, open, and the time of receipt is not
    after `c`; every outcome exists; every stake is 1 to `m`.
  - After a random 0 to 20 seconds it writes the book entry, unless it now
    holds an entry with the same `b`: another officer was faster.
  - A bet that was taken back first hand before the close deletes the
    book entry.
  - **Hold.** A change that would replace or delete a held entry (a changed
    bet, a take back) waits `CHANGE_HOLD = 45` seconds after its receipt
    plus the random delay, and is then judged again with the event as it
    is then: still open, and the time of receipt not after the current `c`.
    Otherwise the entry stays. A "Lock now" reaches the other officers
    only with the push of `gamble`; the hold lets it arrive first. Every
    write and delete keeps the rule "no entry of the same or a newer write
    of the bet": a take back carries the id of its delete. A newer change
    of the same bet replaces a pending one and waits on its own receipt.
  - A bet whose event the officer does not hold yet waits in memory, with
    its time of receipt, until the event arrives or the session ends: at
    most 500 bets, 8 of one bettor, each for 10 minutes.
  - A bet that fails a check gets no entry.
- **Several officers.** All online officers receive the same push. Each
  would write the same entry; the delay above saves most of the double
  writes, and a double write is harmless, because both carry a time of
  receipt before the close.
- **A vouched bet is not booked.** An officer that gets a bet from another
  officer does not know when it was first received. The entry of the first
  officer arrives by the same way.
- **What the bettor sees** for the own bet: "waiting for an officer" (no
  entry with the id of the bet record), "accepted" (entry with that id),
  and after the close "too late" (no such entry). A change that came too
  late leaves the accepted entry in force, and the window says so.
- **What everybody sees**: the sum of the booked stakes per outcome, but
  only after the close. While bets are taken, the window shows the own
  stake and nothing of the others (decided by the user on 2026-11-21). This
  hides the sums in the window only: the book entries travel to every
  member, so a member who reads the saved data can add them up.
- No officer online means that no bet is accepted. The window tells the
  bettor to place bets early.

**Accepted risks.**

- The lock travels only while the locking officer may send (`nocombat`),
  and a push can be lost. A bettor who changes or takes back a bet within
  that time after a "Lock now", while another officer has not heard of the
  lock for `CHANGE_HOLD` seconds, can still void the accepted bet. A close
  that was set when the event was opened is known to every officer and has
  no such window.
- Two officers who press "Lock now" within the propagation time of each
  other end with the later close: last writer wins (15.3).
- A stale "Lock now" written after another officer's resolution puts the
  event back to locked: last writer wins (15.3). The dues of that
  resolution stay stored with a token that the event no longer carries, so
  no reader counts them; an officer resolves the event again.

### 15.5 Resolution and settlement

An officer resolves a locked event: true or false for each outcome, and a
banker (an officer character from the roster; the default is the own one).

- Before the write the window shows the number of valid bets, the sum, and
  a warning when `ns.sync:IsBehind("gamble")` is true: an offline officer
  may have booked bets that this officer lacks.
- **Wait for the bookings.** `Resolve` refuses with the reason `"booking"`
  until `RESOLVE_WAIT = 90` seconds after `c`, and the preview gives the
  seconds left (`wait`). A change received before the close is written at
  most 45 + 20 seconds after it (15.4) and pushed at most 5 seconds later;
  20 seconds are left for the transfer.
- The addon of the resolving officer computes the settlement from the book
  entries that it holds with `t <= c`, writes the dues, and then the event
  with `s = 2`, the results, the token, the number of dues, and the banker.
  The event is written last: a replica that holds the resolved event and
  not yet `d` dues of its token shows "loading".
- **The written dues are the settlement.** No other replica computes it
  again. A book entry that reaches the resolving officer later is not part
  of it; its bettor sees "not in the settlement" and owes nothing.

The settlement, `gambleSettle.settle(outcomes, results, bets, banker)`. The
share of the guild bank is the constant `BANK_SHARE = 10` percent.

1. A stake on an outcome that came true wins; every other stake loses.
2. The claim of a winning stake is what the chance promises as profit:
   `stake * (100 - p) / p`. 30 gold on a 60% outcome claim 20 gold; 30 gold
   on a 10% outcome claim 270. With a cap `x` (15.3) the claim is at most
   `stake * x`: 30 gold on a 10% outcome with `x = 5` claim 150.
3. `L` is the sum of the losing stakes and `C` the sum of the claims. When
   one of them is 0, nothing is owed: an event without winners or without
   losers moves no gold.
4. The winners get their claims in full when the losers' gold is enough for
   them after the share of the bank, and the same part of each claim
   otherwise: a winning stake gets
   `floor(claim * min(1, (100 - BANK_SHARE) / 100 * L / C))`. `W` is the sum.
5. The bank gets `floor(W * BANK_SHARE / (100 - BANK_SHARE))`: 10% of what
   the losers pay.
6. The losers pay `P = W + bank` together, each stake its part
   `stake * P / L`, rounded down. The gold that the rounding leaves over is
   added one coin at a time to the largest losing stakes (equal stakes: by
   name). A loser never pays more than the stake.
7. The net of a character is its winnings minus its payments. The nets and
   the bank share add up to 0.

Example: outcomes Nota 60%, Other 40%. X bets 30 on Nota, Y 20 on Nota, Z
40 on Other.

| Result | Claims | `L` | Winners get | Bank | Losers pay |
| --- | --- | --- | --- | --- | --- |
| Nota wins | X 20, Y 13.3 | 40 | X 20, Y 13 | 3 | Z 36 (of 40) |
| Other wins | Z 60 | 50 | Z 45 | 5 | X 30, Y 20 |

**Dues.** The nets become payments:

- Those who receive are the bank first, then the winners by amount (equal
  amounts: by name). Those who pay are ordered the same way.
- The first payer pays the first receiver as much as both allow; whoever is
  done leaves the list. So the bank share comes from the one or two largest
  losers and goes to the banker, with `k = true`, and the number of dues is
  below the number of bettors plus one.
- When the banker is the payer of a bank due, the due names the banker on
  both sides: the banker puts that gold into the guild bank from the own
  pocket.

### 15.6 Receipts

- The character that a due names in `t` confirms it: the addon adds the due
  number to the own receipt record of the event. A confirmation can be
  taken back.
- A reader counts a receipt only when its token equals that of the event
  and the due names the writer of the receipt as receiver. The self rule
  (14.3) makes sure that only the receiver wrote it.
- The banker confirms the bank dues in the same way and moves the gold into
  the guild bank by hand.
- An event is "settled" for the list when every due is confirmed. Nothing
  else happens then; the records fade after `KEEP_DAYS`.
- Not in this plan: a mark of the payer ("sent"), a confirmation by an
  officer in place of a receiver who is gone, and reminders in chat.

### 15.7 Window and notices

A tab "Gambling" in the addon window (`ns.mainWindow:RegisterTab`), opened
also with `/oooo bet`.

```
+----------------------------+----------------------------------------------+
| Open                       | Who wins the duel on Friday?                 |
|  Who wins the duel ...     | open until Fri 20:00 (in 2 h)   by Officer   |
| Waiting for the result     |                                              |
|  Onyxia down this week?    | Nota    60%   booked 50   your stake [ 30 ]  |
| To pay                     |               you can win 20                 |
|  Loot bet (2 of 5 paid)    | Other   40%   booked 40   your stake [    ]  |
| Done                       |                                              |
|  ...                       | [Place bet]  [Take back]   accepted          |
|                            |                                              |
| [New event]   (officers)   | [Lock now] [Resolve] [Cancel]   (officers)   |
+----------------------------+----------------------------------------------+
```

- **List**: the events in four groups, the newest first.
- **Detail, open**: the outcomes with chance and cap, the own stake with
  the highest possible win, and the state of the own bet (15.4). The booked
  sum per outcome appears after the close (15.4); the sketch above shows a
  locked event.
- **Detail, resolved**: the result of each outcome, the own net, the own
  dues ("give 20 to Nota Scam", "Nota Scam gives you 20 [Received]"), and
  all dues with their confirmations.
- **Officers**: "New event" (title, 2 to 8 outcomes with chance, close as
  day and time, highest stake; an outcome with a chance under 20% shows a
  check box "cap the payout" and a number box for the multiplier `x`), "Lock now", "Resolve" (a check box per
  outcome, the banker, the warning of 15.5, a second click to confirm),
  "Cancel". The controls are shown to an officer character only; the
  engine refuses the writes of everybody else anyway.
- **Notices** in the chat frame, each once per event and character (kept in
  `db.global.gamble.noticed`), with the `addon:` link that opens the tab:
  a new open event, and the own dues after a resolution. They wait for the
  end of combat.
- No protected call is made: the addon opens no trade and no mail.

## 16. Files

```
Addon\Src\Guild\GuildState.lua       + OFFICER_RANKS, IsOfficer
Addon\Src\Sync\SyncTables.lua        + writers "officer" and "self", OriginFor, GetId, NewId, firstHand
Addon\Src\Sync\SyncProtocol.lua      + the message K, the refusal reason "source"
Addon\Src\Sync\SyncPull.lua          + sources and deltas by rank
Addon\Src\Sync\SyncPush.lua          + pushes by rank, the mark per origin, wants of a member
Addon\Src\Sync\SyncSession.lua       + summaries of officers, the versions for IsBehind
Addon\Src\Sync\SyncDelivery.lua      new: K, the held map, the repeated push (14.6)
Addon\Src\Sync\SyncCommands.lua      + the tables debugofficer and debugself of the developer mode
Addon\Src\Gamble\GambleData.lua      new: the two tables, keys, validate                    (host-testable)
Addon\Src\Gamble\GambleSettle.lua    new: settle, the dues                                   (host-testable)
Addon\Src\Gamble\Gamble.lua          new: events, bets, resolution, receipts, the reading    (host-loadable)
Addon\Src\Gamble\GambleBook.lua      new: the booking of the officers                        (host-loadable)
Addon\Src\Gamble\GambleTab.lua       new: the tab "Gambling", notices, /oooo bet
Tests\sync_officer.lua, sync_self.lua, sync_delivery.lua
Tests\sync_gambledata.lua, sync_gamblesettle.lua, sync_gamble.lua, sync_gamblebook.lua
```

Also: the new files in `toc_template.toc` and `.agents/project-map.md`, and
an entry in `CHANGELOG.md` with the release that brings the tab.

## 17. Stages

How to read this section:

- A stage is a group of steps. A step (`13.1`, `13.2`, ...) is one task: one
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
- A number in brackets, such as (14.6), names a section of this plan. A
  step is always called "step".
- Part of every definition of done of stage 13 (12, Scope): the existing
  host tests pass with no change to their files, and a table with
  `writers = "owner"` or `"anyone"` sends and accepts the same messages as
  before the step.
- Stage 13 comes first. Stage 14 needs it. Stage 15 needs stage 14. Within
  stage 14, step 14.2 needs nothing and can be done at any time.

### Stage 13. Protected tables

- **13.6 Client check** (**CLIENT**, an officer and a member account)
  - Checkpoint, in the developer mode on both accounts:
    - `/oooo sync put debugofficer k v` works on the officer and is refused
      on the member; the member receives the record.
    - `/oooo sync put debugself <own name> v` works on the member; the
      officer receives it and the status of the member shows it as held.
      The same command with the name of the other character is refused.
    - The officer logs out; the member writes again; the officer logs in
      and holds the record within three minutes.
    - A third member with the addon version before this plan gets no Lua
      error and no chat line from the new traffic.
  - Record in AGENTS.md whatever the client shows about ranks or whispers
    that differs from the facts there.
  - Done when: the check is recorded, with no Lua error and no "Interface
    action failed" entry.

### Stage 14. Gambling model

### Stage 15. Gambling window

- **15.1 The tab and betting** (**CLIENT**)
  - State: the code is written (`GambleTab.lua`, the start of the model and
    the book in `Core.lua`), with luacheck only. The client check is open.
    To look at there: the weekday of the line "open until" comes from
    `date("%a %H:%M")` and may not be in English.
  - Substeps: `GambleTab.lua` with the list, the detail of an open event,
    the stake boxes, "Place bet", "Take back", the state of the bet, and
    `/oooo bet`. It refreshes on `OnRecordChanged`, at most once in 0.5
    seconds.
  - Checkpoint, with an event that was opened by `/oooo sync put` or by
    step 15.2: the member places a bet, sees "waiting for an officer" and
    then "accepted"; the officer account shows the booked sum; a stake
    over the limit and a letter in the box are refused with a line.
  - Done when: the check is recorded, with no Lua error and no "Interface
    action failed" entry.

- **15.2 The controls of the officers** (**CLIENT**)
  - State: the code is written in `GambleTab.lua`, with luacheck only. The
    client check is open. The close is typed as days, hours, and minutes
    from now. To look at there: "New event" under the list, the cap row
    that appears as a chance under 20 is typed, the second click of
    "Resolve" and "Cancel event", and that a member sees no control.
  - Substeps: "New event", "Lock now", "Resolve" with the warning and the
    second click, "Cancel"; shown to officers only.
  - Checkpoint: an officer opens, locks, and resolves an event; a member
    character of the same account sees no control; a bet after the lock
    shows "too late".
  - Done when: the check is recorded.

- **15.3 Dues, receipts, notices** (**CLIENT**)
  - State: the code is written: the detail of a resolved event with
    "Received" and "Undo" in `GambleTab.lua` (luacheck only), the notices
    in `GambleNotice.lua` (host tests), the changelog entry, and the
    version 2026.11.8. The client check is open.
  - Substeps: the detail of a resolved event; "Received" and its taking
    back; the two notices with their link; the changelog entry and the
    version.
  - Checkpoint, with an officer, a second officer or the same as banker,
    and two members, on the example of 15.5: every account shows the same
    dues; each receiver confirms; the list moves the event to "Done"; the
    notice came once per character and its link opens the tab.
  - Done when: the check is recorded, and one real event of the guild has
    run from the opening to the last confirmation.

## 18. Decisions

Taken with this plan:

- The design applies only to new tables marked as protected. The existing
  tables, their rules of publication, and the existing features do not
  change (12, Scope).
- Protected tables take data from officers only; there is no member relay.
- The proof of a writer is the sender name of the message and the rank in
  the roster, nothing inside the message.
- A bet counts by the time at which an officer's addon received it, not by
  the time in its id.
- The dues that the resolving officer writes are the settlement; no other
  replica computes it.
- The guild bank gets 10% of what the losers pay, through a banker.
- No gold moves by the addon.

Confirmed or changed by the user on 2026-11-21:

- **Officer ranks** (step 13.1): rank indexes 0 and 1. Confirmed.
- **Payout rule** (step 14.2): a winner gets at most what the chance promises,
  and the losers pay only what is needed for that. Confirmed.
- **No winners** (step 14.2): nobody pays, and the bank gets nothing.
  Confirmed.
- **Stakes** (section 15.4): changed. The booked sums per outcome are shown
  only after the close.
- **Banker** (section 15.5): chosen by the resolving officer, the own character by
  default. Confirmed.
- **Payout cap** (section 15.3): new. An outcome with a chance under 20% can
  cap the profit of a winning stake at a multiple of the stake.
