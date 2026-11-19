-- Host test of Addon/Src/Guild/AddonInventory.lua: the table `addon` (addon version and last seen time per
-- character), the rule for the own write, and the rows and lines of `/oooo versioncheck`.
local T = dofile("Tests/harness.lua")

T.loadLibraries()
local ns = T.loadAll({ "Addon/Src/Slash.lua", "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncTables.lua",
  "Addon/Src/Sync/SyncCharacter.lua", "Addon/Src/Sync/SyncCommands.lua", "Addon/Src/Sync/SyncOptions.lua",
  "Addon/Src/Guild/AddonInventory.lua" })
local sync, inventory = ns.sync, ns.addonInventory
local random = T.newRandom()

local now = 1795000000

-- validate
do
  T.eq(inventory.validate("Nota Scam", { v = "2026.11.6", t = now }), true, "a good payload passes")
  T.eq(inventory.validate("Nota Scam", { v = "2027.1.0", t = 0 }), true, "time 0 passes")
  for name, bad in pairs({
    ["a payload that is not a table"] = "2026.11.6",
    ["a missing version"] = { t = now },
    ["a version that is a number"] = { v = 2026, t = now },
    ["a version with a git hash"] = { v = "2026.11.6-abc1234", t = now },
    ["a version with two parts"] = { v = "2026.11", t = now },
    ["a version with a colour code"] = { v = "|cffff0000 1.2.3", t = now },
    ["a version of 21 characters"] = { v = "2026.11." .. string.rep("1", 13), t = now },
    ["a missing time"] = { v = "2026.11.6" },
    ["a time that is a string"] = { v = "2026.11.6", t = "1" },
    ["a negative time"] = { v = "2026.11.6", t = -1 },
    ["a time with a fraction"] = { v = "2026.11.6", t = now + 0.5 },
    ["an infinite time"] = { v = "2026.11.6", t = math.huge },
    ["an unknown field"] = { v = "2026.11.6", t = now, extra = true },
  }) do
    T.eq(inventory.validate("Nota Scam", bad), false, name .. " is rejected")
  end
end

-- needsWrite
do
  T.eq(inventory.needsWrite(nil, "2026.11.6", now), true, "a character without a record writes")
  T.eq(inventory.needsWrite({ v = "2026.11.5", t = now - 1 }, "2026.11.6", now), true, "a new version writes at once")
  T.eq(inventory.needsWrite({ v = "2026.11.6", t = now - 1 }, "2026.11.6", now), false,
    "the same version is not written again a moment later")
  T.eq(inventory.needsWrite({ v = "2026.11.6", t = now - inventory.MIN_REWRITE }, "2026.11.6", now), true,
    "the same version is written again after MIN_REWRITE")
  T.eq(inventory.needsWrite({ v = "2026.11.6", t = now + 500 }, "2026.11.6", now), true,
    "a record from the future is replaced")
  T.ok(inventory.MIN_REWRITE < inventory.HEARTBEAT, "every heartbeat writes")
end

-- The table, through the API
local player = "Nota Scam"
do
  sync:Initialize({ origin = "XXXX", tables = {} }, function() return now end, random, function() return player end)
  T.eq(sync:Put("addon", "Nota Scam", { v = "2026.11.6", t = now }), true, "the own record is written")
  T.eq(sync:Put("addon", "Other One", { v = "2026.11.6", t = now }), nil, "the record of another character is refused")
  T.eq(sync:Put("addon", "Nota Scam", { v = "dev", t = now }), nil, "a payload that fails validate is refused")
end

