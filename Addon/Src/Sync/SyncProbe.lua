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

---Says what a roster read means for the roster cleanup (plan 4.4), which removes the records of every name
---that the roster lacks. The cleanup trusts a read in which the number of entries equals the member count.
---@param total integer Member count of `GetNumGuildMembers`
---@param entries integer Entries that `GetGuildRosterInfo` gave for the indexes 1 to `total`
---@param offline integer Entries of members who are offline
---@param beyond boolean true when an entry exists at the index `total + 1`
---@return string verdict One result line
function probe.rosterVerdict(total, entries, offline, beyond)
  if beyond then
    return "RESULT: UNSAFE: the roster has entries beyond the member count, so the count leaves members out "
      .. "and the cleanup would remove their records"
  end
  if entries < total then
    return "RESULT: safe: " .. (total - entries) .. " of " .. total .. " entries are missing or secret, so the "
      .. "roster cache is incomplete and the cleanup waits"
  end
  if offline > 0 then
    return "RESULT: safe: the roster lists " .. offline .. " offline members, so the cleanup keeps their records"
  end
  return "RESULT: UNDECIDED: no offline entry among " .. total .. ". Either every member is online, or hidden "
    .. "members are left out and the cleanup would remove their records. Run it while a member is offline"
end

---Reports how the records of the table `character` stand against the roster cache, and whether the roster
---cleanup of this session has run: after it, records of offline members must still be there.
---@param report OOOOProbeReport
local function reportCleanupState(report)
  local guild, sync = ns.guildState, ns.sync
  local current = ns.syncSession and ns.syncSession.current
  if not guild or not sync then
    return
  end
  report:Add("roster cache: " .. guild.rosterCount .. " members, complete: " .. tostring(guild:IsRosterComplete())
    .. "; discovery done: " .. tostring(current ~= nil and current.discovered == true)
    .. "; roster cleanup started: " .. tostring(current ~= nil and current.rosterCleaned == true))
  local online, offline, outside = 0, 0, {}
  for key in sync:Iterate("character") do
    local name = sync.keyName(key)
    local member = name and guild:GetMember(name)
    if not member then
      outside[#outside + 1] = key
    elseif member.online then
      online = online + 1
    else
      offline = offline + 1
    end
  end
  report:Add("character records: " .. online .. " of online members, " .. offline .. " of offline members, "
    .. #outside .. " of names outside the roster cache"
    .. (#outside > 0 and (" (" .. table.concat(outside, ", ", 1, math.min(#outside, 5)) .. ")") or ""))
end

probe.Register("roster", "roster - does the roster list offline members; run it with \"Show offline members\" "
  .. "on and off (plan step 8.2)",
  function(report)
    local getCount, getInfo = lookup("GetNumGuildMembers"), lookup("GetGuildRosterInfo")
    if not getCount or not getInfo then
      report:Add("RESULT: GetNumGuildMembers or GetGuildRosterInfo is missing")
      return
    end
    local showOffline = lookup("GetGuildRosterShowOffline")
    report:Add("GetGuildRosterShowOffline(): " .. (showOffline and probe.listValues(showOffline()) or "missing"))
    report:Add("GetNumGuildMembers(): " .. probe.listValues(getCount()))
    local total = getCount()
    if isSecret(total) or type(total) ~= "number" then
      report:Add("RESULT: the member count is not a plain number")
      return
    end
    local entries, online, offline = 0, 0, 0
    for index = 1, total do
      -- The 9th value tells whether the member is online
      local name, _, _, _, _, _, _, _, isOnline = getInfo(index)
      if not isSecret(name) and type(name) == "string" and not isSecret(isOnline) then
        entries = entries + 1
        if isOnline == true then
          online = online + 1
        else
          offline = offline + 1
        end
      end
    end
    local beyondName = getInfo(total + 1)
    local beyond = isSecret(beyondName) or beyondName ~= nil
    report:Add("entries at the indexes 1 to " .. total .. ": " .. entries .. " readable, " .. online .. " online, "
      .. offline .. " offline; an entry at the index " .. (total + 1) .. ": " .. tostring(beyond))
    reportCleanupState(report)
    report:Add(probe.rosterVerdict(total, entries, offline, beyond))
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

--------------------------------------------------------------------------------
-- Message probes (plan step 1.3)
--------------------------------------------------------------------------------

---Prefix of the probe messages. It is not the prefix of the sync protocol, so a probe never reaches the engine.
local PREFIX = "OOOOprobe"
---Longest addon message, in bytes
local MESSAGE_BYTES = 255
---Messages that the burst probe sends at once
local BURST_COUNT = 30
---Attempts of the burst probe after the burst, one per STEADY_INTERVAL seconds
local STEADY_COUNT = 40
local STEADY_INTERVAL = 0.5
---A received burst is reported when no message has come for this many seconds
local QUIET_SECONDS = 5
---Shortest time between two echo replies, which limits what another member can make this client send
local REPLY_INTERVAL = 1

---Computes the message rate from arrival times: the intervals between the first and the last arrival.
---@param times number[] Arrival times in seconds, in any order
---@return number rate Messages per second; 0 for fewer than two arrivals or arrivals at one moment
function probe.messagesPerSecond(times)
  if #times < 2 then
    return 0
  end
  local first, last = times[1], times[1]
  for _, time in ipairs(times) do
    first, last = math.min(first, time), math.max(last, time)
  end
  if last <= first then
    return 0
  end
  return (#times - 1) / (last - first)
end

---Builds a burst message of the full length that carries its sequence number.
---@param sequence integer 1 to 99
---@return string message 255 bytes
function probe.burstMessage(sequence)
  return "B" .. string.format("%02d", sequence) .. string.rep("x", MESSAGE_BYTES - 3)
end

---Reads the sequence number of a received burst message; the text comes from another client, so it is checked.
---@param body string The message without its first character
---@return integer|nil sequence nil when the body is not a burst message of this addon
function probe.parseBurst(body)
  if #body ~= MESSAGE_BYTES - 1 then
    return nil
  end
  local digits = body:match("^(%d%d)x+$")
  local sequence = tonumber(digits)
  if sequence and sequence >= 1 and sequence <= BURST_COUNT + STEADY_COUNT then
    return sequence
  end
  return nil
end

---Counts equal result codes: { "0", "0", "3" } gives "0 x2, 3 x1", in the order of first appearance.
---@param codes string[]
---@return string
function probe.summarizeCodes(codes)
  local counts, order = {}, {}
  for _, code in ipairs(codes) do
    if not counts[code] then
      counts[code] = 0
      order[#order + 1] = code
    end
    counts[code] = counts[code] + 1
  end
  for index, code in ipairs(order) do
    order[index] = code .. " x" .. counts[code]
  end
  return table.concat(order, ", ")
end

---Describes the result of `comparePayload` for a result line.
---@param expected string
---@param received string
---@return string description
---@return boolean intact
local function describePayload(expected, received)
  local position = probe.comparePayload(expected, received)
  if not position then
    return "intact (" .. #received .. " bytes)", true
  end
  return "DAMAGED at position " .. position .. " (expected byte " .. tostring(expected:byte(position)) .. ", got "
    .. tostring(received:byte(position)) .. "; " .. #received .. " of " .. #expected .. " bytes)", false
end

---true when a result of C_ChatInfo.SendAddonMessage means that the message was accepted.
---The form of the result on Forever is not known: older clients give true, newer ones an enum value.
---@param result any
---@return boolean
local function isSuccess(result)
  if isSecret(result) then
    return false
  end
  local success = lookup("Enum.SendAddonMessageResult.Success")
  return result == true or result == 0 or (success ~= nil and result == success)
end

---Sends one probe message.
---@param message string
---@param channel "GUILD"|"WHISPER"
---@param target string? Character name, for WHISPER
---@return string result The result of the send as text
---@return boolean accepted
local function sendMessage(message, channel, target)
  local send = lookup("C_ChatInfo.SendAddonMessage")
  if not send then
    return "C_ChatInfo.SendAddonMessage is missing", false
  end
  local result = send(PREFIX, message, channel, target)
  return text(result), isSuccess(result)
end

---Name of the logged-in character in the form of the roster and of a message sender; nil when it is hidden.
---On Forever `UnitName("player")` returns the first and the last name as two values ('Nota', 'Scam'), and
---the roster and CHAT_MSG_ADDON give them joined by a space.
---@return string|nil
local function playerName()
  local first, last = UnitName("player")
  if isSecret(first) or isSecret(last) or type(first) ~= "string" then
    return nil
  end
  if type(last) == "string" and last ~= "" then
    return first .. " " .. last
  end
  return first
end

---The echo probe that waits for replies
---@type { report: OOOOProbeReport, payload: string, replies: integer, damaged: integer }|nil
local pendingEcho
---The state probe that waits for its own message
---@type { report: OOOOProbeReport, delivered: boolean }|nil
local pendingState
---GetTime() of the last echo reply
local lastReplyAt = 0
---The burst that is arriving; one at a time
---@type { key: string, channel: string, times: number[], sequences: integer[], generation: integer }|nil
local incoming

---Prints what arrived of a burst from another client.
---@param record { key: string, channel: string, times: number[], sequences: integer[] }
local function reportIncoming(record)
  local report = newReport("received", true)
  local atOnce, steadyTimes, offsets = 0, {}, {}
  for index, sequence in ipairs(record.sequences) do
    if sequence <= BURST_COUNT then
      atOnce = atOnce + 1
    else
      steadyTimes[#steadyTimes + 1] = record.times[index]
    end
    offsets[#offsets + 1] = string.format("%02d@%.2f", sequence, record.times[index] - record.times[1])
  end
  report:Add("burst from " .. record.key .. " on " .. record.channel .. ": " .. #record.times .. " messages arrived; "
    .. atOnce .. " of the " .. BURST_COUNT .. " sent at once, " .. #steadyTimes .. " of the " .. STEADY_COUNT
    .. " sent after them")
  report:Add(string.format("RESULT: arrival rate after the burst: %.2f messages per second",
    probe.messagesPerSecond(steadyTimes)))
  report:Store("arrivals (sequence@seconds): " .. table.concat(offsets, " "))
end

---Handlers of the probe messages by their first character.
---Arguments: the rest of the message, the channel, the sender's name (nil when secret), and whether it is our own.
---The fifth argument is the sender as the client gave it, which can be secret.
---@type table<string, fun(body: string, channel: string, from: string|nil, own: boolean, sender: any)>
local messageHandlers = {}

---Echo request: another client asks for the payload back.
function messageHandlers.E(body, channel, from, own)
  if own then
    -- A GUILD message and a whisper to oneself come back to the sender: the server round trip without a second client
    if pendingEcho then
      pendingEcho.report:Add("own message came back on " .. channel .. ": "
        .. describePayload(pendingEcho.payload, body))
    end
    return
  end
  local now = GetTime()
  if now - lastReplyAt < REPLY_INTERVAL then
    return
  end
  lastReplyAt = now
  local report = newReport("received", true)
  if channel == "WHISPER" and not from then
    report:Add("echo request by whisper from a secret name; no reply is possible")
    return
  end
  local result = sendMessage("R" .. body, channel, channel == "WHISPER" and from or nil)
  report:Add("echo request from " .. (from or "<secret>") .. " on " .. channel .. "; reply sent, result: " .. result)
end

---Echo reply: the payload as another client received it.
function messageHandlers.R(body, channel, from, own)
  if own or not pendingEcho then
    return
  end
  local description, intact = describePayload(pendingEcho.payload, body)
  pendingEcho.replies = pendingEcho.replies + 1
  if not intact then
    pendingEcho.damaged = pendingEcho.damaged + 1
  end
  pendingEcho.report:Add("reply from " .. (from or "<secret>") .. " on " .. channel .. ": " .. description)
end

---Burst message: the arrival time is recorded, and the report follows when the messages stop.
function messageHandlers.B(body, channel, from, own)
  local sequence = probe.parseBurst(body)
  if not sequence then
    return
  end
  local key = (from or "<secret>") .. (own and " (this client)" or "")
  if not incoming then
    incoming = { key = key, channel = channel, times = {}, sequences = {}, generation = 0 }
  elseif incoming.key ~= key or #incoming.times >= BURST_COUNT + STEADY_COUNT then
    return
  end
  local record = incoming
  record.times[#record.times + 1] = GetTime()
  record.sequences[#record.sequences + 1] = sequence
  record.generation = record.generation + 1
  local generation = record.generation
  C_Timer.After(QUIET_SECONDS, function()
    if incoming == record and record.generation == generation then
      incoming = nil
      reportIncoming(record)
    end
  end)
end

---State message: shows that a message sent in some game state was delivered.
function messageHandlers.S(_body, channel, from, own)
  if own then
    if pendingState then
      pendingState.delivered = true
      pendingState.report:Add("own message came back on " .. channel)
    end
    return
  end
  newReport("received", true):Add("state message from " .. (from or "<secret>") .. " on " .. channel)
end

---The names probe that waits for its own message
---@type OOOOProbeReport|nil
local pendingNames

---Names message: shows the sender name that the client gives for a message of this character.
function messageHandlers.N(_body, channel, from, _own, sender)
  if pendingNames then
    pendingNames:Add("CHAT_MSG_ADDON sender on " .. channel .. ": '" .. text(sender) .. "', without a realm suffix: '"
      .. text(from) .. "'")
  end
end

---Handler of CHAT_MSG_ADDON. Every argument comes from another client or can be secret, so each is checked.
---@param prefix any
---@param message any
---@param channel any
---@param sender any
local function onAddonMessage(prefix, message, channel, sender)
  if isSecret(prefix) or prefix ~= PREFIX then
    return
  end
  if isSecret(message) or type(message) ~= "string" or #message < 1 or #message > MESSAGE_BYTES then
    return
  end
  if isSecret(channel) or (channel ~= "GUILD" and channel ~= "WHISPER") then
    return
  end
  local handler = messageHandlers[message:sub(1, 1)]
  if not handler then
    return
  end
  -- Forever gives no realm suffix, also for another home server; one is cut off in case that changes
  local from = (not isSecret(sender) and type(sender) == "string") and sender:match("^[^-]+") or nil
  handler(message:sub(2), channel, from, from ~= nil and from == playerName(), sender)
end

---true once the prefix is registered and CHAT_MSG_ADDON is handled; it stays so until the next reload
local listening = false

---Starts to receive probe messages.
---@param report OOOOProbeReport Gets a line about the registration
---@return boolean ready
local function startListening(report)
  if listening then
    return true
  end
  local register = lookup("C_ChatInfo.RegisterAddonMessagePrefix")
  if not register then
    report:Add("RESULT: C_ChatInfo.RegisterAddonMessagePrefix is missing")
    return false
  end
  report:Add("RegisterAddonMessagePrefix(\"" .. PREFIX .. "\"): " .. text(register(PREFIX)))
  if not listen("CHAT_MSG_ADDON", onAddonMessage) then
    report:Add("RESULT: CHAT_MSG_ADDON is not a valid event")
    return false
  end
  listening = true
  return true
end

probe.Register("listen", "listen - answer the message probes of another client (run it on the second account)",
  function(report)
    if startListening(report) then
      report:Add("RESULT: listening for probe messages until the next /reload; what arrives is printed")
    end
  end)

probe.Register("echo", "echo guild | echo whisper <name> - send the 94-character payload and compare what comes back",
  function(report, args)
    local mode = (args[1] or ""):lower()
    local channel, target
    if mode == "guild" then
      channel = "GUILD"
    elseif mode == "whisper" and args[2] then
      channel, target = "WHISPER", table.concat(args, " ", 2)
    else
      report:Add("usage: echo guild | echo whisper <name>")
      return
    end
    if not startListening(report) then
      return
    end
    local pending = { report = report, payload = probe.buildPayload(), replies = 0, damaged = 0 }
    pendingEcho = pending
    local result = sendMessage("E" .. pending.payload, channel, target)
    report:Add("sent on " .. channel .. (target and (" to " .. target) or "") .. ", result: " .. result
      .. "; waiting 10 s for replies")
    later(report, 10, function()
      if pendingEcho == pending then
        pendingEcho = nil
      end
      if pending.replies == 0 then
        report:Add("RESULT: no reply from another client (is /oooo sync probe listen running there?)")
      else
        report:Add("RESULT: " .. pending.replies .. " replies, " .. pending.damaged .. " damaged")
      end
    end)
  end)

probe.Register("burst", "burst [name] - 30 messages of 255 bytes at once, then one every 0.5 s for 20 s; "
  .. "to the guild, or by whisper to <name>",
  function(report, args)
    local channel, target = "GUILD", nil
    if args[1] then
      channel, target = "WHISPER", table.concat(args, " ")
    end
    if not startListening(report) then
      return
    end
    local codes, accepted = {}, 0
    for sequence = 1, BURST_COUNT do
      local result, wasAccepted = sendMessage(probe.burstMessage(sequence), channel, target)
      codes[#codes + 1] = result
      accepted = accepted + (wasAccepted and 1 or 0)
    end
    report:Add(BURST_COUNT .. " messages of " .. MESSAGE_BYTES .. " bytes at once on " .. channel .. ": result codes "
      .. probe.summarizeCodes(codes) .. "; accepted: " .. accepted)
    report:Store("result codes in order: " .. table.concat(codes, " "))

    -- The raw API drops a throttled message, so the rate after the burst is the rate of accepted attempts
    local sequence, steadyCodes, acceptedTimes = BURST_COUNT, {}, {}
    local function attempt()
      sequence = sequence + 1
      local result, wasAccepted = sendMessage(probe.burstMessage(sequence), channel, target)
      steadyCodes[#steadyCodes + 1] = result
      if wasAccepted then
        acceptedTimes[#acceptedTimes + 1] = GetTime()
      end
      if sequence < BURST_COUNT + STEADY_COUNT then
        later(report, STEADY_INTERVAL, attempt)
        return
      end
      report:Add("then " .. STEADY_COUNT .. " attempts, one every " .. STEADY_INTERVAL .. " s: result codes "
        .. probe.summarizeCodes(steadyCodes) .. "; accepted: " .. #acceptedTimes)
      report:Store("result codes in order: " .. table.concat(steadyCodes, " "))
      report:Add(string.format("RESULT: %d accepted at once, then %.2f accepted messages per second; "
        .. "the receiving client prints what arrived %d s after the last message",
        accepted, probe.messagesPerSecond(acceptedTimes), QUIET_SECONDS))
    end
    later(report, STEADY_INTERVAL, attempt)
  end)

probe.Register("offline", "offline <name> - whisper an offline guild member and watch for a system line",
  function(report, args)
    -- A character has a first and a last name, so the name is all the words
    local target = args[1] and table.concat(args, " ")
    if not target then
      report:Add("usage: offline <name>")
      return
    end
    local systemLines = {}
    if not listen("CHAT_MSG_SYSTEM", function(message) systemLines[#systemLines + 1] = text(message) end) then
      report:Add("CHAT_MSG_SYSTEM is not a valid event")
    end
    local result = sendMessage("S", "WHISPER", target)
    report:Add("whisper to " .. target .. ", result: " .. result .. "; watching the system messages for 5 s")
    later(report, 5, function()
      unlisten("CHAT_MSG_SYSTEM")
      for _, line in ipairs(systemLines) do
        report:Add("system line: " .. line)
      end
      report:Add(#systemLines == 0 and "RESULT: no system line appeared"
        or "RESULT: " .. #systemLines .. " system lines appeared; see above whether one names the player")
    end)
  end)

probe.Register("state", "state - one message to the guild and its result; run it in combat, in a dungeon, in a raid",
  function(report)
    local inCombatLockdown, isInInstance, isInRaid =
      lookup("InCombatLockdown"), lookup("IsInInstance"), lookup("IsInRaid")
    local inInstance, instanceType
    if isInInstance then
      inInstance, instanceType = isInInstance()
    end
    report:Add("in combat: " .. text(inCombatLockdown and inCombatLockdown()) .. ", in an instance: "
      .. text(inInstance) .. " (" .. text(instanceType) .. "), in a raid group: " .. text(isInRaid and isInRaid()))
    if not startListening(report) then
      return
    end
    local pending = { report = report, delivered = false }
    pendingState = pending
    local result = sendMessage("S", "GUILD")
    report:Add("sent on GUILD, result: " .. result .. "; waiting 5 s for the message to come back")
    later(report, 5, function()
      if pendingState == pending then
        pendingState = nil
      end
      report:Add(pending.delivered and "RESULT: the message was delivered in this state"
        or "RESULT: the message did not come back within 5 s")
    end)
  end)

---Shows every value of a call for a result line: "'Nota', nil".
---@param ... any
---@return string
local function listValues(...)
  local values = {}
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    values[index] = type(value) == "string" and not isSecret(value) and ("'" .. value .. "'") or text(value)
  end
  return #values > 0 and table.concat(values, ", ") or "no value"
end
probe.listValues = listValues

probe.Register("names", "names - the forms of this character's name: unit functions, roster, and message sender",
  function(report)
    -- Which of these is equal to the sender of an addon message decides how a client knows its own messages
    for _, path in ipairs({ "UnitName", "UnitFullName", "UnitNameUnmodified", "GetUnitName" }) do
      local unitFunction = lookup(path)
      report:Add(path .. '("player"): ' .. (unitFunction and listValues(unitFunction("player")) or "missing"))
    end
    local guid = UnitGUID("player")
    local total = GetNumGuildMembers()
    if not isSecret(guid) and not isSecret(total) and type(total) == "number" then
      for index = 1, total do
        local name = GetGuildRosterInfo(index)
        -- The GUID is the 17th value of GetGuildRosterInfo
        local memberGuid = select(17, GetGuildRosterInfo(index))
        if not isSecret(memberGuid) and memberGuid == guid then
          report:Add("roster name of this character: " .. listValues(name))
        end
      end
    end
    if not startListening(report) then
      return
    end
    pendingNames = report
    report:Add("sent on GUILD, result: " .. sendMessage("N", "GUILD") .. "; waiting 5 s for the message to come back")
    later(report, 5, function()
      if pendingNames == report then
        pendingNames = nil
      end
      report:Add("RESULT: compare the sender line with the lines above")
    end)
  end)
