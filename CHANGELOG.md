# Changelog

<!-- The addon shows this file in its "What's new" window: scripts/release_tool.py
turns it into Addon/Src/Changelog/ChangelogData.lua. Keep the form:
"## <version> (<date>)", "### <section>", and items that start with a
**bold heading** followed by the explanation. `Backticks` mark commands. -->

## 2026.11.9 (2026-11-22)

### Emoji

- **New and changed guild emoji.** The emoji of the guild Discord were imported
  again. New: demonbro, ew, greedy, jesus, jew, nocomment, scared, smart, sus,
  and umm. Renamed: big_league is now bigleague, and heardutalkinshit is now
  heardutalkingshit. Gone: __, destrpot, hastepot, holy_leader, and smudgecat.
- **Some standard emoji.** Chat now also shows a few standard emoji of Discord
  when you write their name: alien, atm, beer, brain, clown, credit_card, eyes,
  fire, fish, flag_ba, foot, ghost, heart, joker, kiss, lock, moai, nose, ogre,
  orangutan, punch, rofl, scroll, skull, sound, tongue, and wood. No colons are
  needed. "Show the standard Discord emoji" in the settings (`/oooo opt`, tab
  "General") turns them off.
- **One texture for all emoji.** The addon draws every emoji from one shared
  image instead of a file per emoji. Emoji in chat look and work as before.

## 2026.11.8 (2026-11-21)

### Gambling

- **A pool among guild members.** The new tab "Gambling" (`/oooo bet`) lists the
  bets that the officers have opened. An event has outcomes with a chance in
  percent, for example "Nota becomes pink today, 60%". Put gold on one or more
  outcomes until the event closes; you can change or take back a stake until
  then. Nothing is paid in advance. There is no bookmaker and no stake is
  multiplied: those who were right share the gold of those who were wrong.
- **What you can win.** The winners are paid from the stakes of the losers,
  after a tenth of it for the guild bank. If nobody lost, nobody wins anything.
  The chance only sets a ceiling for a stake: 30 gold on a 60% outcome get at
  most 20 gold. When the losers staked less than all winners could get, every
  winner gets the same part of the ceiling; when they staked more, the losers
  keep the rest. An officer can set a lower ceiling for an outcome under 20%,
  and the tab shows it.
- **An officer must be online.** A bet counts once the addon of an officer has
  received it before the close. The tab shows "waiting for an officer" and then
  "accepted". Place bets early: with no officer online until the close, a bet is
  too late.
- **Who owes whom.** After an officer has set the results, the tab shows what
  you get or pay and to whom, such as "give 20 gold to Nota Scam". The addon
  moves no gold: trade or mail it yourself. Who received gold presses
  "Received", and everybody sees which dues are confirmed.
- **Notices.** A chat line tells you of a new bet and of your dues after a
  result, each once. Click the link in it to open the tab.
- **For officers.** "New event" opens a bet with its outcomes, the close, and
  the highest stake. "Lock now" closes it early, "Resolve" sets the results and
  the officer who takes the share of the guild bank, and "Cancel event" ends it
  so that nobody owes anything.

## 2026.11.7 (2026-11-20)

### Members

- **Profession icons.** The tab "Members" shows an icon for each profession of a
  member instead of its name. The two numbers in the icon are the skill (white)
  and the highest skill of the learned rank (silver). Point at an icon to read
  the name of the profession. The icons of a member are in the order of the
  profession names.
- **Easier to read lines.** Every second line has a silver background, and an
  offline member is marked with "(offline)" and grey icons.
- **No recipe count.** The count of shared recipes in brackets is gone.

### Emoji

- **Choose the chats with emoji.** The settings (`/oooo opt`, tab "General")
  have a checkbox for each kind of chat: guild, party, raid, officer, say,
  General, and Trade. Guild, party, raid, and officer are on; turn the others on
  when you want emoji there too. Raid warnings follow the raid checkbox.

## 2026.11.6 (2026-11-19)

### Addon versions

