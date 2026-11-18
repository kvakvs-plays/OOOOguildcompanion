-- Host test of the local cleanup (.agents/00-plan.md, section 4.4): old tombstones and the reset of a table
-- that was out of contact for too long (Addon/Src/Sync/SyncCleanup.lua, `Sweep` and `Reset` in
-- SyncTables.lua).
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local DAY = 86400

---Counts the calls of `sync:Reset` of a replica from now on.
---@param replica TestReplica
---@return fun(): integer count
local function countResets(replica)
  local count = 0
  local reset = replica.sync.Reset
  replica.sync.Reset = function(...)
    count = count + 1
    return reset(...)
  end
  return function()
    return count
  end
end

-- A tombstone of 89 days stays; one of 91 days goes; the table version is the same before and after
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a.sync:Put("debug", "old", "text")
  a.sync:Put("debug", "young", "text")
  a.sync:Put("debug", "live", "text")
  a.sync:Delete("debug", "old")
  net:Advance(2 * DAY)
  a.sync:Delete("debug", "young")
  net:Advance(89 * DAY)
  local tbl = a.sync:GetTable("debug")
  local before = a:Version("debug")
  local changes = 0
  a.sync.RegisterCallback("test", "OnRecordChanged", function()
    changes = changes + 1
  end)
  a:Login()
  net:Advance(25)
  T.eq(tbl.records.old.x, true, "nothing is removed before discovery has ended")
  net:Advance(100)
  T.eq(tbl.records.old, nil, "a tombstone of 91 days is removed after the first discovery")
  T.eq(tbl.records.young.x, true, "a tombstone of 89 days stays")
  T.eq(a.sync:Get("debug", "live"), "text", "a record that is not deleted stays, whatever its age")
  T.eq(a:Version("debug"), before, "the table version is the same before and after")
  T.eq(changes, 0, "the removal of a tombstone is no change of a record")

  -- Once per stay in the guild: a tombstone that grows old during the session waits for the next one
  net:Advance(2 * DAY)
  T.eq(tbl.records.young.x, true, "the cleanup runs once per session")
  a:Logout()
  a:Login()
  net:Advance(100)
  T.eq(tbl.records.young, nil, "the next session removes the tombstone that has grown old")
  T.eq(a:Version("debug"), before, "again without a change of the table version")
end

