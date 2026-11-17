-- Fixture for sync_harness.lua: one failing assertion, which must end the process with exit code 1.
local T = dofile("Tests/harness.lua")

T.eq(1, 2, "fixture failure")
print("not reached")
