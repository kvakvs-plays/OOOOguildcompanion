-- Host test of Addon/Src/Sync/SyncStore.lua: records, the clock, the fingerprint, and the table version.
local T = dofile("Tests/harness.lua")

local ns = T.load("Addon/Src/Sync/Base94.lua")
T.load("Addon/Src/Sync/VersionId.lua", ns)
T.load("Addon/Src/Sync/SyncStore.lua", ns)
local store, versionId, base94 = ns.syncStore, ns.versionId, ns.base94
local random = T.newRandom()

local START = 1795000000
---Shorthand: an id of origin `origin` at `seconds` after the start
local function id(seconds, origin, counter)
  return versionId.make(START + seconds, origin, counter or 0)
end

-- newTable
local empty = store.newTable(3)
T.eq(empty, { schema = 3, clock = {}, maxId = versionId.ZERO, fp = 0, records = {} },
  "newTable gives the empty structure")
T.eq(store.tableVersion(empty), "!!!!!!!!!!!!!!!!", "the version of an empty table is 16 times the first digit")

-- Last writer wins
do
  local tbl = store.newTable(1)
  T.eq(store.apply(tbl, "Key", id(10, "AAAA"), "first"), true, "a new key is stored")
  T.eq(tbl.records.Key, { v = id(10, "AAAA"), d = "first" }, "the record holds the id and the payload")
  T.eq(store.apply(tbl, "Key", id(20, "BBBB"), "second"), true, "a newer id replaces the record")
  T.eq(tbl.records.Key.d, "second", "the newer payload is stored")
  T.eq(store.apply(tbl, "Key", id(15, "CCCC"), "old"), false, "an older id does not replace the record")
  T.eq(tbl.records.Key.d, "second", "the record is unchanged after an older id")
  T.eq(store.apply(tbl, "Key", id(20, "BBBB"), "other"), false, "an equal id changes nothing")
  T.eq(tbl.records.Key.d, "second", "the record is unchanged after an equal id")

  -- A losing record still raises the clock of its origin
  T.eq(tbl.clock.CCCC, id(15, "CCCC"), "a losing record raises the clock of its origin")
  T.eq(tbl.clock.AAAA, id(10, "AAAA"), "the clock keeps the origin of a replaced record")
  T.eq(tbl.maxId, id(20, "BBBB"), "maxId is the greatest id seen")
  store.apply(tbl, "Other", id(5, "BBBB"), "late")
  T.eq(tbl.clock.BBBB, id(20, "BBBB"), "an older id of an origin does not lower its clock")
  T.eq(tbl.records.Other.d, "late", "an older id for another key is still stored")
end

-- Tombstones
do
  local tbl = store.newTable(1)
  store.apply(tbl, "Key", id(10, "AAAA"), { level = 60 })
  T.eq(store.apply(tbl, "Key", id(20, "AAAA"), "ignored", true), true, "a newer tombstone replaces a record")
  T.eq(tbl.records.Key, { v = id(20, "AAAA"), x = true }, "a tombstone holds the id and no payload")
  T.eq(store.apply(tbl, "Key", id(15, "BBBB"), "old"), false, "an older record does not replace a tombstone")
  T.eq(store.apply(tbl, "Key", id(30, "BBBB"), "back"), true, "a newer record replaces a tombstone")
  T.eq(tbl.records.Key, { v = id(30, "BBBB"), d = "back" }, "the record after a tombstone has no tombstone mark")
end

-- fp and maxId are kept in place: after random apply calls they equal the values of rebuild
do
  local tbl = store.newTable(1)
  local origins = {}
  for index = 1, 8 do
    origins[index] = versionId.newOrigin(random)
  end
  for _ = 1, 1000 do
    local key = "key" .. random(1, 50)
    store.apply(tbl, key, id(random(0, 5000), origins[random(1, #origins)], random(0, 8835)), random(1, 100),
      random(1, 10) == 1)
  end
  local fp, maxId = tbl.fp, tbl.maxId
  store.rebuild(tbl)
  T.eq(tbl.fp, fp, "fp after 1000 random apply calls equals the value of rebuild")
  T.eq(tbl.maxId, maxId, "maxId after 1000 random apply calls equals the value of rebuild")
  T.eq(math.type(tbl.fp), "integer", "fp is an integer")
  T.ok(tbl.fp >= 0 and tbl.fp < 4294967296, "fp is in [0, 2^32)")
  for origin, clockId in pairs(tbl.clock) do
    T.eq(versionId.originOf(clockId), origin, "a clock entry holds an id of its origin")
  end
end

-- Table version
do
  local a, b = store.newTable(1), store.newTable(1)
  -- The same writes in another order, with another key and payload for the last id of one origin
  store.apply(a, "K1", id(10, "AAAA"), 1)
  store.apply(a, "K2", id(20, "BBBB"), 2)
  store.apply(a, "K3", id(30, "AAAA"), 3)
  store.apply(b, "K3", id(30, "AAAA"), 3)
  store.apply(b, "K2", id(20, "BBBB"), 2)
  T.eq(a.clock, b.clock, "the two tables have equal clocks")
  T.eq(store.tableVersion(a), store.tableVersion(b), "equal clocks give equal table versions")
  T.eq(#store.tableVersion(a), 16, "a table version has 16 characters")

  local before = store.tableVersion(b)
  store.apply(b, "K2", id(25, "BBBB"), 4)
  T.ok(store.tableVersion(b) ~= before, "a change of one clock entry changes the table version")
  T.eq(store.tableVersion(b):sub(1, 11), before:sub(1, 11), "maxId is unchanged when the new id is not the greatest")
  store.apply(b, "K9", id(40, "CCCC"), 5)
  T.eq(store.tableVersion(b):sub(1, 11), id(40, "CCCC"), "the table version starts with the greatest id")

  local maxId, fp = store.parseTableVersion(store.tableVersion(b))
  T.eq(maxId, b.maxId, "parseTableVersion gives back maxId")
  T.eq(fp, b.fp, "parseTableVersion gives back fp")
  local emptyMax, emptyFp = store.parseTableVersion(store.tableVersion(store.newTable(1)))
  T.eq({ emptyMax, emptyFp }, { versionId.ZERO, 0 }, "parseTableVersion reads the version of an empty table")
end

-- parseTableVersion rejects what is not a table version
local version = id(1, "AAAA") .. base94.encode(12345, 5)
T.eq(select("#", store.parseTableVersion(version)), 2, "a table version parses into two values")
for name, bad in pairs({
  ["15 characters"] = version:sub(1, 15),
  ["17 characters"] = version .. "!",
  ["a space"] = version:sub(1, 7) .. " " .. version:sub(9),
  ["a fingerprint of 2^32 or more"] = id(1, "AAAA") .. "~~~~~",
  ["a number"] = 1234567890123456,
  ["a table"] = {},
}) do
  T.eq(store.parseTableVersion(bad), nil, "parseTableVersion rejects " .. name)
end
T.eq(store.parseTableVersion(nil), nil, "parseTableVersion rejects nil")

T.finish()
