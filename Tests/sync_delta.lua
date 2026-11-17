-- Host test of Addon/Src/Sync/SyncStore.lua: digest, delta selection, batches, and convergence of replicas.
local T = dofile("Tests/harness.lua")

local ns = T.load("Addon/Src/Sync/Base94.lua")
T.load("Addon/Src/Sync/VersionId.lua", ns)
T.load("Addon/Src/Sync/SyncStore.lua", ns)
local store, versionId = ns.syncStore, ns.versionId
local random, baseSeed = T.newRandom()

local START = 1795000000

---Shorthand: an id of origin `origin` at `seconds` after the start
local function id(seconds, origin, counter)
  return versionId.make(START + seconds, origin, counter or 0)
end

---Copies a value with all tables inside it.
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

---Runs a pull as the session code will: digest, delta, batches, apply, and after the last batch the rest
---of the source's clock. `batchLimit` cuts the transfer; a cut transfer does not merge the clock.
---@param source OOOOSyncTable
---@param target OOOOSyncTable
---@param maxBytes integer?
---@param batchLimit integer? Apply only this many batches
---@return integer changed Number of records that changed in `target`
---@return integer batchCount Number of batches of the whole transfer
local function pull(source, target, maxBytes, batchLimit)
  local remoteClock = assert(store.parseDigest(store.digest(target)))
  local records = store.selectDelta(source, remoteClock)
  local rest = store.clockRest(source, remoteClock, records)
  local batches = store.splitBatches(records, maxBytes or 2000)
  local changed = 0
  for index = 1, math.min(#batches, batchLimit or #batches) do
    changed = changed + #store.applyBatch(target, batches[index])
  end
  if not batchLimit or batchLimit >= #batches then
    store.mergeClock(target, rest)
  end
  return changed, #batches
end

---The write history of a test: the latest write of every key.
---@class TestHistory
---@field latest table<string, string> Key -> id of the latest write

---Records a write in the history.
local function remember(history, key, writeId)
  if not history.latest[key] or writeId > history.latest[key] then
    history.latest[key] = writeId
  end
end

---Checks the property that convergence rests on: when the clock of a table covers the latest write of a
---key, the table holds that write. A replica that lacks the latest write of a key therefore always shows
---a gap in its clock, and a pull closes it.
---@return string|nil problem nil when the property holds
local function invariantProblem(tbl, history)
  for key, latestId in pairs(history.latest) do
    local seen = tbl.clock[versionId.originOf(latestId)]
    local record = tbl.records[key]
    if seen and seen >= latestId and (not record or record.v ~= latestId) then
      return "the clock covers the latest write of '" .. key .. "', but the table holds "
        .. tostring(record and record.v)
    end
  end
  return nil
end

-- digest and parseDigest
do
  local tbl = store.newTable(1)
  T.eq(store.digest(tbl), "", "the digest of an empty table is empty")
  T.eq(store.parseDigest(""), {}, "an empty digest gives an empty clock")
  store.apply(tbl, "K1", id(10, "BBBB"), 1)
  store.apply(tbl, "K2", id(20, "AAAA"), 2)
  store.apply(tbl, "K3", id(30, "BBBB"), 3)
  local digest = store.digest(tbl)
  T.eq(digest, id(20, "AAAA") .. id(30, "BBBB"), "the digest is the clock ids, sorted")
  T.eq(store.parseDigest(digest), tbl.clock, "parseDigest gives back the clock")
  T.eq({ store.parseDigest(digest:sub(1, 21)) }, { nil, "length" }, "parseDigest rejects a wrong length")
  T.eq({ store.parseDigest(digest:sub(1, 11) .. "bad id here") }, { nil, "id" }, "parseDigest rejects a bad id")
  T.eq({ store.parseDigest(id(1, "AAAA") .. id(2, "AAAA")) }, { nil, "repeated origin" },
    "parseDigest rejects a repeated origin")
  T.eq({ store.parseDigest(42) }, { nil, "length" }, "parseDigest rejects a number")
  T.eq({ store.parseDigest(nil) }, { nil, "length" }, "parseDigest rejects nil")
end

-- selectDelta
do
  local tbl = store.newTable(1)
  store.apply(tbl, "K1", id(30, "AAAA"), "a30")
  store.apply(tbl, "K2", id(10, "BBBB"), "b10")
  store.apply(tbl, "K3", id(20, "AAAA"), nil, true)
  store.apply(tbl, "K4", id(40, "BBBB"), "b40")
  local all = store.selectDelta(tbl, {})
  T.eq(#all, 4, "an empty clock on the other side selects every record")
  for index = 2, #all do
    T.ok(all[index - 1].id < all[index].id, "the delta is sorted by id, ascending")
  end
  T.eq(all[2], { key = "K3", id = id(20, "AAAA"), tombstone = true }, "a tombstone travels with its mark")
  T.eq(all[1], { key = "K2", id = id(10, "BBBB"), payload = "b10" }, "a record travels with its payload")
  local some = store.selectDelta(tbl, { AAAA = id(20, "AAAA"), BBBB = id(40, "BBBB") })
  T.eq(#some, 1, "records at or below the other clock are not selected")
  T.eq(some[1].key, "K1", "the record above the other clock is selected")
  T.eq(store.selectDelta(tbl, copy(tbl.clock)), {}, "an equal clock selects nothing")
end

-- Two replicas with different data end equal after a delta in each direction
do
  local a, b = store.newTable(1), store.newTable(1)
  store.apply(a, "Shared", id(10, "AAAA"), "from a")
  store.apply(a, "OnlyA", id(20, "AAAA"), "a")
  store.apply(a, "Gone", id(25, "AAAA"), nil, true)
  store.apply(b, "Shared", id(15, "BBBB"), "from b")
  store.apply(b, "OnlyB", id(5, "BBBB"), "b")
  store.apply(b, "Gone", id(8, "BBBB"), "still here")
  store.applyBatch(b, store.selectDelta(a, b.clock))
  store.applyBatch(a, store.selectDelta(b, a.clock))
  T.eq(store.tableVersion(a), store.tableVersion(b), "after a delta in each direction the table versions are equal")
  T.eq(a.records, b.records, "after a delta in each direction the records are equal")
  T.eq(a.records.Shared.d, "from b", "the newer write of a shared key wins on both sides")
  T.eq(a.records.Gone.x, true, "the newer tombstone wins on both sides")
end

-- wants: the responder tells for which origins the requester is ahead
do
  local responder, requester = store.newTable(1), store.newTable(1)
  store.apply(responder, "K1", id(10, "AAAA"), 1)
  store.apply(responder, "K2", id(10, "BBBB"), 2)
  store.apply(requester, "K2", id(10, "BBBB"), 2)
  store.apply(requester, "K3", id(20, "BBBB"), 3)
  store.apply(requester, "K4", id(30, "CCCC"), 4)
  local wants = store.wants(responder, requester.clock)
  T.eq(wants, { BBBB = id(10, "BBBB"), CCCC = versionId.ZERO },
    "wants lists the origins with the responder's clock value, and the zero id for an unknown origin")
  T.eq(store.wants(requester, requester.clock), {}, "wants is empty for an equal clock")
  -- The pull, then the push of what the responder wants, makes both equal
  pull(responder, requester)
  store.applyBatch(responder, store.selectDelta(requester, wants))
  T.eq(store.tableVersion(responder), store.tableVersion(requester), "a pull and the wanted push make both equal")
  T.eq(responder.records, requester.records, "a pull and the wanted push give equal records")
end

-- A write that was replaced by another origin leaves no record, but its clock entry must still travel
do
  local source, target = store.newTable(1), store.newTable(1)
  store.apply(source, "Key", id(10, "AAAA"), "replaced")
  store.apply(source, "Key", id(20, "BBBB"), "newer")
  store.apply(source, "Other", id(5, "CCCC"), "kept")
  local records = store.selectDelta(source, target.clock)
  T.eq(#records, 2, "the replaced write is not in the delta")
  local rest = store.clockRest(source, target.clock, records)
  T.eq(rest, { AAAA = id(10, "AAAA") }, "clockRest names the origin whose last write was replaced")
  store.applyBatch(target, records)
  T.ok(store.tableVersion(target) ~= store.tableVersion(source), "the records alone leave the table versions different")
  T.eq(store.mergeClock(target, rest), true, "mergeClock raises the clock")
  T.eq(store.tableVersion(target), store.tableVersion(source), "after mergeClock the table versions are equal")
  T.eq(target.records, source.records, "the records are equal")
  T.eq(store.mergeClock(target, rest), false, "a second mergeClock changes nothing")
  T.eq(store.clockRest(source, target.clock, {}), {}, "clockRest is empty for an equal clock")
  local fp, maxId = target.fp, target.maxId
  store.rebuild(target)
  T.eq({ target.fp, target.maxId }, { fp, maxId }, "mergeClock keeps fp and maxId current")

  -- Entries from another client are checked
  local guarded = store.newTable(1)
  T.eq(store.mergeClock(guarded, { AAAA = id(1, "BBBB"), BBBB = "short", [5] = id(1, "AAAA"), CCCC = 7 }), false,
    "mergeClock skips an id of another origin and what is not an id")
  T.eq(guarded.clock, {}, "a skipped entry does not reach the clock")
  store.apply(guarded, "K", id(50, "AAAA"), 1)
  T.eq(store.mergeClock(guarded, { AAAA = id(40, "AAAA") }), false, "mergeClock never lowers a clock entry")
  T.eq(guarded.clock.AAAA, id(50, "AAAA"), "the clock entry is unchanged")
end

-- Batches from two peers applied in both orders give the same result
do
  local peerA, peerB = store.newTable(1), store.newTable(1)
  for index = 1, 30 do
    store.apply(peerA, "key" .. random(1, 12), id(index * 2, "AAAA"), "a" .. index, random(1, 6) == 1)
    store.apply(peerB, "key" .. random(1, 12), id(index * 2 + 1, "BBBB"), "b" .. index, random(1, 6) == 1)
  end
  local first, second = store.newTable(1), store.newTable(1)
  store.applyBatch(first, store.selectDelta(peerA, {}))
  store.applyBatch(first, store.selectDelta(peerB, first.clock))
  store.applyBatch(second, store.selectDelta(peerB, {}))
  store.applyBatch(second, store.selectDelta(peerA, second.clock))
  T.eq(store.tableVersion(first), store.tableVersion(second), "two peers in both orders: equal table versions")
  T.eq(first.records, second.records, "two peers in both orders: equal records")
end

-- splitBatches
do
  local records = {}
  for index = 1, 200 do
    records[index] = { key = "key" .. index, id = id(index, "AAAA"), payload = string.rep("x", random(0, 120)) }
  end
  local batches = store.splitBatches(records, 500)
  T.ok(#batches > 10, "200 records of up to 140 bytes need many batches of 500 bytes")
  local joined = {}
  for _, batch in ipairs(batches) do
    local bytes = 0
    for _, record in ipairs(batch) do
      bytes = bytes + store.recordSize(record)
      joined[#joined + 1] = record
    end
    T.ok(#batch > 0 and bytes <= 500, "a batch is not empty and stays under the limit")
  end
  T.eq(joined, records, "the joined batches give back the input in its order")
  T.eq(store.splitBatches({}, 500), {}, "no records give no batches")
  local large = { key = "big", id = id(1, "AAAA"), payload = string.rep("x", 900) }
  local small = { key = "small", id = id(2, "AAAA"), payload = "x" }
  T.eq(store.splitBatches({ small, large, small }, 500), { { small }, { large }, { small } },
    "a record over the limit gets a batch of its own")
  T.eq(store.estimateSize({ a = 1, list = { "x", true } }), 4 + 3 + 3 + 6 + (4 + 3 + 3 + 3 + 2),
    "estimateSize counts keys and values of nested tables")
end

-- A transfer cut after batch k, for every k
do
  local history = { latest = {} }
  local origins = { "AAAA", "BBBB", "CCCC" }
  local writes = {}
  local seconds = 0
  for index = 1, 240 do
    seconds = seconds + random(0, 2)
    local write = { key = "key" .. random(1, 60), id = id(seconds, origins[random(1, 3)], index),
      payload = string.rep("p", random(1, 40)), tombstone = random(1, 8) == 1 or nil }
    writes[index] = write
    remember(history, write.key, write.id)
  end
  table.sort(writes, function(a, b) return a.id < b.id end)
  -- The source has seen every write; the target was complete after the first 80
  local source, target = store.newTable(1), store.newTable(1)
  for index, write in ipairs(writes) do
    store.apply(source, write.key, write.id, write.payload, write.tombstone)
    if index <= 80 then
      store.apply(target, write.key, write.id, write.payload, write.tombstone)
    end
  end
  local _, batchCount = pull(source, copy(target), 150, 0)
  T.ok(batchCount >= 10, "the transfer has many batches (" .. batchCount .. ")")
  for cut = 0, batchCount do
    local partial = copy(target)
    pull(source, partial, 150, cut)
    T.eq(invariantProblem(partial, history), nil, "cut after batch " .. cut .. ": the clock covers no missing write")
    local fp, maxId = partial.fp, partial.maxId
    store.rebuild(partial)
    T.eq({ partial.fp, partial.maxId }, { fp, maxId }, "cut after batch " .. cut .. ": fp and maxId are current")
    pull(source, partial, 150)
    T.eq(store.tableVersion(partial), store.tableVersion(source),
      "cut after batch " .. cut .. ": a second pull completes")
    T.eq(partial.records, source.records, "cut after batch " .. cut .. ": the records equal the source")
  end
end

-- A bad record in the middle of a batch
do
  local batch = {
    { key = "a1", id = id(1, "AAAA"), payload = 1 },
    { key = "b1", id = id(2, "BBBB"), payload = 2 },
    { key = "a2", id = id(3, "AAAA"), payload = "bad" },
    { key = "b2", id = id(4, "BBBB"), payload = 4 },
    { key = "a3", id = id(5, "AAAA"), payload = 5 },
    { key = "c1", id = id(6, "CCCC"), payload = 6 },
  }
  local tbl = store.newTable(1)
  local changed, dropped = store.applyBatch(tbl, batch, function(record) return record.payload ~= "bad" end)
  T.eq(changed, { "a1", "b1", "b2", "c1" }, "records before the bad one and of other origins are applied")
  T.eq(dropped, 2, "the bad record and the later record of its origin are dropped")
  T.eq(tbl.records.a2, nil, "the bad record is not stored")
  T.eq(tbl.records.a3, nil, "a later record of the bad origin is not stored")
  T.eq(tbl.clock.AAAA, id(1, "AAAA"), "the clock of the bad origin stops before the bad record")
  T.eq(tbl.clock.BBBB, id(4, "BBBB"), "the clock of another origin is complete")
  T.eq(tbl.clock.CCCC, id(6, "CCCC"), "an origin after the bad record is applied")

  -- A key that is not a string is a bad record of its origin
  tbl = store.newTable(1)
  changed, dropped = store.applyBatch(tbl, { { key = 5, id = id(1, "AAAA") }, { key = "b", id = id(2, "BBBB") },
    { key = "a", id = id(3, "AAAA") } })
  T.eq({ changed, dropped }, { { "b" }, 2 }, "a key that is not a string stops its origin only")

  -- A record without a readable origin ends the batch
  for name, bad in pairs({
    ["a short id"] = { key = "x", id = "short" },
    ["an id with a space"] = { key = "x", id = "!!!!! AAA!!" },
    ["a missing id"] = { key = "x" },
    ["a record that is not a table"] = "record",
  }) do
    tbl = store.newTable(1)
    changed, dropped = store.applyBatch(tbl, { batch[1], bad, batch[2], batch[6] })
    T.eq({ changed, dropped }, { { "a1" }, 3 }, name .. " ends the batch")
    T.eq(tbl.clock, { AAAA = id(1, "AAAA") }, name .. ": only the records before it raise the clock")
  end
  T.eq({ store.applyBatch(store.newTable(1), {}) }, { {}, 0 }, "an empty batch changes nothing")
end

-- Three replicas: random writes, deletes, and pulls (some cut), then pulls until nothing changes
for run = 1, 20 do
  local seed = baseSeed + run
  local label = "seed " .. seed .. ": "
  local runRandom = T.newRandom(seed)
  local now = START
  local history = { latest = {} }
  local replicas = {}
  for index = 1, 3 do
    local origin = versionId.newOrigin(runRandom)
    replicas[index] = {
      tbl = store.newTable(1),
      nextId = versionId.newGenerator(origin, function() return now end, runRandom),
    }
  end
  for round = 1, 500 do
    now = now + runRandom(0, 2)
    local replica = replicas[runRandom(1, 3)]
    local action = runRandom(1, 100)
    if action <= 60 then
      -- A local write or delete, with an id above everything that the table has seen
      local key = "key" .. runRandom(1, 20)
      local writeId = replica.nextId(replica.tbl.maxId)
      store.apply(replica.tbl, key, writeId, { value = runRandom(1, 1000), text = string.rep("t", runRandom(0, 30)) },
        action > 45)
      remember(history, key, writeId)
    else
      local source = replicas[runRandom(1, 3)]
      if source ~= replica then
        local _, batchCount = pull(source.tbl, copy(replica.tbl), 200, 0)
        -- Half of the pulls stop after a random batch
        pull(source.tbl, replica.tbl, 200, runRandom(1, 2) == 1 and runRandom(0, batchCount) or nil)
      end
    end
    local problem = invariantProblem(replica.tbl, history)
    if problem then
      T.eq(problem, nil, label .. "round " .. round)
    end
  end
  -- As the session code will: pull while a table version differs, stop when all are equal
  local sweeps = 0
  local function allEqual()
    local first = store.tableVersion(replicas[1].tbl)
    return store.tableVersion(replicas[2].tbl) == first and store.tableVersion(replicas[3].tbl) == first
  end
  while not allEqual() and sweeps < 10 do
    sweeps = sweeps + 1
    for _, target in ipairs(replicas) do
      for _, source in ipairs(replicas) do
        if store.tableVersion(source.tbl) ~= store.tableVersion(target.tbl) then
          pull(source.tbl, target.tbl, 200)
        end
      end
    end
  end
  T.ok(sweeps <= 3, label .. "the table versions are equal after at most 3 rounds of pulls (" .. sweeps .. ")")
  for index = 2, 3 do
    T.eq(store.tableVersion(replicas[index].tbl), store.tableVersion(replicas[1].tbl),
      label .. "replica " .. index .. " has the table version of replica 1")
    T.eq(replicas[index].tbl.records, replicas[1].tbl.records, label .. "replica " .. index .. " has equal records")
  end
  for key, latestId in pairs(history.latest) do
    if replicas[1].tbl.records[key].v ~= latestId then
      T.eq(replicas[1].tbl.records[key].v, latestId, label .. "the latest write of " .. key .. " is stored")
    end
  end
end
T.ok(true, "three replicas converge with 20 seeds")

T.finish()
