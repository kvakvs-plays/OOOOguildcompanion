-- Host test of discovery in Addon/Src/Sync/SyncSession.lua: the hello, the answers with their suppression,
-- and the peer list, with full replicas on the fake network.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)
-- The push has its own test (sync_push.lua)
Replica.withoutPush = true

local random = T.newRandom()

---Makes a network and the replicas with the given names, not yet logged in.
---@param names string[]
---@param randomFn (fun(m: integer?, n: integer?): number)?
---@return Fakenet net
---@return TestReplica ... One per name
local function setup(names, randomFn)
  randomFn = randomFn or random
  local net = Fakenet.new({ random = randomFn })
  local replicas = {}
  for index, name in ipairs(names) do
    replicas[index] = Replica.new(net, name, { random = randomFn })
  end
  return net, table.unpack(replicas)
end

---Returns the hellos and summaries of the log: the messages of discovery. The pulls that follow a discovery
---are tested in sync_pull.lua.
---@param net Fakenet
---@return FakenetLogEntry[]
local function discoveryLog(net)
  local entries = {}
  for _, entry in ipairs(net.log) do
    local messageType = Replica.codec.decode(entry.text)
    if messageType == "H" or messageType == "S" then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

---Counts the hellos and summaries in the log.
---@param net Fakenet
---@return integer
local function count(net)
  return #discoveryLog(net)
end

