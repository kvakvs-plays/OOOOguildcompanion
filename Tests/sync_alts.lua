-- Host test of Addon/Src/Sync/SyncCharacter.lua (the table `character`, alt detection) and of
-- Addon/Src/Sync/SyncCommands.lua (the table `debug`, the /oooo sync commands, the status formatter).
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local ns = T.loadAll({ "Addon/Src/Slash.lua", "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncTables.lua",
  "Addon/Src/Sync/SyncCharacter.lua", "Addon/Src/Sync/SyncCommands.lua" })
local sync, store, versionId = ns.sync, ns.syncStore, ns.versionId
local character, commands = ns.syncCharacter, ns.syncCommands
local random = T.newRandom()

local now = 1795000000

---Lines printed through ns.print since the last call of `printed`
local output = {}
function ns.print(text)
  output[#output + 1] = text
end
local function printed()
  local text = table.concat(output, "\n")
  output = {}
  return text
end

---Applies a character record as if the install `origin` had written it at `seconds`.
local function write(tbl, name, origin, seconds, origins, isTombstone)
  store.apply(tbl, name, versionId.make(now + seconds, origin, 0),
    { class = "MAGE", level = 10, origins = origins or { origin } }, isTombstone)
end

-- validate
do
  local good = { class = "SHAMAN", level = 60, origins = { "AAAA", "BBBB" } }
  T.eq(character.validate("Nota Scam", good), true, "a good payload passes")
  T.eq(character.validate("Nota Scam", { class = "MAGE", level = 1, origins = { "a|3$" } }), true,
    "level 1 and one origin pass")
  for name, bad in pairs({
    ["a payload that is not a table"] = "text",
    ["a missing class"] = { level = 60, origins = { "AAAA" } },
    ["a class in lower case"] = { class = "Shaman", level = 60, origins = { "AAAA" } },
    ["a class of 21 characters"] = { class = string.rep("A", 21), level = 60, origins = { "AAAA" } },
    ["level 0"] = { class = "MAGE", level = 0, origins = { "AAAA" } },
    ["level 61"] = { class = "MAGE", level = 61, origins = { "AAAA" } },
    ["a level with a fraction"] = { class = "MAGE", level = 10.5, origins = { "AAAA" } },
    ["a level that is a string"] = { class = "MAGE", level = "10", origins = { "AAAA" } },
    ["missing origins"] = { class = "MAGE", level = 10 },
    ["no origin"] = { class = "MAGE", level = 10, origins = {} },
    ["nine origins"] = { class = "MAGE", level = 10,
      origins = { "AAAA", "AAAB", "AAAC", "AAAD", "AAAE", "AAAF", "AAAG", "AAAH", "AAAI" } },
    ["an origin of 3 characters"] = { class = "MAGE", level = 10, origins = { "AAA" } },
    ["an origin with a space"] = { class = "MAGE", level = 10, origins = { "AA A" } },
    ["origins that are not sorted"] = { class = "MAGE", level = 10, origins = { "BBBB", "AAAA" } },
    ["a repeated origin"] = { class = "MAGE", level = 10, origins = { "AAAA", "AAAA" } },
    ["origins with a named field"] = { class = "MAGE", level = 10, origins = { "AAAA", extra = "BBBB" } },
    ["an unknown field"] = { class = "MAGE", level = 10, origins = { "AAAA" }, gold = 5 },
  }) do
    T.eq(character.validate("Nota Scam", bad), false, name .. " is rejected")
  end
end

-- buildPayload
do
  T.eq(character.buildPayload("MAGE", 10, "BBBB", nil), { class = "MAGE", level = 10, origins = { "BBBB" } },
    "the first payload lists the own origin")
  local previous = { class = "MAGE", level = 9, origins = { "AAAA", "CCCC" } }
  local payload = character.buildPayload("MAGE", 10, "BBBB", previous)
  T.eq(payload.origins, { "AAAA", "BBBB", "CCCC" }, "the origins of the previous record are joined and sorted")
  T.eq(character.validate("Nota Scam", payload), true, "a built payload passes validate")
  T.eq(character.buildPayload("MAGE", 10, "AAAA", previous).origins, { "AAAA", "CCCC" }, "an origin is listed once")
  local full = { origins = { "AAAA", "AAAB", "AAAC", "AAAD", "AAAE", "AAAF", "AAAG", "AAAH" } }
  local capped = character.buildPayload("MAGE", 10, "zzzz", full)
  T.eq(#capped.origins, 8, "a full list stays at 8 origins")
  T.eq(capped.origins[8], "zzzz", "the own origin stays in a full list")
  T.eq(character.buildPayload("MAGE", 10, "BBBB", { origins = { "bad", 5, "AAAA" } }).origins, { "AAAA", "BBBB" },
    "a previous entry that is not an origin is left out")
end

-- Alts
do
  local tbl = store.newTable(1)
  write(tbl, "Nota Scam", "XXXX", 10)
  write(tbl, "Nota Tall", "XXXX", 20)
  write(tbl, "Other One", "YYYY", 30)
  T.eq(character.alts(tbl, "Nota Scam"), { "Nota Tall" }, "two characters of one origin are alts")
  T.eq(character.alts(tbl, "Nota Tall"), { "Nota Scam" }, "the alt relation holds in both directions")
  T.eq(character.alts(tbl, "Other One"), {}, "a character of another origin is not an alt")
  T.eq(character.alts(tbl, "Never Was"), {}, "an unknown character has no alts")

  -- Origins X and Y both wrote character A: the characters of X and Y are one group
  write(tbl, "Nota Scam", "YYYY", 40, { "XXXX", "YYYY" })
  T.eq(character.alts(tbl, "Nota Scam"), { "Nota Tall", "Other One" },
    "a character that two origins wrote joins the characters of both")
  T.eq(character.alts(tbl, "Nota Tall"), { "Nota Scam", "Other One" }, "the group is found from a character of X")
  T.eq(character.alts(tbl, "Other One"), { "Nota Scam", "Nota Tall" }, "the group is found from a character of Y")

  -- A chain over three origins
  write(tbl, "Third One", "ZZZZ", 50)
  write(tbl, "Bridge", "ZZZZ", 60, { "YYYY", "ZZZZ" })
  T.eq(character.alts(tbl, "Third One"), { "Bridge", "Nota Scam", "Nota Tall", "Other One" },
    "the group is followed over a chain of shared origins")

  -- A tombstoned character is not listed
  write(tbl, "Nota Tall", "XXXX", 70, nil, true)
  T.eq(character.alts(tbl, "Nota Scam"), { "Bridge", "Other One", "Third One" }, "a deleted character is not listed")
  T.eq(character.alts(tbl, "Nota Tall"), {}, "a deleted character has no alts")
end

-- Through the API: two installs of one player, joined by the payload
do
  local data = { origin = "XXXX", tables = {} }
  ---The character that is logged in: a record of the table is written by its own character only
  local player
  local function playerName() return player end
  sync:Initialize(data, function() return now end, random, playerName)
  T.eq(sync:GetAlts("Nota Scam"), {}, "GetAlts of an empty table is empty")
  player = "Nota Scam"
  sync:Put("character", "Nota Scam", character.buildPayload("SHAMAN", 20, "XXXX", sync:Get("character", "Nota Scam")))
  player = "Nota Tall"
  sync:Put("character", "Nota Tall", character.buildPayload("WARRIOR", 60, "XXXX", sync:Get("character", "Nota Tall")))
  -- The second install has pulled the table and writes one of the characters again
  now = now + 100
  data.origin = "YYYY"
  sync:Initialize(data, function() return now end, random, playerName)
  player = "Nota Scam"
  sync:Put("character", "Nota Scam", character.buildPayload("SHAMAN", 21, "YYYY", sync:Get("character", "Nota Scam")))
  player = "Bank Alt"
  sync:Put("character", "Bank Alt", character.buildPayload("ROGUE", 1, "YYYY", sync:Get("character", "Bank Alt")))
  T.eq(sync:Get("character", "Nota Scam").origins, { "XXXX", "YYYY" }, "the record lists both installs")
  T.eq(sync:GetAlts("Bank Alt"), { "Nota Scam", "Nota Tall" }, "GetAlts joins the characters of both installs")
  T.eq(sync:Put("character", "Bank Alt", { class = "ROGUE", level = 61, origins = { "YYYY" } }), nil,
    "the table refuses a payload that fails validate")
end

-- The debug table and the commands
do
  ns.slash:Dispatch("sync put greeting hello there")
  T.eq(printed(), "written: greeting", "put writes a record")
  ns.slash:Dispatch("sync put greeting hello there")
  T.eq(printed(), "unchanged: greeting", "put of the same text changes nothing")
  ns.slash:Dispatch("sync get greeting")
  T.eq(printed(), "greeting = hello there", "get prints the text")
  ns.slash:Dispatch("sync put pipes a|b")
  ns.slash:Dispatch("sync get pipes")
  T.eq(printed(), "written: pipes\npipes = a||b", "get doubles a | in the stored text")
  T.eq(sync:Get("debug", "pipes"), "a|b", "the stored text is unchanged")
  ns.slash:Dispatch("sync del greeting")
  T.eq(printed(), "deleted: greeting", "del deletes the record")
  ns.slash:Dispatch("sync del greeting")
  T.eq(printed(), "no record: greeting", "a second del finds no record")
  ns.slash:Dispatch("sync get greeting")
  T.eq(printed(), "no record: greeting", "get after del finds no record")
  ns.slash:Dispatch("sync put long " .. string.rep("x", 201))
  T.eq(printed(), "not written: bad payload", "a text over 200 characters is refused")
  for _, command in ipairs({ "put", "put onlykey", "get", "get two words", "del", "del two words" }) do
    ns.slash:Dispatch("sync " .. command)
    T.ok(printed():find("^Usage: /oooo sync "), "'" .. command .. "' prints its usage line")
  end
end

-- The status formatter doubles every |
do
  local data = { origin = "a|c|", tables = {} }
  sync:Initialize(data, function() return now end, random)
  sync:Put("debug", "one", "text")
  sync:Put("debug", "two", "text")
  sync:Delete("debug", "two")
  local lines = commands.statusLines()
  T.eq(lines[1], "origin: a||c||", "the status doubles the | of the origin")
  T.eq(#lines, 1 + #sync.names, "the status has one line per table")
  local debugLine
  for _, line in ipairs(lines) do
    T.ok(not line:gsub("||", ""):find("|", 1, true), "every | of a status line is doubled")
    if line:find("^debug: ") then
      debugLine = line
    end
  end
  local version = store.tableVersion(data.tables.debug)
  T.ok(version:find("|", 1, true), "the table version of this test holds a |")
  T.eq(debugLine, "debug: 1 records, 1 deleted, version " .. version:gsub("|", "||"),
    "the status line has the record count and the table version")
  ns.slash:Dispatch("sync status")
  T.eq(printed(), table.concat(lines, "\n"), "the status command prints the lines")
end

T.finish()
