local addonName, ns = ...

---Other spellings which show an emoji: what people type without thinking and narrowly miss the emoji name.
---This file is edited by hand; no script writes it.
---
---The key is the emoji name (the PNG file name without the extension), the value is the list of aliases.
---An alias matches in any letter case, like the name, and can have spaces. A name with characters other
---than letters, digits, and underscores needs the long form of the key: `["some-name"] = { ... }`.
---@type table<string, string[]>
ns.emojiAliases = {
  -- gzkush = { "gz kush" },
  aightimmaheadout = { "headout" },
  wtfhorse = { "mount" },
  credit_card = { "card" },
}
