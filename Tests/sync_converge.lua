-- Host test of the whole exchange of the shared database: the push after a pull, the periodic summary, and
-- convergence of many replicas with message loss and offline periods.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local codec = Replica.codec

---Counts the logged messages of one type from a time on.
local function countSince(net, messageType, since)
  return Replica.count(net, messageType, nil, since)
end

---Compares the `debug` tables of replicas: versions and contents.
---@param replicas TestReplica[]
---@param what string
local function expectEqual(replicas, what)
  local first = replicas[1]
  for index = 2, #replicas do
    local replica = replicas[index]
    T.eq(replica:Version("debug"), first:Version("debug"), what .. ": version of " .. replica.name)
    T.eq(replica.sync:GetTable("debug").records, first.sync:GetTable("debug").records,
      what .. ": records of " .. replica.name)
  end
end

-- A returns after a time offline with its own new records and pulls from B: the 20 other replicas in B's
-- state get A's records from one P and send no Q
do
  local random = T.newRandom()
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index = 1, 21 do
    replicas[index] = Replica.new(net, "Member " .. index, { random = random })
    replicas[index]:Login()
  end
  local b = replicas[1]
  net:Advance(100)
  b.sync:Put("debug", "shared", "known to all")
  net:Advance(60)
  local a = Replica.new(net, "Nota Scam", { random = random })
  a:Login()
  net:Advance(200)
  replicas[#replicas + 1] = a
  expectEqual(replicas, "before A goes offline")
  a:Logout()
  net:Advance(100)
  -- While A is away, both sides write
  b.sync:Put("debug", "from b", "written while A was away")
  for index = 1, 5 do
    a.sync:Put("debug", "from a " .. index, "written offline " .. index)
  end
  net:Advance(100)
  local since = net:Now()
  a:Login()
  net:Advance(200)
  T.eq(countSince(net, "Q", since), 1, "one pull request: the one of A")
  T.eq(countSince(net, "P", since), 1, "one push: the records that A's source lacked")
  local pushed
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "P" and entry.time >= since then
      pushed = fields
      T.eq(entry.from, "Nota Scam", "the push comes from A")
    end
  end
  T.eq(#pushed.records, 5, "it holds A's five new records")
  T.eq(pushed.own, false, "it is marked as a push after a pull")
  T.eq(a.sync:Get("debug", "from b"), "written while A was away", "A has what was written meanwhile")
  expectEqual(replicas, "after A's return")
  T.eq(a.sync.dirtySince.debug, nil, "A's own writes count as pushed")
  net:Advance(500)
  T.eq(countSince(net, "Q", since), 1, "no other replica pulls afterwards")
  T.eq(countSince(net, "P", since), 1, "and A does not push its records a second time")
end

-- The periodic summary: replicas in one state send few of them, and it repairs a lost push
do
  local random = T.newRandom()
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index = 1, 10 do
    replicas[index] = Replica.new(net, "Member " .. index, { random = random })
    replicas[index]:Login()
  end
  net:Advance(100)
  local since = net:Now()
  net:Advance(3600)
  local summaries = countSince(net, "S", since)
  T.ok(summaries >= 4, "equal replicas keep announcing their state, got " .. summaries .. " summaries in an hour")
  T.ok(summaries <= 20, "but only a few of the 10 send in each period, got " .. summaries)
  T.eq(countSince(net, "Q", since), 0, "no pull between equal replicas")

  -- A push that only one replica misses, and no later push: the summary shows the difference
  local a, b = replicas[1], replicas[2]
  local losing = true
  net.dropIf = function(entry, to)
    return losing and to == b.name and codec.decode(entry.text) == "P"
  end
  a.sync:Put("debug", "key", "text")
  net:Advance(30)
  losing = false
  T.eq(b.sync:Get("debug", "key"), nil, "one replica has missed the push")
  net:Advance(1200)
  T.eq(b.sync:Get("debug", "key"), "text", "after the next summaries it has pulled the record")
  expectEqual(replicas, "after the repair")
end

-- A replica whose only known source goes offline during the pull completes its table later
do
  local random = T.newRandom()
  local net = Fakenet.new({ random = random, sendRate = 2000 })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local c = Replica.new(net, "Third One", { random = random })
  a:Login()
  c:Login()
  net:Advance(100)
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  net:Advance(200)
  T.eq(c:Version("debug"), a:Version("debug"), "two replicas hold the records")
  local b = Replica.new(net, "Other One", { random = random })
  -- Equal replicas give one answer, more or less. Here the hello does not reach the second replica, so the
  -- first one answers and is the only peer that the new replica knows.
  net.dropIf = function(entry, to)
    return to == "Third One" and entry.from == "Other One"
  end
  b:Login()
  local waited = 0
  while not b.session.pull do
    T.ok(waited < 80, "the pull starts")
    net:Advance(0.25)
    waited = waited + 0.25
  end
  net:Advance(1)
  net.dropIf = nil
  T.eq(b:PeerNames(), { "Nota Scam" }, "the new replica knows the one peer that it heard")
  local source, other = a, c
  source:Logout()
  net:Advance(10)
  local partial = b.sync:Count("debug")
  T.ok(partial < 300, "the pull was cut")
  -- Up to two periods of the summary: the first can be left out, when the source announced the version
  -- before it went offline
  net:Advance(2000)
  T.eq(b:Version("debug"), other:Version("debug"), "a summary of the other replica lets it complete the table")
end

---Runs 10 replicas with random writes, 5% message loss, and optionally offline periods, then lets the
---network settle.
---@param seed integer
---@param withOffline boolean
---@return TestReplica[] replicas
---@return table<string, integer> served Responder and its table version -> pull requests that it got
local function simulate(seed, withOffline)
  local random = T.newRandom(seed)
  local net = Fakenet.new({ random = random, loss = 0.05 })
  local replicas, online = {}, {}
  for index = 1, 10 do
    replicas[index] = Replica.new(net, "Member " .. index, { random = random })
    replicas[index]:Login()
    online[index] = true
  end
  ---Responder and its table version -> number of pull requests for `debug` that it got in that state
  local served = {}
  local byName = {}
  for _, replica in ipairs(replicas) do
    byName[replica.name] = replica
  end
  net.dropIf = function(entry, to)
    local messageType, fields = codec.decode(entry.text)
    if messageType == "Q" and fields.table == "debug" then
      local key = to .. " " .. byName[to]:Version("debug")
      served[key] = (served[key] or 0) + 1
    end
    return false
  end
  net:Advance(100)
  -- 40 minutes of activity: a step every 20 seconds
  for _ = 1, 120 do
    local index = random(1, 10)
    local replica = replicas[index]
    local action = random(1, 10)
    if action <= 4 then
      -- A write, also on a replica that is offline: it is pushed after the next login
      replica.sync:Put("debug", "key" .. random(1, 15), "text " .. random(1, 1000000))
    elseif action == 5 then
      replica.sync:Delete("debug", "key" .. random(1, 15))
    elseif action == 6 and withOffline then
      if online[index] then
        replica:Logout()
      else
        replica:Login()
      end
      online[index] = not online[index]
    end
    net:Advance(20)
  end
  -- The writes stop, everybody is online, and the timers run out. The loss goes on.
  for index, replica in ipairs(replicas) do
    if not online[index] then
      replica:Login()
    end
  end
  net:Advance(4 * 3600)
  return replicas, served
end

-- 10 replicas, random Puts, random offline periods, 5% message loss, 20 seeds: all end equal
for seed = 1, 20 do
  local replicas = simulate(seed, true)
  expectEqual(replicas, "seed " .. seed .. " with offline periods")
  T.ok(replicas[1].sync:Count("debug") > 0, "seed " .. seed .. ": the table is not empty")
end

-- Without offline periods: no responder gets more than 3 pull requests while it is in one state. A login
-- is left out here, because each replica that logs in pulls once from the peer with the newest data.
for seed = 1, 10 do
  local replicas, served = simulate(seed, false)
  expectEqual(replicas, "seed " .. seed .. " without offline periods")
  local worst = 0
  for _, count in pairs(served) do
    worst = math.max(worst, count)
  end
  T.ok(worst <= 3, "seed " .. seed .. ": at most 3 pulls from one responder in one state, got " .. worst)
end

T.finish()
