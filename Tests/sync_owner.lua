-- Host test of the owner rule (.agents/00-plan.md, section 5.2): `ns.sync:MayWrite` in
-- Addon/Src/Sync/SyncTables.lua, as `Put`, `Delete`, and the receiver of a push in SyncPush.lua use it.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec

---The definition of an owner table whose keys are a character name, or a name and a number
local function gearDefinition()
  return {
    name = "gear",
    schema = 1,
    keyKind = "character",
    validate = function(_key, payload)
      return type(payload) == "number"
    end,
    maxRecordBytes = 200,
    writers = "owner",
  }
end

-- Put and Delete: only keys of the logged-in character
do
  local ns = T.loadAll({ "Addon/Src/Slash.lua", "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
    "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncTables.lua",
    "Addon/Src/Sync/SyncCharacter.lua" })
  local sync, store, versionId = ns.sync, ns.syncStore, ns.versionId
  local now = 1795000000
  local player = "Nota Scam"
  sync:RegisterTable(gearDefinition())
  sync:RegisterTable({ name = "open", schema = 1, keyKind = "free", validate = function() return true end,
    maxRecordBytes = 200, writers = "anyone" })
  local data = { origin = "XXXX", tables = {} }
  sync:Initialize(data, function() return now end, random, function() return player end)
  local tbl = data.tables.gear

  T.eq(sync:Put("gear", "Nota Scam", 1), true, "a Put for the own character works")
  T.eq(sync:Put("gear", "Nota Scam:171", 2), true, "a Put with a joined key of the own character works")
  local before = store.tableVersion(tbl)
  T.eq({ sync:Put("gear", "Other One", 1) }, { nil, "not the owner" }, "a Put for another name is refused")
  T.eq({ sync:Put("gear", "Other One:171", 1) }, { nil, "not the owner" },
    "a joined key is checked by its name part")
  T.eq({ sync:Put("gear", "Nota Scamp", 1) }, { nil, "not the owner" },
    "a name that only starts like the own is refused")
  T.eq({ sync:Put("gear", ":171", 1) }, { nil, "not the owner" }, "a key without a name is refused")
  T.eq(store.tableVersion(tbl), before, "a refused Put makes no new id")
  T.eq(tbl.records["Other One"], nil, "and stores nothing")

  -- A record of another character, as a pull brings it
  local foreign = versionId.make(now - 10, "YYYY", 0)
  store.apply(tbl, "Other One", foreign, 5)
  before = store.tableVersion(tbl)
  T.eq({ sync:Delete("gear", "Other One") }, { nil, "not the owner" }, "a Delete for another name is refused")
  T.eq(store.tableVersion(tbl), before, "a refused Delete makes no new id")
  T.eq(sync:Get("gear", "Other One"), 5, "and the record stays")
  T.eq(sync:Delete("gear", "Nota Scam:171"), true, "a Delete for the own character works")

  -- An alt of the same install is still another character: one character writes at a time
  sync:Put("character", "Nota Scam", { class = "MAGE", level = 10, origins = { "XXXX" } })
  player = "Nota Tall"
  sync:Put("character", "Nota Tall", { class = "MAGE", level = 10, origins = { "XXXX" } })
  T.eq(sync:IsAltOf("Nota Scam", "Nota Tall"), true, "the two characters are alts")
  T.eq({ sync:Put("gear", "Nota Scam", 9) }, { nil, "not the owner" }, "a Put for an alt is refused")
  T.eq(sync:Put("gear", "Nota Tall", 9), true, "the character that is logged in now can write")

  -- A character whose name is not readable writes nothing
  player = nil
  T.eq({ sync:Put("gear", "Nota Tall", 10) }, { nil, "not the owner" }, "without a character name nothing is written")

  -- A table for every member has no owner rule
  T.eq(sync:Put("open", "Other One", 1), true, "a table with writers = anyone takes every key")

  -- shareOrigin: no chain over a third character
  local characters = data.tables.character
  store.apply(characters, "Bridge", versionId.make(now, "ZZZZ", 0),
    { class = "MAGE", level = 1, origins = { "XXXX", "ZZZZ" } })
  store.apply(characters, "Far One", versionId.make(now, "ZZZZ", 1),
    { class = "MAGE", level = 1, origins = { "ZZZZ" } })
  T.eq(sync:IsAltOf("Bridge", "Nota Scam"), true, "an origin in the payload counts")
  T.eq(sync:IsAltOf("Far One", "Bridge"), true, "the writer of the record counts")
  T.eq(sync:IsAltOf("Far One", "Nota Scam"), false, "a chain over a third character does not")
  T.eq(sync:IsAltOf("Never Was", "Nota Scam"), false, "an unknown character is nobody's alt")
