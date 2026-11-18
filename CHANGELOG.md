# Changelog

## 2026.11.2 (2026-11-19)

### Guild chat history and mentions

- `/oooo chat` opens the **guild chat history**: the guild chat of the last
  14 days, also the lines written while you were offline. It opens with the
  last 100 lines; scroll to the top to load older ones. Item links in it
  show their tooltip, and emoji are shown like in chat.
- **Mentions.** In the settings (General tab, "Mentions") list your nicknames
  and keywords, separated by commas. A guild chat line with `@` directly
  before one of them is a mention of you, without regard to letter case.
- The history window lists your mentions at the right, under "Unread" and
  "Read". A click scrolls to the line, highlights it, and marks it read.
- When the sync brings a mention of you that you have not seen, the addon
  prints one line with a link that opens the window. With "Tell me after
  login" on, it also reminds you of unread mentions after login.
- When you write an `@` mention and no other member with the addon is
  online, the addon warns you that the line is shared only when one comes
  online.

### Shared guild data

- Members with the addon exchange data in the background over hidden addon
  messages: they find each other after login, request what they miss, and
  send their own changes. Nothing is sent in combat; each kind of data
  waits for its own condition (out of combat, out of a raid, or resting).
- Guild chat is kept by every member with the addon and shared for 14 days,
  also lines of members without the addon, so that a member who was offline
  gets them later.
- Each member's characters are shared, so that the addon can recognise the
  alts of one player. Nothing shows them yet.
- `/oooo sync status` shows the state of the shared data and the members
  with the addon that are online.

### Other

- `/opt` opens the settings, like `/oooo opt`. It can be turned off on the
  General tab when another addon uses `/opt`.
- The size of emoji in chat can be set on the General tab (16 to 40 px).