-- A large table is cleaned in steps, one per frame
do
  local net = Fakenet.new({ random = random })
  -- Without the push, whose timer would be counted as a step below
  Replica.withoutPush = true
  local a = Replica.new(net, "Nota Scam", { random = random })
  Replica.withoutPush = false
  for index = 1, 1200 do
    a.sync:Put("debug", "key" .. index, "text")
    a.sync:Delete("debug", "key" .. index)
  end
  a.sync:Put("debug", "live", "text")
  net:Advance(91 * DAY)
  local before = a:Version("debug")
  local steps = 0
  local after = a.session.parts.after
  a.session.parts.after = function(seconds, fn)
    if seconds == 0 then
      steps = steps + 1
    end
    return after(seconds, fn)
  end
  a:Login()
  net:Advance(100)
  T.eq({ a.sync:Count("debug") }, { 1, 0 }, "all 1200 old tombstones are removed")
  T.eq(steps, 2, "1201 records are looked at in three steps of 500: two of them wait for a later frame")
  T.eq(a:Version("debug"), before, "the table version is unchanged")

  -- A record that changes between two steps is judged as it is then
  local sync = a.sync
  local tbl = sync:GetTable("debug")
  for index = 1, 3 do
    sync:Put("debug", "again" .. index, "text")
  end
  sync.SWEEP_CHUNK = 1
  local waiting = {}
  local removed
  local reported = 0
  sync.RegisterCallback("sweep", "OnRecordChanged", function(_event, _table, _key, payload, isRemote)
    if payload == nil then
      T.eq(isRemote, true, "a removed record is reported like a remote delete")
      reported = reported + 1
    end
  end)
  sync:Sweep("debug", function(key)
    return key ~= "live"
  end, function(_seconds, fn)
    waiting[#waiting + 1] = fn
  end, function(count)
    removed = count
  end)
  -- The first step has run and has looked at one record, which the table order decides
  local left = sync:Count("debug") - 1
  T.ok(left == 2 or left == 3, "the first step looks at one record")
  T.eq(removed, nil, "the sweep is not done after its first step")
  tbl.records.again1, tbl.records.again2, tbl.records.again3 = nil, nil, nil
  sync:Put("debug", "late", "written between two steps")
  while #waiting > 0 do
    table.remove(waiting, 1)()
  end
  T.eq(removed, 3 - left, "a record that has gone before its step is passed over")
  T.eq(reported, removed, "every removed record is reported once")
  T.eq(sync:Get("debug", "late"), "written between two steps", "a record that was written after the start stays")
  T.eq(sync:Get("debug", "live"), "text", "a record that the rule keeps stays")
  sync.UnregisterCallback("sweep", "OnRecordChanged")
end

---Runs the return of a replica after `days` away, during which another replica deleted a record.
---@param days integer
---@return TestReplica a The replica that was away
---@return TestReplica b The replica that deleted
---@return fun(): integer resets Number of resets of the table on `a`
---@return Fakenet net
local function returnAfter(days)
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Other One", { random = random })
  local c = Replica.new(net, "Third One", { random = random })
  for _, replica in ipairs({ a, b, c }) do
    replica:Login()
  end
  net:Advance(100)
  b.sync:Put("debug", "keep", "stays")
  b.sync:Put("debug", "gone", "will be deleted")
  a.sync:Put("debug", "mine", "of A")
  net:Advance(100)
  T.eq(a:Version("debug"), b:Version("debug"), "the three replicas start equal")
  T.eq(a.sync:Get("debug", "gone"), "will be deleted", "the replica that will leave holds the record")
  a:Logout()
  b.sync:Delete("debug", "gone")
  net:Advance(100)
  T.eq(c.sync:Get("debug", "gone"), nil, "the delete reaches the replica that stays")
  b:Logout()
  c:Logout()
  net:Advance(days * DAY)
  b:Login()
  c:Login()
  net:Advance(200)
  local resets = countResets(a)
  a:Login()
  net:Advance(600)
  T.eq(a:Version("debug"), b:Version("debug"), "after " .. days .. " days the returning replica ends equal")
  T.eq(a.sync:Get("debug", "gone"), nil, "and without the record that was deleted meanwhile")
  T.eq(a.sync:Get("debug", "keep"), "stays", "and with the record that was not")
  T.eq(a.sync:Get("debug", "mine"), "of A", "and with its own record, which the others hold")
  return a, b, resets, net
end

-- 59 days away: the table is not emptied; the tombstone still exists and arrives with the pull
do
  local a, b, resets = returnAfter(59)
  T.eq(resets(), 0, "a replica that was away for 59 days is not emptied")
  T.eq(a.sync:GetTable("debug").records.gone.x, true, "it has received the tombstone")
  T.eq(b.sync:GetTable("debug").records.gone.x, true, "which the others still hold")
end

-- 61 days away: the table is emptied before the pull
do
  local _, _, resets = returnAfter(61)
  T.eq(resets(), 1, "a replica that was away for 61 days empties the table once, before its pull")
end

-- 100 days away: the tombstone is gone everywhere, and the deleted record does not come back
do
  local a, b, resets, net = returnAfter(100)
  T.eq(resets(), 1, "a replica that was away for 100 days empties the table")
  T.eq(b.sync:GetTable("debug").records.gone, nil, "the others have removed the tombstone")
  T.eq(a.sync:GetTable("debug").records.gone, nil, "the returning replica holds neither record nor tombstone")
  -- A fresh replica that takes the table from the one that returned gets no deleted record
  b:Logout()
  net:SetOnline("Third One", false)
  local fresh = Replica.new(net, "Fresh One", { random = random })
  fresh:Login()
  net:Advance(600)
  T.eq(fresh:Version("debug"), a:Version("debug"), "a fresh replica pulls from the one that returned")
  T.eq(fresh.sync:Get("debug", "gone"), nil, "and does not get the deleted record")
  T.eq(fresh.sync:Get("debug", "keep"), "stays", "but the live one")
end

-- A table that never had contact holds only own records and is not emptied
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a:Login()
  net:Advance(100)
  a.sync:Put("debug", "mine", "written alone")
  net:Advance(100)
  local tbl = a.sync:GetTable("debug")
  T.eq({ tbl.freshAt, tbl.syncedAt }, { nil, nil }, "a replica without peers has no time of contact")
  a:Logout()
  net:Advance(100 * DAY)
  local b = Replica.new(net, "Other One", { random = random })
  b.sync:Put("debug", "theirs", "of B")
  b:Login()
  net:Advance(100)
  local resets = countResets(a)
  a:Login()
  net:Advance(600)
  T.eq(resets(), 0, "a table that was never synced is not emptied")
  T.eq(a.sync:Get("debug", "mine"), "written alone", "it keeps its own record")
  T.eq(a.sync:Get("debug", "theirs"), "of B", "and takes the records of the peer")
  T.eq(b.sync:Get("debug", "mine"), "written alone", "the peer gets the own record")
  T.ok(tbl.freshAt, "now the table has a time of contact")
end

-- A stale table gives nothing to others, and a replica that is level with a peer is fresh again
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a.sync:Put("debug", "key", "text")
  a:Login()
  net:Advance(100)
  local tbl = a.sync:GetTable("debug")
  local now = math.floor(net:Now())
  tbl.freshAt = now - 61 * DAY
  T.eq(a.session:IsStale("debug"), true, "a table without contact for 61 days is stale")
  local raw = { endpoint = net:Join("Other One"), got = {} }
  raw.endpoint.receive = function(text, distribution)
    if distribution == "WHISPER" then
      local messageType, fields = codec.decode(text)
      raw.got[#raw.got + 1] = { type = messageType, fields = fields }
    end
  end
  raw.endpoint:Send(codec.encode("Q", "debug", 1, 5, ""), "WHISPER", "Nota Scam")
  net:Advance(5)
  T.eq({ raw.got[1].type, raw.got[1].fields.reason }, { "B", "busy" }, "a stale table refuses a pull request")
  T.eq(a.sync:Get("debug", "key"), "text", "and is not emptied by the request")

  -- A peer announces the version of this replica: it holds all that the peer holds
  raw.endpoint:Send(codec.encode("S", { debug = a:Version("debug") }), "GUILD")
  net:Advance(5)
  T.eq(a.session:IsStale("debug"), false, "a table that is level with a peer is fresh")
  raw.endpoint:Send(codec.encode("Q", "debug", 1, 6, ""), "WHISPER", "Nota Scam")
  net:Advance(5)
  T.eq(raw.got[#raw.got].type, "D", "and answers a pull request")

  -- A table of an older addon version has only the time of its last pull
  tbl.freshAt, tbl.syncedAt = nil, now - 61 * DAY
  T.eq(a.session:IsStale("debug"), true, "the time of the last pull counts when there is no other")
  tbl.syncedAt = now - 59 * DAY
  T.eq(a.session:IsStale("debug"), false, "59 days are not stale")
end

T.finish()
