-- Host test of the self tables (.agents/00-plan.md, sections 14.3 and 14.4): the character origins and the
-- push marks per origin (step 13.3) in Addon/Src/Sync/SyncTables.lua and SyncPush.lua.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local random = T.newRandom()
local FILES = { "Addon/Src/Slash.lua", "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncTables.lua",
  "Addon/Src/Sync/SyncCharacter.lua" }

---The definition of a self table with a text payload
local function selfDefinition()
  return { name = "mine", schema = 1, keyKind = "character", writers = "self", maxRecordBytes = 200,
    validate = function(_key, payload) return type(payload) == "string" end }
end

---Loads a registry with the table `mine` and a free table `open`, and connects it to a stored database.
---@param data table
---@param playerName fun(): string|nil
---@param now fun(): integer
---@return table sync
---@return table ns
local function newSync(data, playerName, now)
  local ns = T.loadAll(FILES)
  ns.sync:RegisterTable(selfDefinition())
  ns.sync:RegisterTable({ name = "open", schema = 1, keyKind = "free", writers = "anyone", maxRecordBytes = 200,
    validate = function() return true end })
  ns.sync:Initialize(data, now, random, playerName)
  return ns.sync, ns
end

-- The registry: a self table is keyed by character
do
  local ns = T.loadAll(FILES)
  local definition = selfDefinition()
  definition.keyKind = "free"
  T.raises(function() ns.sync:RegisterTable(definition) end, "a self table with free keys is refused", "writers")
  ns.sync:RegisterTable(selfDefinition())
  T.eq(ns.sync.definitions.mine.writers, "self", "a self table keyed by character is accepted")
  T.eq(ns.sync:IsProtected("mine"), true, "and is protected")
  T.eq(ns.sync:IsProtected("character"), false, "an owner table is not")
end

-- Character origins: one per install and character, the install origin elsewhere
do
  local data = { origin = "XXXX", tables = {} }
  local player = "Nota Scam" ---@type string|nil
  local clock = 1795000000
  local sync, ns = newSync(data, function() return player end, function() return clock end)
  local base94, versionId = ns.base94, ns.versionId
  local scam = sync:OriginFor("mine")
  T.eq(scam, base94.encode(base94.hash("XXXX:Nota Scam") % 78074896, 4), "the origin is the hash of install and name")
  T.eq(#scam, 4, "of 4 characters")
  T.ok(base94.isValid(scam), "of base 94")
  T.eq(sync:OriginFor("open"), "XXXX", "another table has the install origin")
  T.eq(sync:OriginFor("character"), "XXXX", "also an owner table")
  T.eq(sync:OriginFor("no_such_table"), nil, "a table that is not registered has none")
  player = "Nota Tall"
  local tall = sync:OriginFor("mine")
  T.ok(tall ~= scam and tall ~= "XXXX", "an alt of the same install has another origin")
  player = nil
  T.eq(sync:OriginFor("mine"), nil, "without the name of the character there is no origin")
  T.eq({ sync:Put("mine", "Nota Scam", "text") }, { nil, "not ready" }, "and a write is refused as not ready")
  T.eq(sync:NewId("mine"), nil, "and NewId gives nothing")
  T.eq(sync:Put("open", "key", "text"), true, "another table is written without the name")

  -- Ids: of the origin of the table, increasing
  player = "Nota Scam"
  local previous = versionId.ZERO
  for index = 1, 20 do
    T.eq(sync:Put("mine", "Nota Scam:" .. index, "text"), true, "a write under the own name works")
    local id = sync:GetId("mine", "Nota Scam:" .. index)
    T.eq(versionId.originOf(id), scam, "its id has the character origin")
    T.ok(id > previous, "the ids of one origin increase")
    previous = id
    if index % 5 == 0 then
      -- Other origins write in between, also in the same second
      ns.syncStore.apply(data.tables.mine, "Other One", versionId.make(clock + 1, "ZZZZ", index), "x")
    end
  end
  T.eq(versionId.originOf(sync:GetId("open", "key")), "XXXX", "the id in another table has the install origin")
  T.eq(versionId.originOf(sync:NewId("mine")), scam, "NewId of a self table has the character origin")
  T.eq(versionId.originOf(sync:NewId("open")), "XXXX", "and of another table the install origin")
  player = "Nota Tall"
  T.eq(sync:Put("mine", "Nota Tall", "alt"), true, "the alt writes under its own name")
  local altId = sync:GetId("mine", "Nota Tall")
  T.eq(versionId.originOf(altId), tall, "with its own origin")
  T.ok(altId > previous, "above everything that the table has seen")
  T.eq(data.tables.mine.clock[scam], previous, "the clock keeps one entry per character")
  T.eq(data.tables.mine.clock[tall], altId, "and one for the alt")

  -- Another session of the same install: the same origins
  clock = clock + 3600
  local again = newSync(data, function() return "Nota Scam" end, function() return clock end)
  T.eq(again:OriginFor("mine"), scam, "the origin of a character is the same in every session")
  T.eq(again:Put("mine", "Nota Scam:again", "text"), true, "and a write after the login works")
  T.ok(again:GetId("mine", "Nota Scam:again") > previous, "with an id above the earlier ones")
  T.eq(versionId.originOf(again:GetId("mine", "Nota Scam:again")), scam, "of the same origin")
  local other = newSync({ origin = "YYYY", tables = {} }, function() return "Nota Scam" end,
    function() return clock end)
  T.ok(other:OriginFor("mine") ~= scam, "the same name on another install has another origin")
end

-- The push mark of a character origin is kept per origin; the install origin keeps `pushed`
do
  local Fakenet = dofile("Tests/fakenet.lua")
  local Replica = dofile("Tests/fixtures/replica.lua")(T)
  local net = Fakenet.new({ random = random })
  local function withMine(name, rankIndex)
    local made = Replica.new(net, name, { random = random, rankIndex = rankIndex })
    local definition = selfDefinition()
    definition.policy = { pushDelay = 10, minInterval = 30 }
    made.sync:RegisterTable(definition)
    return made
  end
  -- The writer is an officer: in this step a self table takes only what an officer sends
  local a, b = withMine("Nota Scam", 0), withMine("Other One")
  a:Login()
  b:Login()
  net:Advance(100)
  a.sync:Put("mine", "Nota Scam", "text")
  a.sync:Put("debug", "key", "text")
  net:Advance(60)
  local mine, debug = a.sync:GetTable("mine"), a.sync:GetTable("debug")
  local origin = a.sync:OriginFor("mine")
  T.eq(mine.pushedBy, { [origin] = mine.clock[origin] }, "the push mark of the character origin is kept per origin")
  T.eq(mine.pushed, nil, "the mark of the install origin is not touched")
  T.eq(debug.pushed, debug.clock[a.sync:GetOrigin()], "another table keeps its mark in pushed")
  T.eq(b.sync:Get("mine", "Nota Scam"), "text", "the record arrives")
  local count = Replica.count(net, "P", "Nota Scam")
  a:Logout()
  net:Advance(10)
  a:Login()
  net:Advance(200)
  T.eq(Replica.count(net, "P", "Nota Scam"), count, "after the next login nothing is pushed again")
  a.sync:Reset("mine")
  T.eq(mine.pushedBy, { [origin] = mine.pushedBy[origin] }, "an emptied table keeps the push mark")
end

T.finish()