-- rows and lines
do
  ---Stores the record of another member, as a pull brings it.
  local counter = 0
  local function foreign(name, version, seen)
    counter = counter + 1
    local changed = sync:ApplyRemote("addon", { { key = name, id = ns.versionId.make(now - 100, "YYYY", counter),
      payload = { v = version, t = seen } } })
    T.eq(#changed, 1, "the record of " .. name .. " is stored")
  end
  foreign("Other One", "2026.11.6", now - 60)
  foreign("Old Timer", "2026.11.5", now - inventory.STALE_SECONDS - 86400)
  foreign("Busy Bee", "2026.11.6", now - inventory.STALE_SECONDS - 10)
  foreign("At Limit", "2026.11.6", now - inventory.STALE_SECONDS)

  local peers = { ["Busy Bee"] = true, ["Pre Table"] = true }
  local parts = {
    sync = sync,
    now = now,
    isPeer = function(name)
      return peers[name] == true
    end,
    playerName = "Nota Scam",
    version = "2026.11.7",
  }
  local rows = inventory.rows(parts,
    { "Other One", "Nota Scam", "Old Timer", "No Addon", "Busy Bee", "Pre Table", "At Limit", "Other One" })
  local names = {}
  for index, row in ipairs(rows) do
    names[index] = row.name
  end
  T.eq(names, { "At Limit", "Busy Bee", "No Addon", "Nota Scam", "Old Timer", "Other One", "Pre Table" },
    "the rows are sorted by name, a repeated name once")
  T.eq(rows[1].stale, false, "a record at the limit is not old")
  T.eq(rows[2], { name = "Busy Bee", version = "2026.11.6", seen = now - inventory.STALE_SECONDS - 10, stale = false,
    talks = true }, "an old record of a member whose addon talks is not old")
  T.eq(rows[3], { name = "No Addon", stale = false, talks = false }, "a member without a record has no version")
  T.eq(rows[4], { name = "Nota Scam", version = "2026.11.7", seen = now, stale = false, talks = true },
    "the own character has the version of this addon, not that of its record")
  T.eq(rows[5].stale, true, "an old record of a silent member is old")
  T.eq(rows[6], { name = "Other One", version = "2026.11.6", seen = now - 60, stale = false, talks = false },
    "a fresh record gives the version")

  T.eq(inventory.lines(rows, now, false, "2026.11.7"), {
    "Addon versions of the 7 online guild members (yours: 2026.11.7):",
    "  At Limit: 2026.11.6",
    "  Busy Bee: 2026.11.6",
    "  No Addon: no addon seen",
    "  Nota Scam: 2026.11.7",
    "  Old Timer: 2026.11.5, last seen 1 d ago",
    "  Other One: 2026.11.6",
    "  Pre Table: an older version, which does not tell its number",
  }, "the lines of the online members")
  T.eq(inventory.lines({}, now, true, nil), { "Addon versions of the 0 guild members in your group:" },
    "the head line of a group, without an own version")

  -- The addon is installed per player: the newest record among a character and its alts counts
  local alts = { ["No Addon"] = { "Old Timer", "Other One", "Never Wrote" }, ["Other One"] = { "Old Timer" },
    ["Old Timer"] = { "Lone Alt" } }
  parts.alts = function(name)
    return alts[name] or {}
  end
  local grouped = inventory.rows(parts, { "No Addon", "Other One", "Old Timer" })
  T.eq(grouped[1], { name = "No Addon", version = "2026.11.6", seen = now - 60, via = "Other One", stale = false,
    talks = false }, "a character without a record takes the newest record of its alts")
  T.eq(grouped[3].via, nil, "an own record that is newer than those of the alts stays")
  T.eq(grouped[2].stale, true, "alts without a record change nothing")
  T.eq(inventory.rowText(grouped[1], now), "No Addon: 2026.11.6 (as Other One)", "the line names the alt")
  alts["Old Timer"] = { "Other One" }
  T.eq(inventory.rowText(inventory.rows(parts, { "Old Timer" })[1], now), "Old Timer: 2026.11.6 (as Other One)",
    "a newer record of an alt replaces an old own one")
  alts["Lazy One"] = { "Old Timer" }
  T.eq(inventory.rowText(inventory.rows(parts, { "Lazy One" })[1], now),
    "Lazy One: 2026.11.5, last seen 1 d ago (as Old Timer)", "an old record of an alt is old")
  parts.alts = nil

  -- Without the session and the own version, as before the login has finished
  local bare = inventory.rows({ sync = sync, now = now }, { "Nota Scam", "Busy Bee" })
  T.eq(bare[1].stale, true, "without a peer list an old record is old")
  T.eq(bare[2].version, "2026.11.6", "without an own version the own record is read")
end

-- The command is registered
do
  T.ok(ns.slash.handlers.versioncheck, "/oooo versioncheck is registered")
end

T.finish()
