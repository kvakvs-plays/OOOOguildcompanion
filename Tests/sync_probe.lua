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

T.finish()
