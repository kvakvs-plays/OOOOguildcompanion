-- Host test harness: loads addon files as the game does and gives assertions that stop at the first failure.
-- Runs on the host Lua (5.4) from the repository root: `lua Tests/<name>.lua`. It never runs in the game.

---@class TestHarness
local T = {}

local ADDON_NAME = "OOOOguildcompanion"
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

---Number of assertions that passed in this process; printed by `finish` and summed by run_all.lua
local checks = 0
---Seeds handed out by `newRandom`, printed on a failure so that the run can be repeated
---@type integer[]
local seeds = {}

---Formats any value for a failure message; tables are printed with sorted keys, so the text is stable.
---@param value any
---@param depth integer?
---@return string
local function show(value, depth)
  depth = depth or 0
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) ~= "table" or depth > 4 then
    return tostring(value)
  end
  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = "[" .. show(k, depth + 1) .. "] = " .. show(v, depth + 1)
  end
  table.sort(parts)
  return "{ " .. table.concat(parts, ", ") .. " }"
end

---Deep equality: tables are equal when they have the same keys with equal values.
---@param a any
---@param b any
---@return boolean
local function same(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---Prints the failed test name with the seeds in use and ends the process with exit code 1.
---@param name string
---@param detail string
local function fail(name, detail)
  print("FAIL " .. tostring(name) .. ": " .. detail)
  for _, seed in ipairs(seeds) do
    print("  random seed " .. seed .. " (repeat with TEST_SEED=" .. seed .. ")")
  end
  os.exit(1)
end

---Runs an addon file as the game does: the chunk receives the addon name and the shared namespace.
---@param path string Path relative to the repository root
---@param ns table? Namespace to pass; a new table when omitted
---@return table ns The namespace, for files that export through it
---@return any ... What the file returned
function T.load(path, ns)
  ns = ns or {}
  local chunk, err = loadfile(path)
  if not chunk then
    error("cannot load " .. path .. ": " .. tostring(err), 2)
  end
  return ns, chunk(ADDON_NAME, ns)
end

---Passes when `actual` equals `expected`; tables are compared by content.
---@param actual any
---@param expected any
---@param name string Test name, printed on a failure
function T.eq(actual, expected, name)
  if not same(actual, expected) then
    fail(name, "expected " .. show(expected) .. ", got " .. show(actual))
  end
  checks = checks + 1
end

---Passes when `condition` is neither false nor nil.
---@param condition any
---@param name string Test name, printed on a failure
function T.ok(condition, name)
  if not condition then
    fail(name, "expected a true value, got " .. show(condition))
  end
  checks = checks + 1
end

---Passes when `fn` raises an error, optionally one whose message contains `pattern` as plain text.
---@param fn function
---@param name string Test name, printed on a failure
---@param pattern string?
function T.raises(fn, name, pattern)
  local succeeded, err = pcall(fn)
  if succeeded then
    fail(name, "expected an error, got none")
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    fail(name, "expected an error with " .. show(pattern) .. ", got " .. show(err))
  end
  checks = checks + 1
end

---Makes a random source that does not depend on `math.random`, so one seed gives one sequence everywhere.
---The seed is `seed`, else the TEST_SEED environment variable, else the clock; it is printed on a failure.
---@param seed integer?
---@return fun(m: integer?, n: integer?): number random Like math.random: (), (m) or (m, n)
---@return integer seed The seed in use
function T.newRandom(seed)
  seed = seed or tonumber(os.getenv("TEST_SEED")) or os.time()
  seeds[#seeds + 1] = seed
  -- Park-Miller generator: every product stays below 2^53
  local state = seed % 2147483646 + 1
  local function random(m, n)
    state = state * 48271 % 2147483647
    if not m then
      return (state - 1) / 2147483646
    end
    if not n then
      m, n = 1, m
    end
    return m + (state - 1) % (n - m + 1)
  end
  return random, seed
end

---Builds the shell command that runs a test script with the same Lua interpreter as this process.
---@param script string Path relative to the repository root
---@return string
function T.luaCommand(script)
  local index = 0
  while arg and arg[index - 1] do
    index = index - 1
  end
  local command = '"' .. (arg and arg[index] or "lua") .. '" "' .. script .. '"'
  if IS_WINDOWS then
    -- cmd.exe strips the first and the last quote of a command line that starts with a quote
    command = '"' .. command .. '"'
  end
  return command
end

---Prints the line that run_all.lua counts. Call it as the last statement of a test file.
function T.finish()
  print("ok " .. tostring(arg and arg[0] or "?") .. " (" .. checks .. " checks)")
end

return T
