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

--------------------------------------------------------------------------------
-- Events and timers for the probes that wait for the client
--------------------------------------------------------------------------------

---One frame for all probe events, created on first use
---@type table|nil
local eventFrame
---Event name -> handler, which receives the event arguments
---@type table<string, fun(...: any)>
local eventHandlers = {}

---Starts to call `handler` on `event`.
---@param event string
---@param handler fun(...: any)
---@return boolean registered false when the client does not have the event (registering it would throw)
local function listen(event, handler)
  local isEventValid = lookup("C_EventUtils.IsEventValid")
  if isEventValid and not isEventValid(event) then
    return false
  end
  if not eventFrame then
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function(_frame, firedEvent, ...)
      local eventHandler = eventHandlers[firedEvent]
      if eventHandler then
        eventHandler(...)
      end
    end)
  end
  eventHandlers[event] = handler
  eventFrame:RegisterEvent(event)
  return true
end

---Stops the calls that `listen` started.
---@param event string
local function unlisten(event)
  if eventFrame and eventHandlers[event] then
    eventHandlers[event] = nil
    eventFrame:UnregisterEvent(event)
  end
end

---Runs `callback` after `seconds`. An error inside becomes a line of `report`.
---@param report OOOOProbeReport
---@param seconds number
---@param callback fun()
local function later(report, seconds, callback)
  C_Timer.After(seconds, function()
    local succeeded, err = pcall(callback)
    if not succeeded then
      report:Add("Lua error: " .. text(err))
    end
  end)
end

--------------------------------------------------------------------------------
-- Local probes (plan step 1.2)
--------------------------------------------------------------------------------