---Returns the last hello or summary in the log.
---@param net Fakenet
---@return FakenetLogEntry
local function last(net)
  local entries = discoveryLog(net)
  return entries[#entries]
end

---Moves the clock in small steps until the log has `count` messages; fails after `limit` seconds.
---@param net Fakenet
---@param wanted integer
---@param limit number
local function advanceUntilCount(net, wanted, limit)
  local waited = 0
  while count(net) < wanted do
    T.ok(waited < limit, "message " .. wanted .. " is sent within " .. limit .. " seconds")
    net:Advance(0.1)
    waited = waited + 0.1
  end
end

-- No hello before the guild state is known, and one hello 20 to 40 seconds after it
do
  local net, a = setup({ "Nota Scam" })
  net:Advance(100)
  T.eq(net:Count(), 0, "nothing is sent before the guild state is known")
  T.eq(a.session:StatusLines()[1], "discovery: not started (not in the guild)", "the status says not started")
  local start = net:Now()
  a:Login()
  T.eq(a.session:StatusLines()[1], "discovery: waiting to send the hello", "the status says waiting")
  net:Advance(19.9)
  T.eq(net:Count(), 0, "no hello in the first 20 seconds")
  advanceUntilCount(net, 1, 20.2)
  T.eq(Replica.count(net, "H"), 1, "one hello within 40 seconds")
  T.eq(net.log[1].distribution, "GUILD", "the hello goes to the guild")
  local _, versions = Replica.codec.decode(net.log[1].text)
  T.eq(versions, { character = a:Version("character"), debug = a:Version("debug"),
    guildchat = a:Version("guildchat") }, "the hello carries the version of every table")
  T.ok(net.log[1].time - start >= 20 and net.log[1].time - start <= 40, "the hello is sent in the random range")
  T.eq(a.session.discovered, false, "the answers are still collected")
  T.eq(a.session:StatusLines()[1], "discovery: collecting answers", "the status says collecting")
  net:Advance(100)
  T.eq(count(net), 1, "the hello is sent once")
  T.eq(a.session.discovered, true, "discovery ends 10 seconds after the hello")
  T.eq(a.session:StatusLines(), { "discovery: done", "peers: 0" }, "the status of a replica without peers")
  a.session:OnGuildStateChanged(true)
  net:Advance(100)
  T.eq(count(net), 1, "a repeated guild state does not send a second hello")
end

-- Two replicas with equal tables: one hello, no summary
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  -- The same write on both: equal tables that are not empty
  local id = a.ns.versionId.make(1794000000, "ZZZZ", 0)
  for _, replica in ipairs({ a, b }) do
    replica.ns.syncStore.apply(replica.sync:GetTable("debug"), "key", id, "text")
  end
  T.eq(a:Version("debug"), b:Version("debug"), "the two replicas have equal tables")
  a:Login()
  net:Advance(100)
  local since = net:Now()
  b:Login()
  net:Advance(100)
  T.eq(Replica.count(net, "H", nil, since), 1, "one hello after the second login")
  T.eq(Replica.count(net, "S"), 0, "no summary between equal replicas")
  T.eq(a:PeerNames(), { "Other One" }, "the replica that heard the hello knows the sender")
  T.eq(a.session:StatusLines()[3]:match("^  Other One: last message %d+ s ago, (.+)$"), "no newer data known",
    "the status shows the peer without a difference")
  T.eq(Replica.count(net, "A", "Nota Scam", since), 1, "the replica that heard the hello whispers that it is here")
  T.eq(b:PeerNames(), { "Nota Scam" }, "so the new replica knows it, although no table differs")
  T.eq(b.session.peers["Nota Scam"].versions, {}, "without a version of any table")
  T.eq(b.session.discovered, true, "its discovery ends")
  T.eq(b.session.pull, nil, "and it pulls nothing")
end

-- The whisper "here": one per hello, not again within a moment, held back in combat
do
  local net, a = setup({ "Nota Scam" })
  a:Login()
  net:Advance(100)
  local raw = net:Join("Raw One")
  local heard = 0
  raw.receive = function(text, distribution)
    if distribution == "WHISPER" and Replica.codec.decode(text) == "A" then
      heard = heard + 1
    end
  end
  local hello = Replica.codec.encode("H", {})
  raw:Send(hello, "GUILD")
  net:Advance(0.5)
  T.eq(heard, 0, "the whisper waits a random time, like an answer")
  net:Advance(10)
  T.eq(heard, 1, "a hello gets one whisper")
  T.ok(a.session.whisperedAt["Raw One"], "the time of the whisper is noted")
  raw:Send(hello, "GUILD")
  net:Advance(10)
  T.eq(heard, 1, "a second hello a moment after the whisper gets none")
  net:Advance(a.ns.syncSession.PRESENCE_INTERVAL)
  raw:Send(hello, "GUILD")
  raw:Send(hello, "GUILD")
  net:Advance(10)
  T.eq(heard, 2, "a later hello gets one again, and two hellos at once get one between them")

  -- In combat nothing is sent; the whisper goes when the fight is over
  net:Advance(100)
  a:SetState({ inCombat = true })
  raw:Send(hello, "GUILD")
  net:Advance(100)
  T.eq(heard, 2, "a replica in combat does not whisper")
  a:SetState({ inCombat = false })
  net:Advance(1)
  T.eq(heard, 3, "it whispers when the fight is over")

  -- A member who went offline before the whisper gets none, and nothing stays owed
  net:Advance(100)
  raw:Send(hello, "GUILD")
  net:Advance(0.5)
  net:SetOnline("Raw One", false)
  net:Advance(100)
  T.eq(next(a.session.presenceOwed), nil, "nothing stays owed to a member who has gone offline")

  -- A whisper "here" from a member makes that member a peer
  net:SetOnline("Raw One", true)
  a.session.peers["Raw One"] = nil
  raw:Send(Replica.codec.encode("A"), "WHISPER", "Nota Scam")
  net:Advance(1)
  T.eq(a:PeerNames(), { "Raw One" }, "the sender of a whisper \"here\" is a peer")
  a.session.peers["Raw One"] = nil
  raw:Send(Replica.codec.encode("A"), "GUILD")
  net:Advance(1)
  T.eq(a:PeerNames(), {}, "the type is dropped on the guild channel")
end

-- 30 equal replicas are online; one more logs in and knows them all after its discovery
do
  local names = {}
  for index = 1, 30 do
    names[index] = string.format("Member %02d", index)
  end
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index, name in ipairs(names) do
    replicas[index] = Replica.new(net, name, { random = random })
    replicas[index]:Login()
  end
  net:Advance(100)
  local since = net:Now()
  local fresh = Replica.new(net, "Aaa First", { random = random })
  fresh:Login()
  net:Advance(100)
  T.eq(Replica.count(net, "A", nil, since), 30, "every peer whispers once")
  T.eq(Replica.count(net, "S", nil, since), 0, "and nobody sends a summary")
  T.eq(#fresh:PeerNames(), 30, "the new replica knows all 30 peers")
end

-- Two replicas that differ: one summary with the table that differs
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  a:Login()
  net:Advance(100)
  b.sync:Put("debug", "key", "text")
  b:Login()
  advanceUntilCount(net, 2, 41)
  local hello = last(net)
  T.eq(Replica.codec.decode(hello.text), "H", "the new replica sends its hello")
  T.eq(hello.from, "Other One", "from its own name")
  net:Advance(100)
  T.eq(Replica.count(net, "S"), 1, "the other replica answers with one summary")
  local summary = last(net)
  local _, versions = Replica.codec.decode(summary.text)
  T.eq(summary.from, "Nota Scam", "the summary comes from the replica that differs")
  T.eq(versions, { debug = a:Version("debug") }, "it lists only the table that differs, with the own version")
  T.ok(summary.time - hello.time >= 1 and summary.time - hello.time <= 8.5,
    "the answer waits 1 to 8 seconds after the hello arrives")
  T.eq(b:PeerNames(), { "Nota Scam" }, "the new replica knows the peer that answered")
  T.eq(a:PeerNames(), { "Other One" }, "the old replica knows the new one")
  T.eq(b.session.peers["Nota Scam"].versions.debug, a:Version("debug"), "the peer is listed with its version")
  T.ok(a:Version("debug") ~= b:Version("debug"), "which is not the version of the new replica")
  T.eq(b.session:DifferingTables(b.session.peers["Nota Scam"]), {},
    "after the pull the peer holds nothing that the new replica lacks")
  T.eq(b.session:StatusLines()[3]:match(", (.+)$"), "no newer data known", "and the status says so")
  T.eq(a.session:DifferingTables(a.session.peers["Other One"]), { "debug" },
    "the old replica lacks the record of the new one")
  T.eq(a.session:StatusLines()[3]:match(", (.+)$"), "has newer data in debug", "and its status names the table")
  T.eq(a.session.peers["Other One"].versions, { character = b:Version("character"), debug = b:Version("debug"),
    guildchat = b:Version("guildchat") }, "a hello gives all versions of the sender")
  for _, entry in ipairs(discoveryLog(net)) do
    T.eq(entry.distribution, "GUILD", "a hello and a summary travel on the guild channel")
  end

  -- /oooo sync status shows the session of the game
  b.ns.syncSession.current = b.session
  local lines = b.ns.syncCommands.statusLines()
  T.eq(lines[#lines - 2], "discovery: done", "the status command shows the state of discovery")
  T.eq(lines[#lines - 1], "peers: 1", "and the number of peers")
  T.ok(lines[#lines]:find("^  Nota Scam: last message %d+ s ago, no newer data known$"), "and one line per peer")

  -- The peer goes offline
  a:Logout()
  T.eq(b:PeerNames(), {}, "a peer that goes offline leaves the list")
  T.eq(a:PeerNames(), {}, "a replica that logs out forgets its peers")
  net:Advance(100)

  -- It returns: a new hello, and both know each other again
  a:Login()
  net:Advance(100)
  T.eq(Replica.count(net, "H", "Nota Scam"), 2, "a replica that logs in again sends a hello again")
  T.eq(b:PeerNames(), { "Nota Scam" }, "the replica is a peer again")
  T.eq(a:PeerNames(), { "Other One" }, "and it knows the one that answered")

  -- A peer that leaves the guild
  net:Leave("Nota Scam")
  T.eq(b:PeerNames(), {}, "a peer that leaves the guild leaves the list")
end

-- 50 replicas in one state and one new replica in another: few summaries
for seed = 1, 3 do
  local seeded = T.newRandom(seed)
  local net = Fakenet.new({ random = seeded, minDelay = 0.05, maxDelay = 0.15 })
  local old = {}
  for index = 1, 50 do
    old[index] = Replica.new(net, "Old " .. index, { random = seeded })
    old[index]:Login()
  end
  net:Advance(100)
  T.eq(Replica.count(net, "H"), 50, "each of 50 replicas sends one hello")
  T.eq(Replica.count(net, "S"), 0, "50 equal replicas send no summary")
  T.eq(#old[1]:PeerNames() + #old[50]:PeerNames() > 0, true, "replicas know the ones whose hello they heard")

  local new = Replica.new(net, "New One", { random = seeded })
  new.sync:Put("debug", "key", "text")
  new:Login()
  net:Advance(100)
  local summaries = Replica.count(net, "S")
  T.ok(summaries >= 1, "at least one replica answers the new one (seed " .. seed .. ")")
  T.ok(summaries <= 5, "at most 5 of 50 replicas answer, got " .. summaries .. " (seed " .. seed .. ")")
  T.eq(#new:PeerNames(), 50, "the new replica knows all 50 peers")
  T.eq(Replica.count(net, "A", nil, net:Now() - 100), 50 - summaries,
    "a peer that answered with a summary sends no whisper; every other one whispers once")
  T.eq(new.session:DifferingTables(new.session:PeerList()[1]), {}, "and has pulled what the peer holds")
  T.eq(old[1].sync:Count("debug"), 0, "the old replicas hold no record")
  for index = 1, 50 do
    T.eq(old[index].session.answerTimer, nil, "no answer is left pending")
  end
end

---Sends a hand-made hello or summary from a member that runs no session, so that nothing but the replica
---under test reacts.
---@param endpoint FakenetEndpoint
---@param messageType string
---@param versions table<string, string>
local function sendAs(endpoint, messageType, versions)
  endpoint:Send(Replica.codec.encode(messageType, versions), "GUILD")
end

---A table version that no replica of these tests has
local OTHER = "!!!!!ZZZZ!!!!!!!"

-- Two hellos within the waiting time give one summary, with the tables of both
do
  local net, a = setup({ "Nota Scam" })
  local b, c = net:Join("Other One"), net:Join("Third One")
  a:Login()
  net:Advance(100)
  T.eq(count(net), 1, "one hello so far")
  sendAs(b, "H", { debug = OTHER })
  net:Advance(0.5)
  sendAs(c, "H", { character = OTHER, future = OTHER })
  net:Advance(20)
  T.eq(Replica.count(net, "S", "Nota Scam"), 1, "one summary answers two hellos")
  local _, versions = Replica.codec.decode(last(net).text)
  T.eq(versions, { debug = a:Version("debug"), character = a:Version("character") },
    "it lists the tables of both hellos and not the table that this replica does not have")
  T.eq(a:PeerNames(), { "Other One", "Third One" }, "the peers are listed in arrival order")

  -- A hello that lists none of the tables of this replica gets no answer
  local before = count(net)
  sendAs(b, "H", { future = OTHER })
  net:Advance(20)
  T.eq(count(net) - before, 1, "a table that the sender does not list is not answered")
end

-- An answer is suppressed by a summary of another peer with the same version, and only for that table
do
  local net, a = setup({ "Nota Scam" })
  local b, c = net:Join("Other One"), net:Join("Third One")
  a:Login()
  net:Advance(100)
  sendAs(b, "H", { debug = OTHER, character = OTHER })
  net:Advance(0.5)
  T.ok(a.session.answerTimer, "an answer is pending")
  -- Another peer in the state of this replica answers first, for one of the two tables
  sendAs(c, "S", { debug = a:Version("debug") })
  net:Advance(20)
  local _, versions = Replica.codec.decode(last(net).text)
  T.eq(last(net).from, "Nota Scam", "the replica still answers")
  T.eq(versions, { character = a:Version("character") }, "without the table that the other peer announced")

  -- The same with both tables announced: no answer at all
  local before = count(net)
  sendAs(b, "H", { debug = OTHER, character = OTHER })
  net:Advance(0.5)
  sendAs(c, "S", { debug = a:Version("debug"), character = a:Version("character") })
  net:Advance(20)
  T.eq(count(net) - before, 2, "no summary when a peer has announced every table")
  T.eq(a.session.answerTimer, nil, "and no answer is pending")

  -- A hello of a third member with the version of this replica suppresses too
  before = count(net)
  sendAs(b, "H", { debug = OTHER, character = a:Version("character") })
  net:Advance(0.5)
  sendAs(c, "H", { debug = a:Version("debug"), character = a:Version("character") })
  net:Advance(20)
  T.eq(count(net) - before, 2, "a hello with the version of this replica stops the answer as well")

  -- A summary with another version does not suppress
  before = count(net)
  sendAs(b, "H", { debug = OTHER, character = a:Version("character") })
  net:Advance(0.5)
  sendAs(c, "S", { debug = "!!!!!YYYY!!!!!!!" })
  net:Advance(20)
  T.eq(count(net) - before, 3, "a summary with another version does not stop the answer")
  T.eq(a.session.peers["Third One"].versions.debug, "!!!!!YYYY!!!!!!!", "a summary updates the versions of its sender")
  T.eq(a.session.peers["Third One"].versions.character, a:Version("character"),
    "and keeps the versions that it does not list")
end

-- Leaving the guild stops the session
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  b.sync:Put("debug", "key", "text")
  a:Login()
  b:Login()
  net:Advance(100)
  T.eq(a:PeerNames(), { "Other One" }, "the two replicas know each other")
  a.session:OnGuildStateChanged(false)
  a.transport:SetActive(false)
  T.eq(a:PeerNames(), {}, "outside the guild the peers are forgotten")
  T.eq(a.session:StatusLines()[1], "discovery: not started (not in the guild)", "and discovery is not started")
  local before = count(net)
  net:Advance(100)
  T.eq(count(net), before, "a replica outside the guild sends nothing")

  -- A hello that is pending when the character leaves is not sent
  local c = Replica.new(net, "Third One", { random = random })
  c:Login()
  net:Advance(5)
  c.session:OnGuildStateChanged(false)
  net:Advance(100)
  T.eq(Replica.count(net, "H", "Third One"), 0, "a pending hello is cancelled")
end

T.finish()
