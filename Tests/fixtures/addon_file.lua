-- Fixture for sync_harness.lua: an addon-style file that records what the loader passed to it.
local addonName, ns = ...

ns.loadedName = addonName
ns.loadCount = (ns.loadCount or 0) + 1

return "returned"