---Tells whether a list of strings is in ascending byte order, without using the `<` of strings.
---@param list string[]
---@return "equal"|"differs" result "equal" when the list has the byte order
function probe.orderCheck(list)
  for index = 2, #list do
    local previous, current = list[index - 1], list[index]
    local position = probe.comparePayload(previous, current)
    -- Not ascending: equal strings, `current` is a prefix of `previous`, or a smaller byte at the difference
    if not position or position > #current
      or (position <= #previous and previous:byte(position) > current:byte(position)) then
      return "differs"
    end
  end
  return "equal"
end

probe.Register("strings", "strings - does < on strings follow the byte order (plan section 3)", function(report)
  -- Values from a table, not literals, so that the comparison happens in the client and not in the compiler
  local pairsToCheck = { { "!", "A" }, { "Z", "a" }, { "a", "~" } }
  local allHold = true
  for _, pair in ipairs(pairsToCheck) do
    local holds = pair[1] < pair[2]
    allHold = allHold and holds
    report:Add('"' .. pair[1] .. '" < "' .. pair[2] .. '": ' .. tostring(holds))
  end
  -- Start from the reverse order, so that an equal result is the work of the sort
  local chars = {}
  for byte = 126, 33, -1 do
    chars[#chars + 1] = string.char(byte)
  end
  table.sort(chars)
  local order = probe.orderCheck(chars)
  report:Add("sort of the 94 characters against the byte order: " .. order)
  report:Add((allHold and order == "equal") and "RESULT: plain < can compare version ids"
    or "RESULT: use a byte-wise comparison for version ids")
end)

probe.Register("time", "time - GetServerTime() next to time()", function(report)
  local getServerTime, localTime = lookup("GetServerTime"), lookup("time")
  if not getServerTime then
    report:Add("RESULT: GetServerTime is missing")
    return
  end
  local server = getServerTime()
  report:Add("GetServerTime(): " .. text(server) .. " (" .. type(server) .. "), secret: " .. tostring(isSecret(server)))
  if not localTime then
    report:Add("RESULT: time is missing")
    return
  end
  local localNow = localTime()
  report:Add("time(): " .. text(localNow) .. " (" .. type(localNow) .. "), secret: " .. tostring(isSecret(localNow)))
  if not isSecret(server) and not isSecret(localNow) and type(server) == "number" and type(localNow) == "number" then
    report:Add("RESULT: usable; server time minus local time: " .. (server - localNow) .. " s")
  else
    report:Add("RESULT: GetServerTime() does not give a plain number")
  end
end)

---Reads the guild roster and reports the rank index and rank name of the members.
---@param report OOOOProbeReport
local function reportRanks(report)
  local total = GetNumGuildMembers()
  if isSecret(total) or type(total) ~= "number" then
    report:Add("RESULT: GetNumGuildMembers() gives " .. text(total))
    return
  end
  ---@type table<integer, { rankName: string, count: integer, names: string[] }>
  local ranks = {}
  local lowest, highest, unreadable = nil, nil, 0
  for index = 1, total do
    local name, rankName, rankIndex = GetGuildRosterInfo(index)
    if isSecret(name) or isSecret(rankName) or isSecret(rankIndex) or type(rankIndex) ~= "number" then
      unreadable = unreadable + 1
    else
      -- The full list goes to the saved variables only: a large guild would flood the chat frame
      report:Store(text(name) .. ": rank index " .. rankIndex .. ", " .. text(rankName))
      local rank = ranks[rankIndex]
      if not rank then
        rank = { rankName = text(rankName), count = 0, names = {} }
        ranks[rankIndex] = rank
      end
      rank.count = rank.count + 1
      if #rank.names < 3 then
        rank.names[#rank.names + 1] = text(name)
      end
      lowest = math.min(lowest or rankIndex, rankIndex)
      highest = math.max(highest or rankIndex, rankIndex)
    end
  end
  report:Add(total .. " members, " .. unreadable .. " with secret or missing roster data")
  if not lowest then
    report:Add("RESULT: no readable roster entry")
    return
  end
  for rankIndex = lowest, highest do
    local rank = ranks[rankIndex]
    if rank then
      report:Add("rank index " .. rankIndex .. " '" .. rank.rankName .. "': " .. rank.count .. " members, for example "
        .. table.concat(rank.names, ", "))
    end
  end
  local top = ranks[0]
  if top and top.count == 1 then
    report:Add("RESULT: rank index 0 has one member, " .. top.names[1] .. " ('" .. top.rankName
      .. "'); the guild master has index 0 if that is the guild master")
  else
    report:Add("RESULT: rank index 0 has " .. (top and top.count or 0) .. " members; the lowest index is " .. lowest)
  end
end

probe.Register("ranks", "ranks - rank index and rank name of the guild members (plan section 7.5)", function(report)
  if not IsInGuild() then
    report:Add("RESULT: this character is not in a guild")
    return
  end
  local finished = false
  local function finish(reason)
    if not finished then
      finished = true
      unlisten("GUILD_ROSTER_UPDATE")
      report:Add(reason)
      reportRanks(report)
    end
  end
  if not listen("GUILD_ROSTER_UPDATE", function() finish("GUILD_ROSTER_UPDATE arrived") end) then
    report:Add("GUILD_ROSTER_UPDATE is not a valid event")
  end
  C_GuildInfo.GuildRoster()
  report:Add("roster requested; waiting up to 10 s for GUILD_ROSTER_UPDATE")
  -- The server throttles the request, so the event may not come; the cached roster is read then
  later(report, 10, function() finish("no GUILD_ROSTER_UPDATE within 10 s; reading the cached roster") end)
end)

---Functions that later stages of the plan call
local API_FUNCTIONS = {
  "GetServerTime", "IsResting", "IsInRaid", "IsInInstance", "InCombatLockdown", "issecretvalue",
  "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "C_Timer.After", "C_Timer.NewTimer",
  "C_GuildInfo.GuildRoster", "GetNumGuildMembers", "GetGuildRosterInfo", "C_EventUtils.IsEventValid",
  "ChatFrame_AddMessageEventFilter", "Enum.SendAddonMessageResult",
}
---Events that later stages of the plan register
local API_EVENTS = {
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_UPDATE_RESTING", "GROUP_ROSTER_UPDATE",
  "PLAYER_ENTERING_WORLD", "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE", "CHAT_MSG_ADDON", "CHAT_MSG_SYSTEM",
}

probe.Register("api", "api - which functions and events of the later stages exist", function(report)
  local existing, missing = {}, {}
  for _, path in ipairs(API_FUNCTIONS) do
    local list = lookup(path) ~= nil and existing or missing
    list[#list + 1] = path
  end
  report:Add("exist: " .. (#existing > 0 and table.concat(existing, ", ") or "none"))
  report:Add("missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
  local isEventValid = lookup("C_EventUtils.IsEventValid")
  if not isEventValid then
    report:Add("RESULT: C_EventUtils.IsEventValid is missing, so the events cannot be checked")
    return
  end
  local valid, invalid = {}, {}
  for _, event in ipairs(API_EVENTS) do
    local list = isEventValid(event) and valid or invalid
    list[#list + 1] = event
  end
  report:Add("valid events: " .. (#valid > 0 and table.concat(valid, ", ") or "none"))
  report:Add("invalid events: " .. (#invalid > 0 and table.concat(invalid, ", ") or "none"))
  report:Add("RESULT: " .. #missing .. " functions missing, " .. #invalid .. " events invalid")
end)
