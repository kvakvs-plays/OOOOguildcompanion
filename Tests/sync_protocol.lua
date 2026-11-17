-- Host test of Addon/Src/Sync/SyncProtocol.lua: the envelope and the types H and S. Every case runs with
-- the stub serializer and with the embedded AceSerializer-3.0, which loads on the host.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
assert(loadfile("Addon/Ace3/AceSerializer-3.0/AceSerializer-3.0.lua"))()
local ns = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/SyncProtocol.lua" })
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
        T.ok(messageType == "H" or messageType == "S", name("a damaged message that passes has a known type"))
        for tableName, version in pairs(fields) do
          T.ok(type(tableName) == "string" and #tableName <= 32, name("a passed table name is short"))
          T.ok(#version == 16 and ns.base94.isValid(version), name("a passed version is valid"))
        end
      end
    end
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
