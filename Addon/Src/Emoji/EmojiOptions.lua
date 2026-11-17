local addonName, ns = ...

---@class OOOOEmojiOptions Special treatment of one emoji
---@field caseSensitive boolean|nil true: the name and the aliases match only in the exact letter case

---Special options of single emoji. This file is edited by hand; no script writes it.
---
---The key is the emoji name (the PNG file name without the extension). An emoji which is not listed has no
---special options. A name with characters other than letters, digits, and underscores needs the long form of
---the key: `["some-name"] = { ... }`.
---
---`caseSensitive = true` is for an emoji whose name is a normal word in another letter case: without it,
---WAS would replace every "was" in chat.
---@type table<string, OOOOEmojiOptions>
ns.emojiOptions = {
  WAS = { caseSensitive = true },
  WUT = { caseSensitive = true },
}
