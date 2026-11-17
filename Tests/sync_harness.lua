-- Host test of the harness itself: the loader, the assertions, and the seeded random source.
local T = dofile("Tests/harness.lua")

-- load passes the addon name and the namespace, as the game does
local ns = { existing = true }
local sameNs, result = T.load("Tests/fixtures/addon_file.lua", ns)
T.ok(sameNs == ns, "load returns the namespace that it was given")
T.eq(ns.loadedName, "OOOOguildcompanion", "load passes the addon name")
T.eq(ns.loadCount, 1, "load passes the namespace")
T.eq(ns.existing, true, "load keeps what the namespace already holds")
T.eq(result, "returned", "load returns the file's return value")
T.load("Tests/fixtures/addon_file.lua", ns)
T.eq(ns.loadCount, 2, "a second file sees the state of the first")
T.eq(T.load("Tests/fixtures/addon_file.lua").loadCount, 1, "load makes a namespace when none is given")
T.raises(function() T.load("Tests/fixtures/missing.lua") end, "load raises on a missing file", "cannot load")

-- Assertions
T.eq({ a = 1, b = { 2, 3 } }, { a = 1, b = { 2, 3 } }, "eq compares tables by content")
T.raises(function() error("boom") end, "raises accepts an error")
T.raises(function() error("boom") end, "raises matches the message", "boom")

-- A failing assertion ends the process with exit code 1 and names the test
local pipe = assert(io.popen(T.luaCommand("Tests/fixtures/failing_assert.lua")))
local output = pipe:read("a")
local _, _, code = pipe:close()
T.eq(code, 1, "a failing assertion gives exit code 1")
T.ok(output:find("FAIL fixture failure", 1, true), "a failing assertion prints the test name")
T.ok(not output:find("not reached", 1, true), "nothing runs after a failing assertion")

-- Seeded random source
local randomA, seedA = T.newRandom(12345)
local randomB = T.newRandom(12345)
local randomC = T.newRandom(54321)
T.eq(seedA, 12345, "newRandom reports its seed")
local equal, differs = true, false
for _ = 1, 1000 do
  local a, b, c = randomA(1, 94), randomB(1, 94), randomC(1, 94)
  equal = equal and a == b
  differs = differs or a ~= c
  if a < 1 or a > 94 or a ~= math.floor(a) then
    T.ok(false, "random(m, n) gives an integer in [m, n]")
  end
end
T.ok(equal, "the same seed gives the same sequence")
T.ok(differs, "another seed gives another sequence")
local fraction = randomA()
T.ok(fraction >= 0 and fraction < 1, "random() gives a number in [0, 1)")
local upTo = randomA(10)
T.ok(upTo >= 1 and upTo <= 10, "random(m) gives an integer in [1, m]")

T.finish()