- **Who runs which version.** `/oooo versioncheck` prints the addon version of
  every online guild member. In a party or raid it prints only the guild members
  of your group. A member whose addon has been silent for some hours is shown
  with the time it was last seen, and a member without the addon as "no addon
  seen". Members with a version before 2026.11.6 do not tell their number yet.

### Guild chat

- **A clicked mention is easier to find.** The line of a mention that you click
  in the guild chat history now has a silver background and keeps its green
  text, instead of turning yellow.

## 2026.11.5 (2026-11-19)

### One window

- **One window for everything.** `/oooo` opens the addon window. The guild chat
  history, the recipe search, and the new member list are tabs of it. The window
  can be moved and resized, and it opens with the tab that you used last. The
  commands `/oooo chat` and `/oooo prof` are gone.
- **Members and their professions.** The new tab "Members" lists every member
  who shares professions, with each profession, its skill level, and the count
  of shared recipes. Pick a profession to see only its members, the highest
  skill first.

## 2026.11.4 (2026-11-19)

### Guild professions

- **A clearer recipe detail.** The detail of a clicked recipe in `/oooo prof`
  has its own framed field. It shows the icon of the recipe and its name as a
  link: a click opens the link, a shift-click puts it into the chat box. The
  materials are item icons with the needed count; point at one to see the item.
- **The reminder comes reliably.** The reminder to open your profession windows
  was sometimes skipped right after login. It now waits until the game shows
  your skill levels.
- **Who can craft what.** `/oooo prof` opens a window that searches the recipes
  of all guild members with the addon. Type a part of a recipe name, or of a
  material name, or both. A click on a recipe shows its materials and the
  members who know it, online members first. A shift-click puts the item link
  into the chat box.
- **Your professions are shared.** The addon shares the professions and skill
  levels of your character. To share your recipes, open each of your profession
  windows once; the addon reminds you after login. Recipes that you learn later
  are added when you open the window again.

## 2026.11.2 (2026-11-19)

### Guild chat history and mentions

- **Guild chat history.** `/oooo chat` opens the guild chat of the last 14 days,
  also the lines written while you were offline. It opens with the last 100
  lines; scroll to the top to load older ones. Item links in it show their
  tooltip, and emoji are shown like in chat.
- **Mentions.** In the settings (General tab, "Mentions") list your nicknames
  and keywords, separated by commas. A guild chat line with `@` directly before
  one of them is a mention of you, without regard to letter case.
- **Your mentions beside the history.** The history window lists your mentions
  at the right, under "Unread" and "Read". A click scrolls to the line,
  highlights it, and marks it read.
- **A notice for a new mention.** When the sync brings a mention of you that you
  have not seen, the addon prints one line with a link that opens the window.
  With "Tell me after login" on, it also reminds you of unread mentions after
  login.
- **A warning when nobody can share your mention.** When you write an `@`
  mention and no other member with the addon is online, the addon warns you that
  the line is shared only when one comes online.

### Shared guild data

- **Sync in the background.** Members with the addon exchange data over hidden
  addon messages: they find each other after login, request what they miss, and
  send their own changes. Nothing is sent in combat; each kind of data waits for
  its own condition (out of combat, out of a raid, or resting).
- **Guild chat for 14 days.** Guild chat is kept by every member with the addon
  and shared for 14 days, also lines of members without the addon, so that a
  member who was offline gets them later.
- **Characters of one player.** Each member's characters are shared, so that the
  addon can recognise the alts of one player. Nothing shows them yet.
- **Sync status.** `/oooo sync status` shows the state of the shared data and
  the members with the addon that are online.

### Other

- **What's new.** `/oooo new` opens a window with the changes of each version.
  After login the addon prints its version with a link that opens the window.
- **A short command for the settings.** `/opt` opens the settings, like
  `/oooo opt`. It can be turned off on the General tab when another addon uses
  `/opt`.
- **Emoji size.** The size of emoji in chat can be set on the General tab (16 to
  40 px).
