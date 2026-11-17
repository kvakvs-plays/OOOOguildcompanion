-- Runs every host test (Tests/sync_*.lua), each in its own process, and prints one summary line.
-- Usage, from the repository root: lua Tests/run_all.lua

local T = dofile("Tests/harness.lua")

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

---Lists the test files, sorted. The pattern is fixed, so nothing from outside reaches the shell.
---@return string[] paths Paths relative to the repository root
local function listTests()
  local command = IS_WINDOWS and 'dir /b "Tests\\sync_*.lua" 2>nul' or "ls Tests/sync_*.lua 2>/dev/null"
  local paths = {}
  local pipe = assert(io.popen(command))
  for line in pipe:lines() do
    local name = line:match("([^/\\]+%.lua)%s*$")
    if name then
      paths[#paths + 1] = "Tests/" .. name
    end
  end
  pipe:close()
  table.sort(paths)
  return paths
end

local checks, failed = 0, 0
local tests = listTests()
for _, path in ipairs(tests) do
  local pipe = assert(io.popen(T.luaCommand(path)))
  local output = pipe:read("a")
  local _, _, code = pipe:close()
  io.write(output)
  if code == 0 then
    checks = checks + (tonumber(output:match("%((%d+) checks%)%s*$")) or 0)
  else
    failed = failed + 1
    print("FAILED " .. path .. " (exit code " .. tostring(code) .. ")")
  end
end

print(#tests .. " tests, " .. checks .. " checks, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
