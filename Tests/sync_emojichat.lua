-- Host test of the emoji in chat (Addon/Src/Emoji/Emoji.lua, EmojiChat.lua): the tokens of a chat line are
-- looked up in the trigger strings. The guild emoji and the standard emoji of Discord are bare words alike.
local T = dofile("Tests/harness.lua")

local ns = {
  addon = {
    NewModule = function()
      return {}
    end,
  },
  guildState = {
    RegisterCallback = function() end,
  },
  db = { profile = { general = { emojiSize = 16, emojiChannels = {} }, emoji = { disabled = {} } } },
  emojiAliases = { gzkush = { "gz kush" }, Kek = { "lol" } },
  emojiOptions = { WAS = { caseSensitive = true } },
  -- As scripts/import_discord_emoji.py writes them
  emojiAtlas = { size = 256, cell = 64, pages = 2 },
  emojiSprites = {
    { name = "gzkush", page = 1, x = 0, y = 0 },
    { name = "joy", page = 1, x = 64, y = 0 },
    { name = "Kek", page = 1, x = 128, y = 0 },
    { name = "WAS", page = 1, x = 192, y = 0 },
    { name = "fire", page = 1, x = 0, y = 64, standard = true },
    { name = "joy", page = 1, x = 64, y = 64, standard = true },
    { name = "skull", page = 2, x = 0, y = 0, standard = true },
  },
  -- The guild emoji "joy" keeps its name: the standard one of that name has no trigger
  emojiTriggerStrings = { gzkush = 1, joy = 2, kek = 3, was = 4, fire = 5, skull = 7 },
}
T.loadAll({ "Addon/Src/Emoji/Emoji.lua", "Addon/Src/Emoji/EmojiChat.lua" }, ns)
local chat = ns.emojiChat

local ATLAS = "|TInterface\\AddOns\\OOOOguildcompanion\\Icons\\Emoji\\Atlas"
local GZKUSH = ATLAS .. "1.png:16:16:0:0:256:256:0:64:0:64|t"
local GUILD_JOY = ATLAS .. "1.png:16:16:0:0:256:256:64:128:0:64|t"
local KEK = ATLAS .. "1.png:16:16:0:0:256:256:128:192:0:64|t"
local WAS = ATLAS .. "1.png:16:16:0:0:256:256:192:256:0:64|t"
local FIRE = ATLAS .. "1.png:16:16:0:0:256:256:0:64:64:128|t"
local SKULL = ATLAS .. "2.png:16:16:0:0:256:256:0:64:0:64|t"

---@param text string
---@return string
local function replace(text)
  return chat:ReplaceEmoji(text)
end

-- The list of the settings window
local all = ns.emoji:GetAll()
T.eq(#all, 4, "the list has the guild emoji only")
T.eq({ all[1].name, all[2].name, all[3].name, all[4].name }, { "gzkush", "joy", "Kek", "WAS" }, "sorted by name")
T.eq(all[3].id, 3, "with the emoji id")
T.eq({ ns.emoji:GetTexture(7) },
  { "Interface\\AddOns\\OOOOguildcompanion\\Icons\\Emoji\\Atlas2.png", 0, 0.25, 0, 0.25 },
  "the texture coordinates of an emoji")

-- The emoji of the guild
T.eq(replace("kek nice"), KEK .. " nice", "a guild emoji is a bare word")
T.eq(replace("KEK, nice"), KEK .. ", nice", "in any letter case, before punctuation")
T.eq(replace(":Kek: nice"), KEK .. " nice", "and takes its two colons")
T.eq(replace("Kek: nice"), KEK .. ": nice", "but not a single colon")
T.eq(replace("kekw"), "kekw", "a longer word is no emoji")
T.eq(replace("lol"), KEK, "an alias of one word")
T.eq(replace("so gz kush all"), "so " .. GZKUSH .. " all", "an alias of several words")
T.eq(replace("gz kushy"), "gz kushy", "which must end at the end of a word")
T.eq(replace("it WAS him"), "it " .. WAS .. " him", "a case sensitive emoji in its exact case")
T.eq(replace("it was him"), "it was him", "and not in another case")

-- The standard emoji
T.eq(replace("the fire is hot"), "the " .. FIRE .. " is hot", "a bare word")
T.eq(replace("FIRE!"), FIRE .. "!", "in any letter case")
T.eq(replace("a :fire: b"), "a " .. FIRE .. " b", "and takes its two colons")
T.eq(replace("a :fire b"), "a :" .. FIRE .. " b", "but not a single one")
T.eq(replace("fire: hot"), FIRE .. ": hot", "a colon after the word is punctuation")
T.eq(replace(":fire::skull:"), FIRE .. SKULL, "two in a row")
T.eq(replace("fireball"), "fireball", "a longer word is no emoji")
T.eq(replace("note:fire"), "note:" .. FIRE, "a word after a colon")
T.eq(replace(":flame: :nosuch:"), ":flame: :nosuch:", "a name that is no trigger stays")
T.eq(replace(":joy:"), GUILD_JOY, "the guild emoji wins over a standard one with its name")
T.eq(replace("|cff00ff00fire|r |Hitem:1|h[fire]|h"), "|cff00ff00" .. FIRE .. "|r |Hitem:1|h[fire]|h",
  "inside a colour, but not inside a link")

-- The settings
ns.emoji:SetEnabled("Kek", false)
T.eq(replace("kek lol fire"), "kek lol " .. FIRE, "a guild emoji which is turned off, with its alias")
ns.emoji:SetEnabled("Kek", true)
T.eq(chat:IsStandardEnabled(), true, "a missing setting of the standard emoji means on")
chat:SetStandardEnabled(false)
T.eq(replace("fire kek"), "fire " .. KEK, "turned off: only the guild emoji")
chat:SetStandardEnabled(true)
T.eq(replace("fire"), FIRE, "turned on again")
chat:SetSize(32)
T.eq(replace("fire"), ATLAS .. "1.png:32:32:0:0:256:256:0:64:64:128|t", "a new size reaches the emoji")

T.finish()