end

-- A push of own writes: the receiver checks every key against the sender
do
  local net = Fakenet.new({ random = random })
  local b = Replica.new(net, "Other One", { random = random })
  b.sync:RegisterTable(gearDefinition())
  b:Login()
  net:Advance(100)
  local versionId = b.ns.versionId
  local scam, tall = net:Join("Nota Scam"), net:Join("Nota Tall")
  local gear = b.sync:GetTable("gear")
  local now = math.floor(net:Now())
  local zero = versionId.ZERO
  local other = versionId.make(now - 5, "RRRR", 0) .. "!!!!!"
  local counter = 0
  ---Makes the next id of an origin.
  local function id(origin)
    counter = counter + 1
    return versionId.make(now - 90, origin, counter)
  end
  ---Sends a push of one origin with the zero base, which is never a gap.
  local function send(from, tableName, own, origin, records)
    from:Send(codec.encode("P", tableName, 1, other, other, own, { [origin] = zero },
      Replica.protocol.packRecords(records), nil), "GUILD")
    net:Advance(1)
  end

  local own1 = id("XXXX")
  send(scam, "gear", true, "XXXX", { { key = "Nota Scam", id = own1, payload = 1 } })
  T.eq(b.sync:Get("gear", "Nota Scam"), 1, "a push from A with A's key is applied")
  local joined = id("XXXX")
  send(scam, "gear", true, "XXXX", { { key = "Nota Scam:171", id = joined, payload = 2 } })
  T.eq(b.sync:Get("gear", "Nota Scam:171"), 2, "a joined key of the sender is applied")

  -- The alt is unknown until the table `character` lists both characters under one origin
  local early = id("XXXX")
  send(scam, "gear", true, "XXXX", { { key = "Nota Tall", id = early, payload = 3 } })
  T.eq(b.sync:Get("gear", "Nota Tall"), nil, "a key of a character that is not known as an alt is dropped")
  T.eq(gear.clock.XXXX, joined, "and the clock does not pass it")
  local payload = { class = "MAGE", level = 10, origins = { "XXXX" } }
  send(scam, "character", true, "XXXX", { { key = "Nota Scam", id = id("XXXX"), payload = payload } })
  send(tall, "character", true, "XXXX", { { key = "Nota Tall", id = id("XXXX"), payload = payload } })
  T.eq(b.sync:IsAltOf("Nota Tall", "Nota Scam"), true, "the receiver now knows the two as alts")
  send(scam, "gear", true, "XXXX", { { key = "Nota Tall", id = id("XXXX"), payload = 3 } })
  T.eq(b.sync:Get("gear", "Nota Tall"), 3, "a push from A with the key of A's alt is applied")
  send(scam, "gear", true, "XXXX", { { key = "Nota Tall:9", id = id("XXXX"), payload = 4 } })
  T.eq(b.sync:Get("gear", "Nota Tall:9"), 4, "also with a joined key")

  -- A foreign key: dropped together with the later records of that origin
  local good, bad, late = id("XXXX"), id("XXXX"), id("XXXX")
  send(scam, "gear", true, "XXXX", {
    { key = "Nota Scam", id = good, payload = 5 },
    { key = "Other One", id = bad, payload = 6 },
    { key = "Nota Scam:171", id = late, payload = 7 },
  })
  T.eq(b.sync:Get("gear", "Nota Scam"), 5, "the record before the foreign key is applied")
  T.eq(b.sync:Get("gear", "Other One"), nil, "a push from A with B's key is dropped")
  T.eq(b.sync:Get("gear", "Nota Scam:171"), 2, "together with the later records of that origin")
  T.eq(gear.clock.XXXX, good, "the clock stays before the dropped record")
  T.ok(b.session.delayedPullTimer, "the receiver has a pull scheduled, because the versions still differ")

  -- A character table cannot be claimed either: the first record of a name comes from that name
  send(scam, "character", true, "XXXX", { { key = "Third One", id = id("XXXX"), payload = payload } })
  T.eq(b.sync:Get("character", "Third One"), nil, "a character record for another name is dropped")

  -- Records that are passed on after a pull cannot be checked
  net:Join("Third One")
  send(scam, "gear", false, "WWWW", { { key = "Third One", id = id("WWWW"), payload = 8 } })
  T.eq(b.sync:Get("gear", "Third One"), 8, "a push that passes records on is applied with any key")
end

T.finish()
