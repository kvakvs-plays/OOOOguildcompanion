-- Host test of the mentions (.agents/00-plan.md, stage 11; Addon/Src/Chat/Mentions.lua): the watch list,
-- the search for `@` words, the text that the window shows, the list of mentions with its read and unread
-- entries, the notice, and the warning for a mention that nobody can copy.
local T = dofile("Tests/harness.lua")
T.loadLibraries()

local ITEM_LINK = "|cff0070dd|Hitem:4306::::::::60:::::|h[Silk Cloth]|h|r"

--------------------------------------------------------------------------------
-- Step 11.1: the functions that only compute
--------------------------------------------------------------------------------

local mentions = T.load("Addon/Src/Chat/Mentions.lua").mentions

-- parseWatchList
T.eq(mentions.parseWatchList("tall, kvakvs ,scam"), { "tall", "kvakvs", "scam" }, "spaces around commas are cut off")
T.eq(mentions.parseWatchList(""), {}, "an empty setting is an empty list")
T.eq(mentions.parseWatchList(" , ,, "), {}, "and so is one with commas alone")
T.eq(mentions.parseWatchList(nil), {}, "and a setting that is no string")
T.eq(mentions.parseWatchList("tall,Tall, TALL,scam"), { "tall", "scam" }, "a repeated entry is taken once")
T.eq(mentions.parseWatchList("KvaKvs"), { "kvakvs" }, "upper case becomes lower case")
T.eq(mentions.parseWatchList("nota tall, x"), { "nota tall", "x" }, "an entry keeps its inner spaces")
T.eq(mentions.parseWatchList("@tall"), { "tall" }, "an @ before an entry is dropped")

-- hasMention
T.eq(mentions.hasMention("@tall hello"), true, "@word at the start")
T.eq(mentions.hasMention("hello @tall, you there"), true, "@word in the middle")
T.eq(mentions.hasMention("hello @tall"), true, "@word at the end")
T.eq(mentions.hasMention("no mention here"), false, "a line without @")
T.eq(mentions.hasMention("meet @ 8"), false, "a lone @")
T.eq(mentions.hasMention("ends with @"), false, "an @ at the end")
T.eq(mentions.hasMention("mail a@b.c"), true, "an e-mail form counts")
T.eq(mentions.hasMention("look |cff0070dd|Hitem:1::|h[Sword @home]|h|r"), false, "an @ inside an item link does not")
T.eq(mentions.hasMention("look " .. ITEM_LINK .. " @tall"), true, "an @ after a link does")
T.eq(mentions.hasMention("@|cff00ff00tall|r"), false, "an @ before an escape sequence is alone")

-- fragments
do
  local watch = mentions.parseWatchList("kvakvs, tall")
  T.eq(mentions.fragments("@Kvakvs hello", watch), { "@Kvakvs" }, "at the start, returned as written")
  T.eq(mentions.fragments("hello @tall there", watch), { "@tall" }, "in the middle")
  T.eq(mentions.fragments("hello @tall", watch), { "@tall" }, "at the end")
  T.eq(mentions.fragments("hey @tall, come", watch), { "@tall" }, "before a comma")
  T.eq(mentions.fragments("is it @TALL?", watch), { "@TALL" }, "before a question mark, in upper case")
  T.eq(mentions.fragments("@kvakvsy hello", watch), {}, "an entry that is the start of a longer word")
  T.eq(mentions.fragments("@taller", watch), {}, "also at the end of the line")
  T.eq(mentions.fragments("@tall_one", watch), {}, "an underscore is a part of the word")
  T.eq(mentions.fragments("@tall\195\164", watch), {}, "and so is a UTF-8 letter")
  T.eq(mentions.fragments("@Tall and @kvakvs: hi @tall", watch), { "@Tall", "@kvakvs", "@tall" },
    "all watched fragments of a line, in their order")
  T.eq(mentions.fragments("@other hello", watch), {}, "an @ word that is not watched")
  T.eq(mentions.fragments("tall kvakvs", watch), {}, "a watched word without @")
  T.eq(mentions.fragments("@ tall", watch), {}, "the entry must follow the @ directly")
  T.eq(mentions.fragments("@tall", {}), {}, "an empty watch list finds nothing")
  T.eq(mentions.fragments("|cff0070dd|Hitem:1::|h[@tall]|h|r", watch), {}, "an @ inside a link does not count")
  T.eq(mentions.fragments("look @Tall " .. ITEM_LINK, watch), { "@Tall" }, "a mention before a link does")
  T.eq(mentions.fragments("@tall|cff00ff00x|r", watch), { "@tall" }, "an escape sequence ends the word")
  -- "\195\166" is the letter ae; string.lower leaves it alone
  T.eq(mentions.fragments("hi @\195\166z!", mentions.parseWatchList("\195\166z")), { "@\195\166z" },
    "an entry with a UTF-8 letter")
  T.eq(mentions.fragments("@nota tall is here, @Nota", mentions.parseWatchList("nota, nota tall")),
    { "@nota tall", "@Nota" }, "of two entries that match, the longer one is taken")
end

-- sanitize
T.eq(mentions.sanitize("plain text"), "plain text", "a plain text is unchanged")
T.eq(mentions.sanitize("look " .. ITEM_LINK), "look " .. ITEM_LINK, "an item link and a colour code stay")
T.eq(mentions.sanitize("|cnIQ1:|Hitem:4603::|h[Raw Spotted Yellowtail]|h|r"),
  "|cnIQ1:|Hitem:4603::|h[Raw Spotted Yellowtail]|h|r", "a named colour stays")
T.eq(mentions.sanitize("a | b"), "a || b", "a lone | is doubled")
T.eq(mentions.sanitize("ends with |"), "ends with ||", "also at the end")
T.eq(mentions.sanitize("a || b"), "a || b", "a doubled | stays as it is")
T.eq(mentions.sanitize("|TInterface\\Icons\\x:64|t big"), "||TInterface\\Icons\\x:64||t big",
  "a texture escape is doubled")
T.eq(mentions.sanitize("line|nbreak"), "line||nbreak", "and so is a line break")
T.eq(mentions.sanitize("|Hitem:1|h[|TInterface\\x:64|t Sword]|h"), "|Hitem:1|h[||TInterface\\x:64||t Sword]|h",
  "a texture inside the text of a link is doubled")
T.eq(mentions.sanitize("|Hitem:1|h[cut off"), "||Hitem:1||h[cut off", "a link that does not end is no link")
T.eq(mentions.sanitize("|cffff0000red"), "|cffff0000red|r", "a colour that is left open is closed")
T.eq(mentions.sanitize("|cffff0000red|r|r"), "|cffff0000red|r|r", "a spare |r stays")

T.finish()
