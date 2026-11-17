-- Host test of Addon/Src/Sync/Base94.lua: numbers as base-94 strings, the hash, and the byte-wise comparison.
local T = dofile("Tests/harness.lua")

local base94 = T.load("Addon/Src/Sync/Base94.lua").base94
local random = T.newRandom()

local MAX_5 = 94 ^ 5 - 1

-- encode and decode
T.eq(base94.encode(0, 5), "!!!!!", "0 is five times the first digit")
T.eq(base94.encode(93, 1), "~", "93 is the last digit")
T.eq(base94.encode(94, 2), "\"!", "94 carries into the second digit")
T.eq(base94.encode(MAX_5, 5), "~~~~~", "the greatest value of 5 characters")
for _, number in ipairs({ 0, 1, 93, 94, MAX_5 }) do
  T.eq(base94.decode(base94.encode(number, 5)), number, "round trip of " .. number)
end
for _ = 1, 1000 do
  local number = random(0, MAX_5)
  local text = base94.encode(number, 5)
  if #text ~= 5 or base94.decode(text) ~= number then
    T.eq(base94.decode(text), number, "round trip of the random value " .. number)
  end
end
T.ok(true, "round trip of 1000 random values")
T.eq(base94.decode(base94.encode(1795000000, 5)), 1795000000, "round trip of a timestamp")
T.eq(base94.decode(""), 0, "an empty string decodes to 0")

-- Order: strings of one width compare like their numbers
for _ = 1, 1000 do
  local a, b = random(0, MAX_5), random(0, MAX_5)
  if a ~= b then
    local low, high = math.min(a, b), math.max(a, b)
    if base94.encode(low, 5) >= base94.encode(high, 5) then
      T.ok(false, "encode(" .. low .. ") sorts before encode(" .. high .. ")")
    end
  end
end
T.ok(true, "the string order of 1000 random pairs equals the number order")

-- Bad input of encode
T.raises(function() base94.encode(-1, 5) end, "encode raises on a negative number", "not a non-negative integer")
T.raises(function() base94.encode(1.5, 5) end, "encode raises on a fraction", "not a non-negative integer")
T.raises(function() base94.encode("1", 5) end, "encode raises on a string", "not a non-negative integer")
T.raises(function() base94.encode(MAX_5 + 1, 5) end, "encode raises on a number that is too large", "does not fit")
T.raises(function() base94.encode(94, 1) end, "encode raises on 94 in one character", "does not fit")

-- isValid and bad input of decode
T.eq(base94.isValid("!~Az09"), true, "the printable characters are valid")
for name, bad in pairs({
  ["a space"] = "a b",
  ["byte 127"] = "a\127",
  ["a newline"] = "a\n",
  ["a byte above 127"] = "a\200",
}) do
  T.eq(base94.isValid(bad), false, "isValid rejects " .. name)
  T.eq(base94.decode(bad), nil, "decode rejects " .. name)
end
T.eq(base94.isValid(42), false, "isValid rejects a number")
T.eq(base94.isValid(nil), false, "isValid rejects nil")
T.eq(base94.decode(nil), nil, "decode rejects nil")

-- Hash: these constants guard against a silent change. They were computed independently (Python, plain
-- 32-bit arithmetic), so they also check the split multiplication.
for text, expected in pairs({
  [""] = 1891919065,
  ["a"] = 1430630912,
  ["OO OO"] = 1966373557,
  ["!!!!!!!!!!!"] = 634075737,
  ["~~~~~~~~~~~"] = 3015068278,
  ["0aB3$xyz!~Q"] = 1137101360,
}) do
  T.eq(base94.hash(text), expected, "hash of '" .. text .. "'")
end
for _ = 1, 1000 do
  local chars = {}
  for index = 1, random(0, 20) do
    chars[index] = string.char(random(0, 255))
  end
  local hash = base94.hash(table.concat(chars))
  if math.type(hash) ~= "integer" or hash < 0 or hash >= 4294967296 then
    T.ok(false, "the hash is an integer in [0, 2^32), got " .. tostring(hash))
  end
end
T.ok(true, "1000 random strings hash to an integer in [0, 2^32)")

-- compare agrees with < (the host compares in byte order)
T.eq(base94.compare("abc", "abc"), 0, "equal strings compare as 0")
T.eq(base94.compare("ab", "abc"), -1, "a prefix sorts first")
T.eq(base94.compare("abc", "ab"), 1, "a longer string sorts after its prefix")
T.eq(base94.compare("Z", "a"), -1, "upper case sorts before lower case")
for _ = 1, 1000 do
  local a = base94.encode(random(0, MAX_5), 5):sub(1, random(1, 5))
  local b = base94.encode(random(0, MAX_5), 5):sub(1, random(1, 5))
  local expected = a == b and 0 or (a < b and -1 or 1)
  if base94.compare(a, b) ~= expected then
    T.eq(base94.compare(a, b), expected, "compare('" .. a .. "', '" .. b .. "')")
  end
end
T.ok(true, "compare agrees with < on 1000 random pairs")

-- The file must work without the game and without the bit library
local source = assert(io.open("Addon/Src/Sync/Base94.lua")):read("a")
T.ok(not source:find("bit%."), "Base94.lua does not use the bit library")

T.finish()
