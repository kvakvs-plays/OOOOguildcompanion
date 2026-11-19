-- Host test of the table `profession` (.agents/00-plan.md, section 5.4 and step 12.2;
-- Addon/Src/Professions/ProfessionData.lua), and of the engine with a record near the size of one batch.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local DATA_FILE = "Addon/Src/Professions/ProfessionData.lua"

---Makes a replica that has the table `profession`.
---@param net Fakenet
---@param name string
---@return TestReplica
local function withProfessions(net, name)
  local replica = Replica.new(net, name, { random = random })
  T.load(DATA_FILE, replica.ns)
  return replica
end

---Returns `count` recipe ids in ascending order, spread like real spell ids.
---@param count integer
---@param first integer?
---@return integer[]
local function recipeIds(count, first)
  local ids = {}
  for index = 1, count do
    ids[index] = (first or 2000) + index * 37
  end
  return ids
end

-- Packing: a round trip, the order, and repeated ids
do
  local net = Fakenet.new({ random = random })
  local a = withProfessions(net, "Nota Scam")
  local data = a.ns.professionData
  T.eq(data.packRecipes({}), nil, "no recipes give no field")
  T.eq(data.unpackRecipes(nil), {}, "no field gives no recipes")
  local packed = data.packRecipes({ 18560, 2660, 1229737, 2660, 1 })
  T.eq(#packed, 16, "four ids are 16 characters: a repeated id is packed once")
  T.eq(data.unpackRecipes(packed), { 1, 2660, 18560, 1229737 }, "the round trip gives the ids in ascending order")
  T.eq(data.packRecipes({ 1229737, 1, 18560, 2660 }), packed, "one set of recipes has one text")
  T.eq(data.recipeCount(packed), 4, "the count is read from the length")
  T.eq(data.recipeCount(nil), 0, "no field counts as no recipe")
  T.eq(data.unpackRecipes(data.packRecipes({ data.MAX_ID })), { data.MAX_ID }, "the largest id fits")
  T.eq(data.packRecipes({ 0, -5, 2.5, "2660", data.MAX_ID + 1, 2660 }), data.packRecipes({ 2660 }),
    "a value that is no id is left out")
  local ids = {}
  for index = 1, 300 do
    ids[index] = random(1, 2000000)
  end
  local unpacked = data.unpackRecipes(data.packRecipes(ids))
  local seen = {}
  for _, id in ipairs(ids) do
    seen[id] = true
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  T.eq(#unpacked, distinct, "random ids: every distinct id is packed once")
  for index = 2, #unpacked do
    T.ok(unpacked[index - 1] < unpacked[index] and seen[unpacked[index]], "random ids: ascending and known")
  end
  T.ok(data.isRecipeList(data.packRecipes(ids)), "a packed list passes the check of validate")

  -- The union: a scan only adds
  local stored = data.packRecipes({ 10, 20, 30 })
  T.eq(data.mergeRecipes(stored, { 20 }), stored, "a scan that finds nothing new gives the same text")
  T.eq(data.mergeRecipes(stored, {}), stored, "an empty scan removes nothing")
  T.eq(data.unpackRecipes(data.mergeRecipes(stored, { 25, 5, 30 })), { 5, 10, 20, 25, 30 },
    "new ids are joined in order")
  T.eq(data.unpackRecipes(data.mergeRecipes(nil, { 7 })), { 7 }, "a record without recipes takes the first ones")
  T.eq(data.mergeRecipes(nil, {}), nil, "nothing joined with nothing is no field")
  T.eq(data.unpackRecipes(data.mergeRecipes("broken", { 7 })), { 7 }, "a damaged stored list counts as empty")

  -- The key
  T.eq(data.key("Nota Scam", 171), "Nota Scam:171", "the key joins the name and the profession id")
  T.eq({ data.parseKey("Nota Scam:171") }, { "Nota Scam", 171 }, "and is split at the colon, not at the space")
  T.eq({ data.parseKey("Æz Clap:333") }, { "Æz Clap", 333 }, "a name with a UTF-8 letter")
  for _, bad in ipairs({ "Nota Scam", "Nota Scam:", ":171", "Nota Scam:abc", "Nota Scam:17.5", "Nota Scam:-1",
    "Nota Scam:0171", "Nota Scam:0", "Nota Scam:171:2", "Nota Scam:1000000", "Nota Scam: 171", 171 }) do
    T.eq(data.parseKey(bad), nil, "the key " .. tostring(bad) .. " is refused")
  end
end

-- validate
do
  local net = Fakenet.new({ random = random })
  local a = withProfessions(net, "Nota Scam")
  local data, base94 = a.ns.professionData, a.ns.base94
  local key = "Nota Scam:171"
  local recipes = data.packRecipes({ 2660, 18560 })
  ---Builds a good payload with some fields replaced; the value `false` removes a field.
  local function payload(changes)
    local result = { l = 275, m = 300, r = recipes }
    for field, value in pairs(changes or {}) do
      if value == false then
        result[field] = nil
      else
        result[field] = value
      end
    end
    return result
  end
  T.ok(data.validate(key, payload()), "a full payload passes")
  T.ok(data.validate(key, payload({ r = false })), "a profession without recipes passes")
  T.ok(data.validate(key, payload({ s = 9788 })), "a specialization passes")
  T.ok(data.validate(key, payload({ l = 1, m = 1 })), "level 1 passes")
  T.ok(data.validate(key, payload({ l = 450, m = 450 })), "level 450 passes")
  local bad = {
    ["no table"] = "text",
    ["a level of 0"] = payload({ l = 0 }),
    ["a level over the range"] = payload({ l = 451 }),
    ["a fraction as level"] = payload({ l = 274.5 }),
    ["a text as level"] = payload({ l = "275" }),
    ["no level"] = payload({ l = false }),
    ["a maximum of 0"] = payload({ m = 0 }),
    ["a fraction as maximum"] = payload({ m = 300.5 }),
    ["no maximum"] = payload({ m = false }),
    ["a specialization of 0"] = payload({ s = 0 }),
    ["a fraction as specialization"] = payload({ s = 9788.5 }),
    ["an unknown field"] = payload({ name = "Alchemy" }),
    ["a list as recipes"] = payload({ r = { 2660 } }),
    ["an empty recipe text"] = payload({ r = "" }),
    ["a wrong length"] = payload({ r = recipes .. "!!" }),
    ["a character outside base 94"] = payload({ r = recipes:sub(1, 7) .. " " }),
    ["a descending id"] = payload({ r = base94.encode(18560, 4) .. base94.encode(2660, 4) }),
    ["a repeated id"] = payload({ r = base94.encode(2660, 4) .. base94.encode(2660, 4) }),
    ["the id 0"] = payload({ r = base94.encode(0, 4) .. base94.encode(2660, 4) }),
  }
  for name, value in pairs(bad) do
    T.eq(data.validate(key, value), false, name .. " is refused")
  end
  T.eq(data.validate("Nota Scam", payload()), false, "a key without profession id is refused")
  T.eq(data.validate("Nota Scam:x", payload()), false, "a key with a profession id that is no number is refused")

  -- Through the API: the owner rule on the joined key, and the size limit
  T.eq(a.sync:Put("profession", key, payload()), true, "a Put for the own character works")
  T.eq(a.sync:Put("profession", key, payload()), false, "an equal payload writes nothing")
  T.eq({ a.sync:Put("profession", "Nota Scamp:171", payload()) }, { nil, "not the owner" },
    "a name that only starts like the own is refused")
  T.eq({ a.sync:Put("profession", "Other One:171", payload()) }, { nil, "not the owner" },
    "a record of another character is refused")
  T.eq({ a.sync:Put("profession", "Nota Scam", payload()) }, { nil, "bad payload" },
    "a key without profession id is refused by validate")
  T.eq({ a.sync:Put("profession", key, payload({ l = 0 })) }, { nil, "bad payload" }, "a bad payload is refused")
  T.eq(a.sync:Put("profession", "Nota Scam:197", payload({ r = data.packRecipes(recipeIds(450)) })), true,
    "a record with 450 recipes fits")
  T.eq({ a.sync:Put("profession", "Nota Scam:164", payload({ r = data.packRecipes(recipeIds(500)) })) },
    { nil, "too large" }, "one with 500 recipes is over the size of a record")
  local definition = a.sync.definitions.profession
  T.eq({ definition.keyKind, definition.writers, definition.maxRecordBytes, definition.policy.minInterval },
    { "character", "owner", 2000, 900 }, "the definition of the table")
end

-- The engine with records near and over the size of one batch
do
  ---The definition of a table whose records can be larger than one batch
  local function bigDefinition()
    return { name = "big", schema = 1, keyKind = "free", maxRecordBytes = 3000, writers = "anyone",
      validate = function(_key, payload) return type(payload) == "string" end,
      policy = { when = "nocombat", pushDelay = 10, minInterval = 30 } }
  end
  local net = Fakenet.new({ random = random })
  local a = withProfessions(net, "Nota Scam")
  local b = withProfessions(net, "Other One")
  local c = withProfessions(net, "Third One")
  for _, replica in ipairs({ a, b, c }) do
    replica.sync:RegisterTable(bigDefinition())
  end
  net:SetOnline("Third One", false)
  local store, data = a.ns.syncStore, a.ns.professionData
  local near, over = string.rep("n", 1900), string.rep("o", 2500)

  -- splitBatches: neither record shares a batch
  local records = {
    { key = "small1", id = a.ns.versionId.make(1795000000, "XXXX", 0), payload = "small" },
    { key = "near", id = a.ns.versionId.make(1795000000, "XXXX", 1), payload = near },
    { key = "over", id = a.ns.versionId.make(1795000000, "XXXX", 2), payload = over },
    { key = "small2", id = a.ns.versionId.make(1795000000, "XXXX", 3), payload = "small" },
  }
  local nearSize, overSize = store.recordSize(records[2]), store.recordSize(records[3])
  T.ok(nearSize >= 1900 and nearSize <= 2000, "the first large record is just under the batch size: " .. nearSize)
  T.ok(overSize > 2000, "the second one is over it")
  local batches = store.splitBatches(records, 2000)
  local shape = {}
  for index, batch in ipairs(batches) do
    shape[index] = #batch
  end
  T.eq(shape, { 2, 1, 1 }, "the record over the batch size gets a batch of its own, the one near it fills one")
  T.eq({ batches[1][2].key, batches[2][1].key, batches[3][1].key }, { "near", "over", "small2" },
    "in the order of the records")

  -- A push carries both, and the largest record of the table `profession`
  a:Login()
  b:Login()
  net:Advance(100)
  local professionKey = data.key("Nota Scam", 197)
  local recipes = data.packRecipes(recipeIds(450))
  T.eq(a.sync:Put("big", "near", near), true, "the record near the batch size is written")
  T.eq(a.sync:Put("big", "over", over), true, "and the one over it")
  T.eq(a.sync:Put("profession", professionKey, { l = 300, m = 300, r = recipes }), true, "and a full profession")
  local professionSize = store.recordSize({ key = professionKey, payload = a.sync:Get("profession", professionKey) })
  T.ok(professionSize > 1800 and professionSize <= 2000, "the profession record is near the batch size: "
    .. professionSize)
  net:Advance(2000)
  T.eq(b.sync:Get("big", "near"), near, "a push carries the record near the batch size")
  T.eq(b.sync:Get("big", "over"), over, "and the one over it")
  T.eq(b.sync:Get("profession", professionKey), { l = 300, m = 300, r = recipes },
    "and the profession record, whole")
  T.eq(b:Version("big"), a:Version("big"), "both replicas have the same version of the table")
  T.eq(b:Version("profession"), a:Version("profession"), "and of the table profession")

  -- A pull carries them to a replica that was offline
  c:Login()
  net:Advance(1000)
  T.eq(c.sync:Get("big", "near"), near, "a pull carries the record near the batch size")
  T.eq(c.sync:Get("big", "over"), over, "and the one over it")
  T.eq(data.unpackRecipes(c.sync:Get("profession", professionKey).r), recipeIds(450),
    "and the 450 recipes of the profession record")
  T.eq(c:Version("big"), a:Version("big"), "the third replica has the same version of the table")
  T.eq(c:Version("profession"), a:Version("profession"), "and of the table profession")
  T.eq(c.session.pull, nil, "no pull is left running")

  -- A foreign record with a bad recipe list is dropped by the receiver
  local versionId = b.ns.versionId
  local raw = net:Join("Raw One")
  local now = math.floor(net:Now())
  local other = versionId.make(now - 5, "RRRR", 0) .. "!!!!!"
  raw:Send(Replica.codec.encode("P", "profession", 1, other, other, true, { QQQQ = versionId.ZERO },
    Replica.protocol.packRecords({
      { key = "Raw One:171", id = versionId.make(now - 90, "QQQQ", 1), payload = { l = 10, m = 75, r = "!!!$!!!#" } },
    }), nil), "GUILD")
  net:Advance(1)
  T.eq(b.sync:Get("profession", "Raw One:171"), nil, "a received record with a descending recipe list is dropped")
  raw:Send(Replica.codec.encode("P", "profession", 1, other, other, true, { QQQQ = versionId.ZERO },
    Replica.protocol.packRecords({
      { key = "Raw One:171", id = versionId.make(now - 80, "QQQQ", 2), payload = { l = 10, m = 75, r = "!!!#!!!$" } },
    }), nil), "GUILD")
  net:Advance(1)
  T.eq(b.sync:Get("profession", "Raw One:171"), { l = 10, m = 75, r = "!!!#!!!$" }, "a good one is stored")
end

T.finish()
