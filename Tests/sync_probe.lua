-- Host test of the slash command dispatcher (Slash.lua) and the computing parts of the probes (SyncProbe.lua).
local T = dofile("Tests/harness.lua")

local ns = T.load("Addon/Src/Slash.lua")
T.load("Addon/Src/Sync/SyncProbe.lua", ns)
local probe = ns.syncProbe

---Lines printed through ns.print since the last call of `printed`
---@type string[]
local output = {}
function ns.print(text)
  output[#output + 1] = text
end

---Returns the captured lines as one text and clears them.
---@return string
local function printed()
  local text = table.concat(output, "\n")
  output = {}
  return text
end

-- Payload
local payload = probe.buildPayload()
T.eq(#payload, 94, "the payload has 94 characters")
local seen = {}
for position = 1, #payload do
  local byte = payload:byte(position)
  seen[byte] = (seen[byte] or 0) + 1
end
for byte = 33, 126 do
  T.eq(seen[byte], 1, "the payload holds byte " .. byte .. " exactly once")
end

-- Comparison
T.eq(probe.comparePayload(payload, payload), nil, "an equal payload has no difference")
for _, position in ipairs({ 1, 40, 94 }) do
  local damaged = payload:sub(1, position - 1) .. " " .. payload:sub(position + 1)
  T.eq(probe.comparePayload(payload, damaged), position, "a damaged payload differs at position " .. position)
end
T.eq(probe.comparePayload(payload, payload:sub(1, 50)), 51, "a cut payload differs after its last character")
T.eq(probe.comparePayload(payload, payload .. "x"), 95, "a longer payload differs at the added character")
T.eq(probe.comparePayload(payload, nil), 1, "a missing payload differs at position 1")

-- Result line
T.eq(probe.formatResult("echo", "a|b||c"), "[probe echo] a||b||||c", "a result line doubles every |")

-- Dispatcher
local dispatcher = ns.newDispatcher("/test")
local calls = {}
dispatcher:Register("One", "one - first", function(rest) calls[#calls + 1] = "one:" .. rest end)
dispatcher:Register("two", "two <x> - second", function(rest) calls[#calls + 1] = "two:" .. rest end)
T.eq(dispatcher:Dispatch("one"), true, "a known word is handled")
T.eq(dispatcher:Dispatch("  TWO   Some Name  "), true, "the word matches in any letter case")
T.eq(calls, { "one:", "two:Some Name" }, "the right handler gets the trimmed rest in its own letter case")
T.eq(printed(), "", "a handled command prints no usage text")
for _, input in ipairs({ "three", "", "   ", "onetwo", "one|two" }) do
  T.eq(dispatcher:Dispatch(input), false, "an unknown word is not handled: '" .. input .. "'")
  T.eq(printed(), "Usage:\n  /test one - first\n  /test two <x> - second", "an unknown word prints the usage text")
end
T.eq(dispatcher:Dispatch(nil), false, "a missing input is not handled")
T.eq(dispatcher:Dispatch(42), false, "an input that is not a string is not handled")
printed()
T.eq(#calls, 2, "an unknown word calls no handler")
T.raises(function() dispatcher:Register("ONE", "one", print) end, "a repeated word raises", "registered twice")

-- The real command tree: /oooo sync probe ...
T.eq(ns.slash:Dispatch("sync probe list"), true, "/oooo sync probe list reaches the probe module")
local list = printed()
for _, name in ipairs(probe.names) do
  T.ok(list:find("\n  " .. name .. " ", 1, true), "the list names the probe " .. name)
end
ns.slash:Dispatch("sync probe")
T.ok(printed():find("Probes", 1, true), "probe without a name prints the list")
ns.slash:Dispatch("sync probe nosuchprobe now")
T.ok(printed():find("Probes", 1, true), "an unknown probe prints the list")
ns.slash:Dispatch("sync nosuchcommand")
T.ok(printed():find("/oooo sync probe", 1, true), "an unknown sync command prints the sync usage text")
ns.slash:Dispatch("nosuchcommand")
T.ok(printed():find("/oooo sync", 1, true), "an unknown command prints the usage text")

-- A probe run: lines are printed and stored, and an error becomes a line
ns.db = { global = {} }
probe.Register("selftest", "selftest - used by the host test", function(report, args)
  report:Add("args: " .. table.concat(args, ","))
  report:Store("stored only")
  error("broken on purpose")
end)
ns.slash:Dispatch("sync probe SelfTest a B")
local run = printed()
T.ok(run:find("[probe selftest] args: a,B", 1, true), "a probe gets its arguments and prints a line")
T.ok(not run:find("stored only", 1, true), "a stored line is not printed")
T.ok(run:find("Lua error: ", 1, true) and run:find("broken on purpose", 1, true), "an error becomes a result line")
local stored = ns.db.global.probeResults.selftest
T.eq(stored.build, "?", "the result records an unknown build on the host")
T.eq(#stored.lines, 3, "the result keeps every line")
T.eq(stored.lines[2], "stored only", "the result keeps a line that was not printed")

-- Sort check of the strings probe
local byteOrder = {}
for byte = 33, 126 do
  byteOrder[#byteOrder + 1] = string.char(byte)
end
T.eq(probe.orderCheck(byteOrder), "equal", "the byte order gives equal")
local random = T.newRandom()
local shuffled = { table.unpack(byteOrder) }
for index = #shuffled, 2, -1 do
  local other = random(1, index - 1)
  shuffled[index], shuffled[other] = shuffled[other], shuffled[index]
end
T.eq(probe.orderCheck(shuffled), "differs", "a shuffled list gives differs")
T.eq(probe.orderCheck({ "a", "a" }), "differs", "a repeated entry gives differs")
T.eq(probe.orderCheck({ "a", "ab", "b" }), "equal", "a prefix sorts before the longer string")
T.eq(probe.orderCheck({ "ab", "a" }), "differs", "a longer string before its prefix gives differs")
T.eq(probe.orderCheck({}), "equal", "an empty list gives equal")

-- Probes that need no client API run on the host; the others must report, not raise
ns.slash:Dispatch("sync probe strings")
local strings = printed()
T.ok(strings:find("against the byte order: equal", 1, true), "the strings probe sorts into the byte order on the host")
T.ok(strings:find("RESULT: plain < can compare version ids", 1, true), "the strings probe gives a result")
ns.slash:Dispatch("sync probe time")
T.ok(printed():find("RESULT: GetServerTime is missing", 1, true), "the time probe reports a missing API")
ns.slash:Dispatch("sync probe api")
local api = printed()
T.ok(api:find("missing: GetServerTime, ", 1, true), "the api probe lists a missing function")
T.ok(not api:find("Lua error", 1, true), "the api probe does not raise without the client")
T.eq(probe.lookup("string.format"), string.format, "lookup follows a dotted path")
T.eq(probe.lookup("string.format.x"), nil, "lookup gives nil below a value that is not a table")
T.eq(probe.lookup("nosuch.global"), nil, "lookup gives nil for a missing global")

-- Burst report: messages per second from arrival times
T.eq(probe.messagesPerSecond({ 0, 1, 2, 3 }), 1, "four arrivals one second apart give 1 message per second")
T.eq(probe.messagesPerSecond({ 10.5, 10, 11 }), 2, "arrival times in any order: 3 arrivals in 1 s give 2 per second")
T.eq(probe.messagesPerSecond({ 100, 100.25, 100.5, 100.75, 101 }), 4, "five arrivals in 1 s give 4 per second")
T.eq(probe.messagesPerSecond({}), 0, "no arrival gives 0")
T.eq(probe.messagesPerSecond({ 7 }), 0, "one arrival gives 0")
T.eq(probe.messagesPerSecond({ 7, 7, 7 }), 0, "arrivals at one moment give 0")

-- Burst messages
for _, sequence in ipairs({ 1, 30, 31, 70 }) do
  local message = probe.burstMessage(sequence)
  T.eq(#message, 255, "a burst message has 255 bytes")
  T.eq(message:sub(1, 1), "B", "a burst message starts with its type")
  T.eq(probe.parseBurst(message:sub(2)), sequence, "a burst message gives back sequence " .. sequence)
end
local body = probe.burstMessage(5):sub(2)
for name, bad in pairs({
  ["sequence 0"] = "00" .. body:sub(3),
  ["sequence 71"] = "71" .. body:sub(3),
  ["no digits"] = "xx" .. body:sub(3),
  ["a short body"] = body:sub(1, 100),
  ["a long body"] = body .. "x",
  ["other padding"] = body:sub(1, 253) .. "y",
  ["an empty body"] = "",
}) do
  T.eq(probe.parseBurst(bad), nil, "parseBurst rejects " .. name)
end

-- Result codes
T.eq(probe.summarizeCodes({ "0", "0", "3", "0", "3" }), "0 x3, 3 x2", "equal result codes are counted")
T.eq(probe.summarizeCodes({}), "", "no result code gives an empty summary")

-- Message probes without the client: a usage line or a missing API, never an error
for _, command in ipairs({ "echo", "echo whisper", "echo guild", "echo whisper Name", "burst", "listen", "state",
  "offline" }) do
  ns.slash:Dispatch("sync probe " .. command)
  local result = printed()
  T.ok(result ~= "" and not result:find("Lua error", 1, true), "probe " .. command .. " reports without an error")
end

-- Value list of the names probe
T.eq(probe.listValues("Nota", nil, 5), "'Nota', nil, 5", "listValues shows every value, also nil")
T.eq(probe.listValues(), "no value", "listValues names a call without values")

-- Roster probe (plan step 8.2): the verdict, and a run against a stubbed roster
T.ok(probe.rosterVerdict(5, 5, 3, false):find("^RESULT: safe: the roster lists 3 offline"), "offline entries are safe")
T.ok(probe.rosterVerdict(5, 2, 0, false):find("^RESULT: safe: 3 of 5 entries are missing"), "missing entries are safe")
T.ok(probe.rosterVerdict(2, 2, 0, false):find("^RESULT: UNDECIDED"), "no offline entry decides nothing")
T.ok(probe.rosterVerdict(2, 2, 1, true):find("^RESULT: UNSAFE"), "an entry beyond the count is unsafe")
ns.slash:Dispatch("sync probe roster")
T.ok(printed():find("RESULT: GetNumGuildMembers or GetGuildRosterInfo is missing", 1, true),
  "the roster probe reports a missing API")
local members = { { "Nota Scam", true }, { "Other One", false }, { "Gone Away", false } }
_G.GetNumGuildMembers = function() return #members, 1, 1 end
_G.GetGuildRosterInfo = function(index)
  local member = members[index]
  if member then
    return member[1], "Rank", 1, 60, "Mage", "Zone", "", "", member[2]
  end
end
ns.guildState = {
  rosterCount = 2,
  IsRosterComplete = function() return true end,
  GetMember = function(_self, name)
    return ({ ["Nota Scam"] = { online = true }, ["Other One"] = { online = false } })[name]
  end,
}
ns.sync = {
  keyName = function(key) return key end,
  Iterate = function() return next, { ["Nota Scam"] = 1, ["Other One"] = 1, ["Left Guild"] = 1 } end,
}
ns.slash:Dispatch("sync probe roster")
local roster = printed()
T.ok(roster:find("GetNumGuildMembers(): 3, 1, 1", 1, true), "the roster probe shows the member counts")
T.ok(roster:find("3 readable, 1 online, 2 offline; an entry at the index 4: false", 1, true), "and the entries")
T.ok(roster:find("1 of online members, 1 of offline members, 1 of names outside the roster cache (Left Guild)", 1,
  true), "and how the character records stand against the roster")
T.ok(roster:find("roster cleanup started: false", 1, true), "and the state of the cleanup")
T.ok(roster:find("RESULT: safe: the roster lists 2 offline members", 1, true), "and the verdict")
T.ok(not roster:find("Lua error", 1, true), "the roster probe does not raise")
_G.GetNumGuildMembers, _G.GetGuildRosterInfo = nil, nil

T.finish()
