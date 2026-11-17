local addonName, ns = ...

-- Numbers as strings over the 94 printable ASCII characters `!` (33) to `~` (126), and a 32-bit string hash.
-- See .agents/00-plan.md, section 3.
--
-- This file uses no WoW API and no `bit` library, so the host tests run the same code (Tests/sync_base94.lua).
-- Every intermediate value stays below 2^53: the doubles of Lua 5.1 and the integers of Lua 5.4 then agree.

---@class OOOOBase94
local base94 = {}
ns.base94 = base94

---Byte of the digit 0
local FIRST_BYTE = 33
---Byte of the digit 93
local LAST_BYTE = 126
local RADIX = 94
---2^32, written out because `2^32` is a float on Lua 5.4
local TWO_32 = 4294967296

---Writes a number as a base-94 string of a fixed width, most significant digit first.
---Strings of one width compare in the order of their numbers.
---@param number integer Not negative
---@param width integer Number of characters
---@return string
function base94.encode(number, width)
  if type(number) ~= "number" or number < 0 or number ~= math.floor(number) then
    error("base94.encode: not a non-negative integer: " .. tostring(number), 2)
  end
  local rest = number
  local chars = {}
  for position = width, 1, -1 do
    local digit = rest % RADIX
    chars[position] = string.char(FIRST_BYTE + digit)
    rest = math.floor(rest / RADIX)
  end
  if rest > 0 then
    error("base94.encode: " .. tostring(number) .. " does not fit into " .. width .. " characters", 2)
  end
  return table.concat(chars)
end

---Tells whether a value is a string of base-94 digits only.
---@param text any
---@return boolean
function base94.isValid(text)
  if type(text) ~= "string" then
    return false
  end
  for position = 1, #text do
    local byte = text:byte(position)
    if byte < FIRST_BYTE or byte > LAST_BYTE then
      return false
    end
  end
  return true
end

---Reads a base-94 string as a number. Exact for up to 8 characters.
---@param text any
---@return integer|nil number nil when `text` is not a string of base-94 digits
function base94.decode(text)
  if not base94.isValid(text) then
    return nil
  end
  local number = 0
  for position = 1, #text do
    number = number * RADIX + (text:byte(position) - FIRST_BYTE)
  end
  return number
end

---Multiplies two numbers below 2^32 modulo 2^32 without an intermediate value above 2^49.
---@param a integer
---@param b integer
---@return integer
local function multiply32(a, b)
  local low = a % 65536
  local high = math.floor(a / 65536)
  return ((high * b) % 65536 * 65536 + low * b) % TWO_32
end

---Hashes a string to 32 bits: `h = h * 33 + byte` over the bytes, then a mix that spreads the last bytes
---over all bits. The fingerprint of a table is a sum of these values, so the hash must never change:
---a change makes equal tables look different to members with another addon version.
---@param text string
---@return integer hash In [0, 2^32)
function base94.hash(text)
  local hash = 5381
  for position = 1, #text do
    hash = (hash * 33 + text:byte(position)) % TWO_32
  end
  hash = multiply32(hash, 2654435761)
  hash = (hash + math.floor(hash / 65536)) % TWO_32
  hash = multiply32(hash, 2246822519)
  hash = (hash + math.floor(hash / 8192)) % TWO_32
  return hash
end

---Compares two strings byte by byte, without the `<` of strings.
---The release client compares strings in byte order (plan step 1.2), so `<` is in use; this is the fallback.
---@param a string
---@param b string
---@return integer order -1 when `a` sorts first, 1 when `b` sorts first, 0 when they are equal
function base94.compare(a, b)
  for position = 1, math.min(#a, #b) do
    local byteA, byteB = a:byte(position), b:byte(position)
    if byteA ~= byteB then
      return byteA < byteB and -1 or 1
    end
  end
  if #a == #b then
    return 0
  end
  return #a < #b and -1 or 1
end
