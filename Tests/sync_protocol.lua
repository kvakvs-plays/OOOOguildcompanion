-- Host test of Addon/Src/Sync/SyncProtocol.lua: the envelope and the types H and S. Every case runs with
-- the stub serializer and with the embedded AceSerializer-3.0, which loads on the host.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
-- AceSerializer writes a number that has no short decimal form with these two; Lua 5.4 has dropped them
rawset(math, "frexp", rawget(math, "frexp") or function(value)
  if value == 0 or value ~= value or value == math.huge or value == -math.huge then
    return value, 0
  end
  local exponent = math.floor(math.log(math.abs(value), 2)) + 1
  return value / 2 ^ exponent, exponent
end)
rawset(math, "ldexp", rawget(math, "ldexp") or function(mantissa, exponent)
  return mantissa * 2 ^ exponent
end)
assert(loadfile("Addon/Ace3/AceSerializer-3.0/AceSerializer-3.0.lua"))()
local ns = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua",
  "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncProtocol.lua" })
local protocol = ns.syncProtocol
local random = T.newRandom()

local serializers = {
  stub = dofile("Tests/fixtures/stub_serializer.lua"),
  ace = _G.LibStub("AceSerializer-3.0"),
}

---A table version of 16 valid characters, with the two characters that AceSerializer escapes
local VERSION_A = "!!!!!aB3$!!~^~~~"
local VERSION_B = "5k|Q2aB3$7x!!!!z"

