# Changelog

<!--
The addon shows this file in its "What's new" window: scripts/release_tool.py
turns it into Addon/Src/Changelog/ChangelogData.lua. Keep the form:
"## <version> (<date>)", "### <section>", and items that start with a
**bold heading** followed by the explanation. `Backticks` mark commands.
-->

## 2026.11.3 (2026-11-19)

### Guild professions

- **Who can craft what.** `/oooo prof` opens a window that searches the
  recipes of all guild members with the addon. Type a part of a recipe name,
  or of a material name, or both. A click on a recipe shows its materials
  and the members who know it, online members first. A shift-click puts the
  item link into the chat box.
- **Your professions are shared.** The addon shares the professions and
  skill levels of your character. To share your recipes, open each of your
  profession windows once; the addon reminds you after login. Recipes that
  you learn later are added when you open the window again.

## 2026.11.2 (2026-11-19)

### Guild chat history and mentions

- **Guild chat history.** `/oooo chat` opens the guild chat of the last
  14 days, also the lines written while you were offline. It opens with the
  last 100 lines; scroll to the top to load older ones. Item links in it
  show their tooltip, and emoji are shown like in chat.
- **Mentions.** In the settings (General tab, "Mentions") list your nicknames
  and keywords, separated by commas. A guild chat line with `@` directly
  before one of them is a mention of you, without regard to letter case.
- **Your mentions beside the history.** The history window lists your
  mentions at the right, under "Unread" and "Read". A click scrolls to the
  line, highlights it, and marks it read.
- **A notice for a new mention.** When the sync brings a mention of you that
  you have not seen, the addon prints one line with a link that opens the
  window. With "Tell me after login" on, it also reminds you of unread
  mentions after login.
- **A warning when nobody can share your mention.** When you write an `@`
  mention and no other member with the addon is online, the addon warns you
  that the line is shared only when one comes online.

### Shared guild data

- **Sync in the background.** Members with the addon exchange data over
  hidden addon messages: they find each other after login, request what they
  miss, and send their own changes. Nothing is sent in combat; each kind of
  data waits for its own condition (out of combat, out of a raid, or
  resting).
- **Guild chat for 14 days.** Guild chat is kept by every member with the
  addon and shared for 14 days, also lines of members without the addon, so
  that a member who was offline gets them later.
- **Characters of one player.** Each member's characters are shared, so that
  the addon can recognise the alts of one player. Nothing shows them yet.
- **Sync status.** `/oooo sync status` shows the state of the shared data and
  the members with the addon that are online.

### Other

- **What's new.** `/oooo new` opens a window with the changes of each
  version. After login the addon prints its version with a link that opens
  the window.
- **A short command for the settings.** `/opt` opens the settings, like
  `/oooo opt`. It can be turned off on the General tab when another addon
  uses `/opt`.
- **Emoji size.** The size of emoji in chat can be set on the General tab
  (16 to 40 px).
