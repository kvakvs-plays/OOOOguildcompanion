-- A small serializer with the interface of AceSerializer-3.0, for host tests that must not depend on the
-- library: `Serialize(...)` gives a string, `Deserialize(text)` gives true and the values, or false and a
-- message. It handles nil, booleans, numbers, strings, and tables of these.
--
-- Format: "STUB" and then one item per value. Items: `z` nil, `t` true, `f` false, `n<number>;`,
-- `s<length>:<bytes>`, `{` key item, value item, ... `}`.

---@class StubSerializer
local Stub = {}

---Appends the item of one value to `parts`.
---@param value any
---@param parts string[]
local function write(value, parts)
  local kind = type(value)
  if value == nil then
    parts[#parts + 1] = "z"
  elseif kind == "boolean" then
    parts[#parts + 1] = value and "t" or "f"
  elseif kind == "number" then
    parts[#parts + 1] = "n" .. string.format("%.17g", value) .. ";"
  elseif kind == "string" then
    parts[#parts + 1] = "s" .. #value .. ":" .. value
  elseif kind == "table" then
    parts[#parts + 1] = "{"
    for key, item in pairs(value) do
      write(key, parts)
      write(item, parts)
    end
    parts[#parts + 1] = "}"
  else
    error("cannot serialize a " .. kind)
  end
end

---Reads one item at `position`. Raises on malformed text.
---@param text string
---@param position integer
---@return any value
---@return integer position Position after the item
local function read(text, position)
  local tag = text:sub(position, position)
  if tag == "z" then
    return nil, position + 1
  elseif tag == "t" or tag == "f" then
    return tag == "t", position + 1
  elseif tag == "n" then
    local digits, after = text:match("^([^;]*);()", position + 1)
    return assert(tonumber(digits), "bad number"), after
  elseif tag == "s" then
    local length, after = text:match("^(%d+):()", position + 1)
    length = assert(tonumber(length), "bad string length")
    assert(after + length - 1 <= #text, "string is cut")
    return text:sub(after, after + length - 1), after + length
  elseif tag == "{" then
    local result = {}
    position = position + 1
    while text:sub(position, position) ~= "}" do
      local key, item
      key, position = read(text, position)
      item, position = read(text, position)
      assert(key ~= nil and key == key, "bad table key")
      result[key] = item
    end
    return result, position + 1
  end
  error("bad tag")
end

---@param ... any
---@return string
function Stub:Serialize(...)
  local parts = { "STUB" }
  for index = 1, select("#", ...) do
    write((select(index, ...)), parts)
  end
  return table.concat(parts)
end

---@param text string
---@return boolean succeeded
---@return any ... The values, or the error message
function Stub:Deserialize(text)
  if type(text) ~= "string" or text:sub(1, 4) ~= "STUB" then
    return false, "not stub data"
  end
  local values, count, position = {}, 0, 5
  local succeeded, message = pcall(function()
    while position <= #text do
      count = count + 1
      values[count], position = read(text, position)
    end
  end)
  if not succeeded then
    return false, message
  end
  return true, table.unpack(values, 1, count)
end

return Stub