T.eq(#VERSION_A, 16, "the test version has 16 characters")
T.eq(protocol.CHANNELS.H, "GUILD", "a hello travels on GUILD")
T.eq(protocol.CHANNELS.S, "GUILD", "a summary travels on GUILD")

for label, serializer in pairs(serializers) do
  local codec = protocol.new(serializer)
  local function name(text)
    return label .. ": " .. text
  end
  ---Decodes a message that is serialized as given, without the checks of `encode`.
  local function decodeRaw(...)
    return codec.decode(serializer:Serialize(...))
  end

  -- Round trips
  do
    local versions = { character = VERSION_A, debug = VERSION_B }
    for _, messageType in ipairs({ "H", "S" }) do
      local text = codec.encode(messageType, versions)
      T.eq(type(text), "string", name("encode gives a string"))
      local decodedType, fields = codec.decode(text)
      T.eq(decodedType, messageType, name("the type of " .. messageType .. " comes back"))
      T.eq(fields, versions, name("the versions of " .. messageType .. " come back"))
      T.ok(fields ~= versions, name("the decoded table is a new one"))
    end
    T.eq({ codec.decode(codec.encode("H", {})) }, { "H", {} }, name("a hello without tables is valid"))
    local full = {}
    for index = 1, 64 do
      full["table" .. index] = VERSION_A
    end
    T.eq({ codec.decode(codec.encode("S", full)) }, { "S", full }, name("64 tables are accepted"))
    T.eq({ decodeRaw(1, "H", { [string.rep("n", 32)] = VERSION_A }) },
      { "H", { [string.rep("n", 32)] = VERSION_A } }, name("a table name of 32 characters is accepted"))
    T.eq((decodeRaw(1, "H", { debug = VERSION_A }, "extra")), "H", name("a field after the known ones is ignored"))
  end

  -- Refusals: nil and a reason, without raising
  do
    local tooMany = {}
    for index = 1, 65 do
      tooMany["table" .. index] = VERSION_A
    end
    local refused = {
      ["text that is not serialized data"] = "hello there",
      ["an empty text"] = "",
      ["a number in place of the text"] = 5,
      ["nil in place of the text"] = false,
      ["an unknown type"] = serializer:Serialize(1, "Z", {}),
      ["a type that is a number"] = serializer:Serialize(1, 7, {}),
      ["a type of two characters"] = serializer:Serialize(1, "HS", {}),
      ["a missing type"] = serializer:Serialize(1),
      ["a missing field"] = serializer:Serialize(1, "H"),
      ["a number in place of the table"] = serializer:Serialize(1, "H", 5),
      ["a string in place of the table"] = serializer:Serialize(1, "S", VERSION_A),
      ["65 entries"] = serializer:Serialize(1, "H", tooMany),
      ["a version of 15 characters"] = serializer:Serialize(1, "H", { debug = VERSION_A:sub(1, 15) }),
      ["a version of 17 characters"] = serializer:Serialize(1, "H", { debug = VERSION_A .. "!" }),
      ["a version with a space"] = serializer:Serialize(1, "H", { debug = "!!!!!aB3$ !~^~~~" }),
      ["a version with a byte above 126"] = serializer:Serialize(1, "H", { debug = "!!!!!aB3$\200!~^~~~" }),
      ["a version that is a number"] = serializer:Serialize(1, "H", { debug = 1234567890123456 }),
      ["a table name that is a number"] = serializer:Serialize(1, "H", { [1] = VERSION_A }),
      ["an empty table name"] = serializer:Serialize(1, "H", { [""] = VERSION_A }),
      ["a table name of 33 characters"] = serializer:Serialize(1, "H", { [string.rep("n", 33)] = VERSION_A }),
      ["one bad entry among good ones"] = serializer:Serialize(1, "H", { character = VERSION_A, debug = "short" }),
      ["a protocol version that is a string"] = serializer:Serialize("1", "H", {}),
      ["protocol version 0"] = serializer:Serialize(0, "H", {}),
      ["a protocol version with a fraction"] = serializer:Serialize(1.5, "H", {}),
      ["a missing protocol version"] = serializer:Serialize(),
    }
    for case, text in pairs(refused) do
      local succeeded, messageType, reason = pcall(codec.decode, text or nil)
      T.ok(succeeded, name(case .. " does not raise"))
      T.eq(messageType, nil, name(case .. " is refused"))
      T.eq(type(reason), "string", name(case .. " gives a reason"))
      T.ok(reason ~= protocol.NEWER, name(case .. " is not taken for a newer version"))
    end
  end

  -- A newer protocol version
  do
    T.eq({ decodeRaw(protocol.VERSION + 1, "H", { debug = VERSION_A }) }, { nil, "newer" },
      name("a greater protocol version gives the reason newer"))
    T.eq({ decodeRaw(protocol.VERSION + 1, "Z", "anything") }, { nil, "newer" },
      name("a newer version is reported before its unknown type"))
  end

  -- Random input never raises
  do
    for _ = 1, 1000 do
      local bytes = {}
      for index = 1, random(0, 60) do
        bytes[index] = string.char(random(0, 255))
      end
      local text = table.concat(bytes)
      local succeeded, messageType = pcall(codec.decode, text)
      T.ok(succeeded and messageType == nil, name("random bytes are refused without an error"))
    end
    -- Valid messages with one byte changed, cut, or doubled
    local valid = codec.encode("H", { character = VERSION_A, debug = VERSION_B })
    for _ = 1, 1000 do
      local position = random(1, #valid)
      local kind = random(1, 3)
      local text
      if kind == 1 then
        text = valid:sub(1, position - 1) .. string.char(random(0, 255)) .. valid:sub(position + 1)
      elseif kind == 2 then
        text = valid:sub(1, position - 1)
      else
        text = valid:sub(1, position) .. valid:sub(position)
      end
      local succeeded, messageType, fields = pcall(codec.decode, text)
      T.ok(succeeded, name("a damaged message does not raise"))
      if messageType ~= nil then
        -- A change inside a name or a version can leave a valid message; its fields must still be checked
        -- The type byte can turn into "A" (here), which takes no fields and so passes with any
        T.ok(messageType == "H" or messageType == "S" or messageType == "A",
          name("a damaged message that passes has a known type"))
        for tableName, version in pairs(fields) do
          T.ok(type(tableName) == "string" and #tableName <= 32, name("a passed table name is short"))
          T.ok(#version == 16 and ns.base94.isValid(version), name("a passed version is valid"))
        end
      end
    end
  end
end

-- The pull types Q, D, and B
T.eq({ protocol.CHANNELS.Q, protocol.CHANNELS.D, protocol.CHANNELS.B }, { "WHISPER", "WHISPER", "WHISPER" },
  "the pull types travel as whispers")

local ID_A = "5k|Q2aB3$!!"
local ID_B = "5k|Q3cD4~^^"
local ID_C = "5k|Q4aB3$!#"
local ZERO = ns.versionId.ZERO

---Returns a copy of a list with one entry replaced; `REMOVE` takes the entry and all later ones away.
local REMOVE = {}
local function with(list, index, value)
  local copy = {}
  for position = 1, #list do
    copy[position] = list[position]
  end
  if value == REMOVE then
    for position = index, #list do
      copy[position] = nil
    end
    return copy, index - 1
  end
  copy[index] = value
  return copy, math.max(#list, index)
end

for label, serializer in pairs(serializers) do
  local codec = protocol.new(serializer)
  local function name(text)
    return label .. ": " .. text
  end

  local records = {
    { key = "Nota Scam", id = ID_A, payload = { class = "SHAMAN", level = 60, origins = { "aB3$" } } },
    { key = "Gone", id = ID_B, tombstone = true },
    { key = "text", id = ID_C, payload = "a ^ and a ~ and a |" },
    { key = "flag", id = ID_C, payload = false },
  }
  ---The fields of a valid message of each type, in the order of the wire
  local valid = {
    Q = { "debug", 1, 12345, ID_A .. ID_B },
    D = { "debug", 12345, 3, true, protocol.packRecords(records), { ["cD4~"] = ID_B },
      { ["aB3$"] = ID_A, zzzz = ZERO } },
    B = { "debug", 12345, "busy", 30 },
  }

  -- Round trips
  do
    T.eq({ codec.decode(codec.encode("Q", table.unpack(valid.Q))) },
      { "Q", { table = "debug", schema = 1, nonce = 12345, clock = { ["aB3$"] = ID_A, ["cD4~"] = ID_B } } },
      name("a pull request comes back with the digest read into a clock"))
    T.eq({ codec.decode(codec.encode("Q", "debug", 1, 1, "")) },
      { "Q", { table = "debug", schema = 1, nonce = 1, clock = {} } }, name("an empty digest is valid"))
    T.eq({ codec.decode(codec.encode("D", table.unpack(valid.D))) }, { "D", {
      table = "debug", nonce = 12345, batch = 3, last = true, records = records,
      rest = { ["cD4~"] = ID_B }, wants = { ["aB3$"] = ID_A, zzzz = ZERO },
    } }, name("a delta comes back, with a tombstone and with a payload that is false"))
    T.eq({ codec.decode(codec.encode("D", "debug", 7, 1, false, {})) },
      { "D", { table = "debug", nonce = 7, batch = 1, last = false, records = {}, rest = {}, wants = {} } },
      name("a delta without records, rest, and wants is valid"))
    T.eq({ codec.decode(codec.encode("B", table.unpack(valid.B))) },
      { "B", { table = "debug", nonce = 12345, reason = "busy", retry = 30 } }, name("a refusal comes back"))
    T.eq((codec.decode(codec.encode("B", "debug", 1, "later", 0.5))), "B",
      name("an unknown reason word and a retry time with a fraction are accepted"))
    local full = {}
    for index = 1, 500 do
      full[index] = { "key" .. index, ID_A, index }
    end
    local _, delta = codec.decode(codec.encode("D", "debug", 7, 1, false, full))
    T.eq(#delta.records, 500, name("500 records are accepted"))
  end

  -- A rejection for each field out of range
  do
    local manyRecords, manyOrigins = {}, {}
    for index = 1, 501 do
      manyRecords[index] = { "key" .. index, ID_A, index }
    end
    for index = 1, 2001 do
      manyOrigins[ns.base94.encode(index, 4)] = ZERO
    end
    local badNumbers = { 0, -1, 1.5, "1", 2147483648, 0 / 0, false }
    ---Type -> list of { field position, bad value, what it is }
    local cases = { Q = {}, D = {}, B = {} }
    local function add(messageType, position, value, what)
      cases[messageType][#cases[messageType] + 1] = { position, value, what }
    end
    for _, messageType in ipairs({ "Q", "D", "B" }) do
      for _, bad in ipairs({ 5, "", "Debug", "9debug", "de bug", string.rep("n", 33), false }) do
        add(messageType, 1, bad, "a bad table name " .. tostring(bad))
      end
      for position = 1, #valid[messageType] do
        if not (messageType == "D" and position >= 6) then
          add(messageType, position, REMOVE, "a message cut before field " .. position)
        end
      end
    end
    for _, bad in ipairs(badNumbers) do
      add("Q", 2, bad, "a bad schema " .. tostring(bad))
      add("Q", 3, bad, "a bad nonce " .. tostring(bad))
      add("D", 2, bad, "a bad nonce " .. tostring(bad))
      add("D", 3, bad, "a bad batch number " .. tostring(bad))
      add("B", 2, bad, "a bad nonce " .. tostring(bad))
    end
    add("Q", 2, 1000001, "a schema over the limit")
    add("D", 3, 100001, "a batch number over the limit")
    add("Q", 4, 5, "a digest that is a number")
    add("Q", 4, ID_A:sub(1, 10), "a digest of 10 characters")
    add("Q", 4, ID_A .. "5k|Q2aB 3!!", "a digest with a space")
    add("Q", 4, ID_A .. ID_C, "a digest with a repeated origin")
    add("Q", 4, string.rep(ID_A, 2001), "a digest over the limit")
    add("D", 4, 1, "a last flag that is a number")
    add("D", 4, "true", "a last flag that is a string")
    add("D", 5, "records", "records that are a string")
    add("D", 5, manyRecords, "501 records")
    add("D", 5, { { "key", ID_A, 1 }, [3] = { "key", ID_B, 1 } }, "records with a gap")
    add("D", 5, { { "key", ID_A, 1 }, extra = { "key", ID_B, 1 } }, "records with a named entry")
    add("D", 5, { "record" }, "a record that is a string")
    add("D", 5, { { 5, ID_A, 1 } }, "a key that is a number")
    add("D", 5, { { "", ID_A, 1 } }, "an empty key")
    add("D", 5, { { string.rep("k", 65), ID_A, 1 } }, "a key of 65 characters")
    add("D", 5, { { "key", ID_A:sub(1, 10), 1 } }, "an id of 10 characters")
    add("D", 5, { { "key", "5k|Q2aB 3!!", 1 } }, "an id with a space")
    add("D", 5, { { "key", 12345678901, 1 } }, "an id that is a number")
    add("D", 5, { { "key", ID_A } }, "a record without a payload and without a tombstone marker")
    add("D", 5, { { "key", ID_A, 1, true } }, "a tombstone with a payload")
    add("D", 5, { { "key", ID_A, 1, "x" } }, "a tombstone marker that is a string")
    add("D", 5, { { "key", ID_A, [4] = false } }, "a tombstone marker that is false")
    add("D", 6, "rest", "a clock rest that is a string")
    add("D", 6, { ["aB3"] = ID_A }, "a clock rest with an origin of 3 characters")
    add("D", 6, { [5] = ID_A }, "a clock rest with an origin that is a number")
    add("D", 6, { ["aB3$"] = "short" }, "a clock rest with a short id")
    add("D", 6, { ["cD4~"] = ID_A }, "a clock rest with an id of another origin")
    add("D", 6, manyOrigins, "a clock rest of 2001 entries")
    add("D", 7, 5, "wants that are a number")
    add("D", 7, { ["aB 3"] = ID_A }, "wants with a space in an origin")
    add("D", 7, { ["aB3$"] = 5 }, "wants with an id that is a number")
    add("D", 7, manyOrigins, "wants of 2001 entries")
    for _, bad in ipairs({ 5, "", "Busy", "too busy", string.rep("r", 17), false }) do
      add("B", 3, bad, "a bad reason " .. tostring(bad))
    end
    for _, bad in ipairs({ -1, 3601, "30", 0 / 0, 1 / 0, false }) do
      add("B", 4, bad, "a bad retry time " .. tostring(bad))
    end

    for messageType, list in pairs(cases) do
      for _, case in ipairs(list) do
        local fields, count = with(valid[messageType], case[1], case[2])
        local text = serializer:Serialize(1, messageType, table.unpack(fields, 1, count))
        local succeeded, decodedType, reason = pcall(codec.decode, text)
        local what = messageType .. " with " .. case[3]
        T.ok(succeeded, name(what .. " does not raise"))
        T.eq(decodedType, nil, name(what .. " is refused"))
        T.eq(type(reason), "string", name(what .. " gives a reason"))
      end
    end
  end

  -- 1000 random variations of valid messages never raise
  do
    local junk = { 0, -5, 1.5, 2 ^ 40, "", "text", ID_A, ZERO, true, false, {}, { 1, 2 }, { key = "value" },
      { { "key", ID_A, 1 } }, string.rep("x", 300) }
    local types = { "Q", "D", "B" }
    for _ = 1, 1000 do
      local messageType = types[random(1, 3)]
      local fields, count = valid[messageType], #valid[messageType]
      for _ = 1, random(1, 2) do
        local position = random(1, #valid[messageType] + 1)
        local value = junk[random(1, #junk + 1)]
        fields, count = with(fields, position, value == nil and REMOVE or value)
      end
      local succeeded, decodedType, decoded = pcall(codec.decode,
        serializer:Serialize(1, messageType, table.unpack(fields, 1, count)))
      T.ok(succeeded, name("a varied " .. messageType .. " does not raise"))
      if decodedType ~= nil then
        T.eq(decodedType, messageType, name("a varied message that passes keeps its type"))
        T.ok(type(decoded.table) == "string" and type(decoded.nonce) == "number",
          name("a varied message that passes has a table name and a nonce"))
      end
    end
  end
end

-- The push type P
T.eq(protocol.CHANNELS.P, "GUILD", "a push travels on GUILD")
for label, serializer in pairs(serializers) do
  local codec = protocol.new(serializer)
  local function name(text)
    return label .. ": " .. text
  end
  local records = { { key = "one", id = ID_A, payload = "text" }, { key = "gone", id = ID_C, tombstone = true } }
  ---The fields of a valid push, in the order of the wire
  local valid = { "debug", 1, VERSION_A, VERSION_B, true, { ["aB3$"] = ZERO, ["cD4~"] = ID_B },
    protocol.packRecords(records), { ["cD4~"] = ID_B } }
  T.eq({ codec.decode(codec.encode("P", table.unpack(valid))) }, { "P", {
    table = "debug", schema = 1, version = VERSION_A, was = VERSION_B, own = true,
    base = { ["aB3$"] = ZERO, ["cD4~"] = ID_B }, records = records, rest = { ["cD4~"] = ID_B },
  } }, name("a push comes back"))
  T.eq({ codec.decode(codec.encode("P", "debug", 1, VERSION_A, VERSION_A, false, {}, {})) }, { "P", {
    table = "debug", schema = 1, version = VERSION_A, was = VERSION_A, own = false, base = {}, records = {},
    rest = {},
  } }, name("a push without records and without a clock rest is valid"))
  for _, case in ipairs({
    { 1, "De bug", "a bad table name" },
    { 2, 0, "schema 0" },
    { 3, VERSION_A:sub(1, 15), "a version of 15 characters" },
    { 3, 5, "a version that is a number" },
    { 4, VERSION_A .. "!", "a version before of 17 characters" },
    { 4, true, "a missing version before" },
    { 5, 1, "an own flag that is a number" },
    { 5, REMOVE, "a message cut before the own flag" },
    { 6, REMOVE, "a message cut before the base" },
    { 6, "base", "a base that is a string" },
    { 6, { ["aB3"] = ZERO }, "a base with an origin of 3 characters" },
    { 6, { ["aB3$"] = "short" }, "a base with a short id" },
    { 6, { ["aB3$"] = ID_B }, "a base with an id of another origin" },
    { 7, REMOVE, "a message cut before the records" },
    { 7, { { "key", ID_A } }, "a record without a payload" },
    { 7, { { "", ID_A, 1 } }, "an empty key" },
    { 8, { ["aB3$"] = ID_B }, "a clock rest with an id of another origin" },
    { 8, { ["aB3$"] = ZERO }, "a clock rest with the zero id" },
    { 8, 5, "a clock rest that is a number" },
  }) do
    local fields, count = with(valid, case[1], case[2])
    local succeeded, decodedType, reason = pcall(codec.decode,
      serializer:Serialize(1, "P", table.unpack(fields, 1, count)))
    T.ok(succeeded, name("a push with " .. case[3] .. " does not raise"))
    T.eq(decodedType, nil, name("a push with " .. case[3] .. " is refused"))
    T.eq(type(reason), "string", name("a push with " .. case[3] .. " gives a reason"))
  end
end

-- A serializer that raises is contained
do
  local codec = protocol.new({
    Serialize = function()
      return ""
    end,
    Deserialize = function()
      error("broken")
    end,
  })
  T.eq({ codec.decode("text") }, { nil, "not a message" }, "an error of the serializer is a refusal")
end

T.finish()
