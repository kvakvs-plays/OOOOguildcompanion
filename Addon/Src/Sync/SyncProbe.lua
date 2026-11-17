local addonName, ns = ...

-- `/oooo sync probe <name>`: checks of client behaviour that the shared database plan depends on
-- (.agents/00-plan.md, stage 1). Each probe prints its result and stores it in the saved variables.
--
-- Nothing at file scope uses the WoW API, so the host tests can load this file (Tests/sync_probe.lua).
-- A probe reaches an API whose existence on Forever is not confirmed through `lookup`, never by its name.

---@class OOOOProbeResult Last result of one probe, kept in `db.global.probeResults[name]`
---@field build string Client build number, or "?" when it is unknown
---@field lines string[] The result lines, without the chat escapes

---@class OOOOProbeDefinition
---@field help string Usage line: "strings - string comparison order"
---@field run fun(report: OOOOProbeReport, args: string[]) The probe; an error inside becomes a result line

---@class OOOOSyncProbe
---@field probes table<string, OOOOProbeDefinition> Probe name -> definition
---@field names string[] Probe names in the order of registration
local probe = { probes = {}, names = {} }
ns.syncProbe = probe

---Most lines that one stored result keeps, so that a long listening session cannot grow the file without end
local MAX_STORED_LINES = 600

--------------------------------------------------------------------------------
-- Functions that only compute; the host tests cover them
--------------------------------------------------------------------------------

---Builds the test payload: every character that a version id can hold (bytes 33 to 126), each once.
---@return string payload 94 characters in byte order
function probe.buildPayload()
  local chars = {}
  for byte = 33, 126 do
    chars[#chars + 1] = string.char(byte)
  end
  return table.concat(chars)
end

---Finds where a payload that came back differs from the one that was sent.
---@param expected string
---@param received any
---@return integer|nil position First position that differs (1 when `received` is not a string); nil when equal
function probe.comparePayload(expected, received)
  if type(received) ~= "string" then
    return 1
  end
  if expected == received then
    return nil
  end
  local shorter = math.min(#expected, #received)
  for position = 1, shorter do
    if expected:byte(position) ~= received:byte(position) then
      return position
    end
  end
  return shorter + 1
end

---Doubles every `|`, which starts an escape sequence in chat output.
---@param text string
---@return string
function probe.escapePipes(text)
  return (text:gsub("|", "||"))
end

---Formats one result line of a probe for chat.
---@param name string Probe name
---@param text string Result, as stored
---@return string
function probe.formatResult(name, text)
  return "[probe " .. name .. "] " .. probe.escapePipes(text)
end

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------

---Finds a global by its dotted path ("C_ChatInfo.SendAddonMessage"); nil when any part is missing.
---@param path string
---@return any
local function lookup(path)
  local value = _G
  for part in path:gmatch("[^.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[part]
  end
  return value
end
probe.lookup = lookup

---true when `value` is a secret value, which must not be compared, concatenated, or printed.
---@param value any
---@return boolean
local function isSecret(value)
  local check = lookup("issecretvalue")
  return check ~= nil and check(value) == true
end

---Text of any value for a result line; a secret value is named, not read.
---@param value any
---@return string
local function text(value)
  if isSecret(value) then
    return "<secret " .. type(value) .. ">"
  end
  return tostring(value)
end

---Collects the result lines of one probe run: prints them and stores them in the saved variables.
---@class OOOOProbeReport
---@field name string Probe name
---@field lines string[] The stored lines; the same table as in the saved variables when they are loaded
local Report = {}
Report.__index = Report

---Starts the result of a probe and replaces the stored one, or continues it when `append` is set.
---@param name string
---@param append boolean?
---@return OOOOProbeReport
local function newReport(name, append)
  local getBuildInfo = lookup("GetBuildInfo")
  local build = getBuildInfo and select(2, getBuildInfo())
  local result = { build = build and text(build) or "?", lines = {} }
  local global = ns.db and ns.db.global
  if global then
    global.probeResults = global.probeResults or {}
    local stored = global.probeResults[name]
    if append and type(stored) == "table" and type(stored.lines) == "table" and stored.build == result.build then
      result = stored
    end
    global.probeResults[name] = result
  end
  return setmetatable({ name = name, lines = result.lines }, Report)
end

---Stores a result line without printing it, for long lists that would flood the chat frame.
---@param line string
function Report:Store(line)
  if #self.lines < MAX_STORED_LINES then
    self.lines[#self.lines + 1] = line
  end
end

---Prints a result line and stores it.
---@param line string
function Report:Add(line)
  self:Store(line)
  ns.print(probe.formatResult(self.name, line))
end

--------------------------------------------------------------------------------
-- Registry and command
--------------------------------------------------------------------------------

---Adds a probe to the list. A repeated name is a programming error.
---@param name string Lower case, one word
---@param help string Usage line: "strings - string comparison order"
---@param run fun(report: OOOOProbeReport, args: string[])
function probe.Register(name, help, run)
  assert(not probe.probes[name], "probe registered twice: " .. name)
  probe.probes[name] = { help = help, run = run }
  probe.names[#probe.names + 1] = name
end

---Runs one probe. An error inside the probe becomes a result line, so the lines before it are kept.
---@param name string
---@param args string[] Words after the probe name
---@return boolean found false when no probe has that name
function probe.Run(name, args)
  local definition = probe.probes[name]
  if not definition then
    return false
  end
  local report = newReport(name)
  local succeeded, err = pcall(definition.run, report, args)
  if not succeeded then
    report:Add("Lua error: " .. text(err))
  end
  return true
end

---Prints the probe names with their usage lines.
function probe.PrintList()
  ns.print("Probes (/oooo sync probe <name>); results are kept in the saved variables under probeResults:")
  for _, name in ipairs(probe.names) do
    ns.print("  " .. probe.probes[name].help)
  end
end

---Handles `/oooo sync probe <name> [arguments]` and `/oooo sync probe list`.
---@param input string Text after "probe"
function probe.OnCommand(input)
  local words = {}
  for word in input:gmatch("%S+") do
    words[#words + 1] = word
  end
  local name = table.remove(words, 1)
  if not name or name:lower() == "list" or not probe.Run(name:lower(), words) then
    probe.PrintList()
  end
end

ns.syncSlash:Register("probe", "probe <name> [arguments] - run a client probe; probe list - show the probes",
  probe.OnCommand)
