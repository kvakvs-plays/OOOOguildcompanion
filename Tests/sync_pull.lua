-- Host test of the pull in Addon/Src/Sync/SyncPull.lua, with full replicas on the fake network and with
-- hand-made messages from members that run no session.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)
-- The push has its own test (sync_push.lua)
Replica.withoutPush = true

local random = T.newRandom()
local codec = Replica.codec

---Joins a member that runs no session and records the checked messages that it receives.
---@param net Fakenet
---@param name string
---@return table member { endpoint, got = { { type, fields, sender } }, Send(type, target, ...) }
local function joinRaw(net, name)
  local member = { endpoint = net:Join(name), got = {} }
  member.endpoint.receive = function(text, distribution, sender)
    local messageType, fields = codec.decode(text)
    -- Only the answers to its own requests: the whispers
    if distribution == "WHISPER" then
      member.got[#member.got + 1] = { type = messageType, fields = fields, sender = sender }
    end
  end
  ---Sends a hand-made message on the channel of its type.
  function member:Send(messageType, target, ...)
    self.endpoint:Send(codec.encode(messageType, ...), Replica.protocol.CHANNELS[messageType], target)
  end
  ---Returns the received messages of one type.
  function member:Of(messageType)
    local list = {}
    for _, message in ipairs(self.got) do
      if message.type == messageType then
        list[#list + 1] = message.fields
      end
    end
    return list
  end
  return member
end

---Moves the clock in small steps until `condition` gives true; fails after `limit` seconds.
---@param net Fakenet
---@param condition fun(): any
---@param limit number
---@param what string What is waited for, for the failure message
local function advanceUntil(net, condition, limit, what)
  local waited = 0
  while not condition() do
    T.ok(waited < limit, what .. " within " .. limit .. " seconds")
    net:Advance(0.25)
    waited = waited + 0.25
  end
end

---Makes a network with one replica that is logged in and has finished its discovery.
---@param options table? Options of `Fakenet.new`; the random source is filled in
---@return Fakenet net
---@return TestReplica a
local function setup(options)
  options = options or {}
  options.random = options.random or random
  local net = Fakenet.new(options)
  local a = Replica.new(net, "Nota Scam", { random = random })
  a:Login()
  net:Advance(100)
  return net, a
end

--------------------------------------------------------------------------------
-- Responder
--------------------------------------------------------------------------------

-- A hand-made Q gets the expected batches
do
  local net, a = setup()
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index .. " " .. string.rep("x", index % 40))
  end
  a.sync:Delete("debug", "key7")
  local store, versionId = a.ns.syncStore, a.ns.versionId
  local tbl = a.sync:GetTable("debug")
  local b = joinRaw(net, "Other One")
  b:Send("Q", "Nota Scam", "debug", 1, 777, "")
  net:Advance(60)

  local batches = b:Of("D")
  T.ok(#batches > 5, "300 records travel in several batches")
  T.eq(#b.got, #batches, "the requester gets nothing but batches")
  local previous, total = versionId.ZERO, 0
  for index, batch in ipairs(batches) do
    T.eq(batch.table, "debug", "a batch names the table")
    T.eq(batch.nonce, 777, "a batch repeats the nonce")
    T.eq(batch.batch, index, "the batches are numbered from 1")
    T.eq(batch.last, index == #batches, "only the last batch has the flag")
    local bytes = 0
    for _, record in ipairs(batch.records) do
      T.ok(record.id > previous, "the records are in ascending id order")
      previous = record.id
      bytes = bytes + store.recordSize(record)
      total = total + 1
      local stored = tbl.records[record.key]
      T.eq({ record.id, record.payload, record.tombstone }, { stored.v, stored.d, stored.x },
        "a record travels with its id, payload, and tombstone mark")
    end
    T.ok(#batch.records >= 1 and bytes <= 2000, "a batch is not empty and is under the size limit")
    if not batch.last then
      T.eq({ batch.rest, batch.wants }, { {}, {} }, "only the last batch carries the clock rest and the wants")
    end
  end
  T.eq(total, 300, "every record is sent once, the tombstone too")
  T.eq(batches[#batches].rest, {}, "no clock rest when the records carry the clock")
  T.eq(batches[#batches].wants, {}, "no wants when the requester has nothing")
  T.eq(a.session.serving, nil, "the responder is free after the last batch")
  T.eq(net:Count(function(entry)
    return codec.decode(entry.text) == "D" and entry.distribution ~= "WHISPER"
  end), 0, "the batches travel as whispers")
  T.eq(Replica.count(net, "S", "Nota Scam"), 1, "the responder tells the guild the version that its writes have made")
end

-- The digest limits the delta; an empty delta is one last batch; wants and clock rest
do
  local net, a = setup()
  local store, versionId = a.ns.syncStore, a.ns.versionId
  local tbl = a.sync:GetTable("debug")
  local now = math.floor(net:Now())
  local x1, x2 = versionId.make(now - 50, "XXXX", 0), versionId.make(now - 40, "XXXX", 0)
  local y1 = versionId.make(now - 30, "YYYY", 0)
  store.apply(tbl, "one", x1, "first of X")
  store.apply(tbl, "two", x2, "second of X")
  -- Y replaces the second write of X: the clock keeps X's id, but no record carries it
  store.apply(tbl, "two", y1, "Y over X")
  local b = joinRaw(net, "Other One")

  b:Send("Q", "Nota Scam", "debug", 1, 1, x1)
  net:Advance(10)
  local delta = b:Of("D")[1]
  T.eq(#b:Of("D"), 1, "a small delta is one batch")
  T.eq(delta.last, true, "which is the last")
  T.eq(delta.records, { { key = "two", id = y1, payload = "Y over X" } }, "only the records above the digest are sent")
  T.eq(delta.rest, { XXXX = x2 }, "the clock rest carries the clock value that no record carries")

  b.got = {}
  b:Send("Q", "Nota Scam", "debug", 1, 2, store.digest(tbl))
  net:Advance(10)
  T.eq(b:Of("D"), { { table = "debug", nonce = 2, batch = 1, last = true, records = {}, rest = {}, wants = {} } },
    "a requester that has everything gets one empty last batch")

  b.got = {}
  local ahead = versionId.make(now - 10, "XXXX", 0)
  local unknown = versionId.make(now - 20, "ZZZZ", 0)
  b:Send("Q", "Nota Scam", "debug", 1, 3, ahead .. y1 .. unknown)
  net:Advance(10)
  T.eq(b:Of("D")[1].wants, { XXXX = x2, ZZZZ = versionId.ZERO },
    "the wants name the origins for which the requester is ahead, with the responder's clock value")
end

-- A second Q during a transfer gets B; afterwards the responder serves again
do
  local net, a = setup({ sendRate = 2000 })
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  local b, c = joinRaw(net, "Other One"), joinRaw(net, "Third One")
  b:Send("Q", "Nota Scam", "debug", 1, 11, "")
  net:Advance(2)
  T.ok(a.session.serving, "the transfer is running")
  T.eq(a.session:StatusLines()[3]:match("^serving: debug to Other One, batch %d+ of %d+$") ~= nil, true,
    "the status shows the pull that is served")
  c:Send("Q", "Nota Scam", "debug", 1, 22, "")
  net:Advance(2)
  T.eq(c.got, { { type = "B", sender = "Nota Scam",
    fields = { table = "debug", nonce = 22, reason = "busy", retry = 30 } } },
    "a second request during a transfer is refused with a retry time")
  net:Advance(60)
  local batches = b:Of("D")
  T.eq(batches[#batches].last, true, "the first transfer goes on to its end")
  T.eq(#c:Of("D"), 0, "the refused requester gets no batch")

  c.got = {}
  c:Send("Q", "Nota Scam", "debug", 1, 23, "")
  net:Advance(60)
  T.eq(#c:Of("D"), #batches, "after the transfer the responder serves the next request")

  -- A new request of the same peer replaces its running one
  b.got = {}
  b:Send("Q", "Nota Scam", "debug", 1, 12, "")
  net:Advance(2)
  b:Send("Q", "Nota Scam", "debug", 1, 13, "")
  net:Advance(60)
  T.eq(#b:Of("B"), 0, "a second request of the same peer is not refused")
  local finished = 0
  for _, batch in ipairs(b:Of("D")) do
    if batch.last then
      finished = finished + 1
      T.eq(batch.nonce, 13, "the transfer that ends is the one of the new request")
    end
  end
  T.eq(finished, 1, "one transfer reaches its last batch")
end

-- Another schema and an unknown table get B, and no record is sent
do
  local net, a = setup()
  a.sync:Put("debug", "key", "text")
  local b = joinRaw(net, "Other One")
  b:Send("Q", "Nota Scam", "debug", 2, 31, "")
  b:Send("Q", "Nota Scam", "future", 1, 32, "")
  net:Advance(10)
  table.sort(b.got, function(left, right)
    return left.fields.nonce < right.fields.nonce
  end)
  T.eq(b.got, {
    { type = "B", sender = "Nota Scam", fields = { table = "debug", nonce = 31, reason = "schema", retry = 3600 } },
    { type = "B", sender = "Nota Scam", fields = { table = "future", nonce = 32, reason = "unknown", retry = 3600 } },
  }, "another schema and an unknown table are refused")
  T.eq(a.session.serving, nil, "a refused request does not occupy the responder")
end

-- The requester goes offline: the responder is free for the next request
do
  local net, a = setup({ sendRate = 2000 })
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  local b, c = joinRaw(net, "Other One"), joinRaw(net, "Third One")
  b:Send("Q", "Nota Scam", "debug", 1, 41, "")
  net:Advance(2)
  T.ok(a.session.serving, "the transfer is running")
  net:SetOnline("Other One", false)
  T.eq(a.session.serving, nil, "the responder is free when the requester goes offline")
  local sent = net:Count()
  c:Send("Q", "Nota Scam", "debug", 1, 42, "")
  net:Advance(60)
  T.eq(c:Of("D")[#c:Of("D")].last, true, "the next request is served to its end")
  T.eq(#c:Of("B"), 0, "and is not refused")
  T.ok(net:Count() > sent, "the responder sends again")

  -- A transfer whose progress callback never comes is given up after 120 seconds
  a.session.serving = { peer = "Other Two", table = "debug", nonce = 1, batches = { {} }, rest = {}, wants = {},
    sent = 1, left = 0, activeAt = net:Now() }
  c.got = {}
  c:Send("Q", "Nota Scam", "debug", 1, 43, "")
  net:Advance(10)
  T.eq(#c:Of("B"), 1, "a stuck transfer still refuses a request within 120 seconds")
  net:Advance(120)
  c.got = {}
  c:Send("Q", "Nota Scam", "debug", 1, 44, "")
  net:Advance(60)
  T.eq(#c:Of("B"), 0, "after 120 seconds without a step the stuck transfer is given up")
  T.eq(c:Of("D")[#c:Of("D")].last, true, "and the request is served")

  -- A session that stops ends its transfer
  c:Send("Q", "Nota Scam", "debug", 1, 45, "")
  net:Advance(2)
  T.ok(a.session.serving, "a transfer is running")
  a:Logout()
  T.eq(a.session.serving, nil, "a replica that logs out serves nothing")
end

--------------------------------------------------------------------------------
-- Requester
--------------------------------------------------------------------------------

local pull

-- The source choice, on a table of cases
do
  local a = Replica.new(Fakenet.new({ random = random }), "Nota Scam", { random = random })
  pull = a.ns.syncPull
  local make = a.ns.versionId.make
  local function version(seconds, fingerprint)
    return make(1795000000 + seconds, "AAAA", 0) .. (fingerprint or "!!!!!")
  end
  local own = version(100)
  local function peer(order, tableVersion, retryAt)
    return { name = "Peer " .. order, order = order, versions = { debug = tableVersion }, lastSeen = 0,
      retryAt = retryAt and { debug = retryAt } or nil }
  end
  local now = 5000
  ---{ what, peers, merged, expected name, expected retry time }
  local cases = {
    { "no peer", {}, nil, nil, nil },
    { "a peer with the own version", { peer(1, own) }, nil, nil, nil },
    { "a peer without the table", { { name = "Peer 1", order = 1, versions = {}, lastSeen = 0 } }, nil, nil, nil },
    { "one peer that differs", { peer(1, version(50)) }, nil, "Peer 1", nil },
    { "the greatest maxId", { peer(1, version(50)), peer(2, version(300)), peer(3, version(200)) }, nil, "Peer 2",
      nil },
    { "a tie goes to the first that answered", { peer(3, version(300, "aaaaa")), peer(2, version(300, "bbbbb")),
      peer(4, version(300, "ccccc")) }, nil, "Peer 2", nil },
    { "a merged version is skipped", { peer(1, version(300)), peer(2, version(200)) }, { [version(300)] = true },
      "Peer 2", nil },
    { "all versions merged", { peer(1, version(300)) }, { [version(300)] = true }, nil, nil },
    { "a peer that has to wait is passed over", { peer(1, version(300), now + 60), peer(2, version(200)) }, nil,
      "Peer 2", now + 60 },
    { "only peers that have to wait", { peer(1, version(300), now + 60), peer(2, version(200), now + 30) }, nil, nil,
      now + 30 },
    { "a wait that is over", { peer(1, version(300), now - 1) }, nil, "Peer 1", nil },
    { "an older maxId than the own one still differs", { peer(1, version(10)) }, nil, "Peer 1", nil },
  }
  for _, case in ipairs(cases) do
    local source, retryAt = pull.chooseSource(case[2], "debug", own, case[3], now)
    T.eq(source and source.name, case[4], "source choice: " .. case[1])
    T.eq(retryAt, case[5], "source choice, retry time: " .. case[1])
  end

  -- The version of the responder, from the own clock and the wants
  local store = a.ns.syncStore
  local tbl = store.newTable(1)
  local x, y, z = make(1795000010, "XXXX", 0), make(1795000020, "YYYY", 0), make(1795000030, "ZZZZ", 0)
  local xOld = make(1795000005, "XXXX", 0)
  store.apply(tbl, "x", x, "x")
  store.apply(tbl, "y", y, "y")
  store.apply(tbl, "z", z, "z")
  T.eq(pull.responderVersion(tbl, {}), store.tableVersion(tbl), "without wants the responder has the own version")
  T.eq(pull.responderVersion(tbl, { XXXX = xOld, ZZZZ = a.ns.versionId.ZERO }),
    store.versionOfClock({ XXXX = xOld, YYYY = y }), "the wants lower the responder's clock")
  T.eq(pull.responderVersion(tbl, { XXXX = z, YYYY = make(1795000099, "YYYY", 0), QQQQ = xOld }),
    store.tableVersion(tbl), "a want of another origin, a greater one, and an unknown origin change nothing")
end

---Joins a member that runs no session but answers every hello with a summary, so that a replica takes it
---for a peer, and that records the pull requests it gets.
---@param net Fakenet
---@param name string
---@param versions table<string, string> What the summary announces
---@param onQuery (fun(source: table, request: table))? Called for every pull request
---@return table source A member of `joinRaw` with `queries`
local function joinSource(net, name, versions, onQuery)
  local source = joinRaw(net, name)
  source.queries = {}
  local record = source.endpoint.receive
  source.endpoint.receive = function(text, distribution, sender)
    record(text, distribution, sender)
    local messageType, fields = codec.decode(text)
    if messageType == "H" and sender ~= name then
      source:Send("S", nil, versions)
    elseif messageType == "Q" then
      source.queries[#source.queries + 1] = fields
      if onQuery then
        onQuery(source, fields)
      end
    end
  end
  return source
end

---A table version that no replica has, with a recent `maxId`.
local function otherVersion(replica, net, origin)
  return replica.ns.versionId.make(math.floor(net:Now()) - 5, origin or "RRRR", 0) .. "!!!!!"
end

-- A fresh replica pulls 500 records and ends with the table version of the source
do
  local net, a = setup()
  for index = 1, 500 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  a.sync:Delete("debug", "key9")
  local b = Replica.new(net, "Other One", { random = random })
  local changes = {}
  b.sync.RegisterCallback(changes, "OnRecordChanged", function(_, tableName, key, payload, isRemote)
    changes[#changes + 1] = { tableName, key, payload, isRemote }
  end)
  b:Login()
  net:Advance(25)
  T.eq(b.session.discovered, false, "nothing is pulled while the answers are collected")
  T.eq(Replica.count(net, "Q"), 0, "no pull request before discovery ends")
  net:Advance(100)
  T.eq(Replica.count(net, "Q", "Other One"), 1, "one pull request for the table that differs")
  T.eq(b:Version("debug"), a:Version("debug"), "the fresh replica ends with the table version of the source")
  T.eq({ b.sync:Count("debug") }, { 499, 1 }, "it has the 499 records and the tombstone")
  T.eq(b.sync:Get("debug", "key500"), "text of record 500", "a record has its payload")
  T.eq(#changes, 500, "OnRecordChanged fires for every received record")
  T.eq(changes[1], { "debug", "key1", "text of record 1", true }, "with the flag for a remote change")
  T.eq(b.sync:GetTable("debug").syncedAt ~= nil, true, "the time of the completed pull is stored")
  T.eq(b.sync:GetTable("character").syncedAt, nil, "a table that was not pulled has no such time")
  T.eq(Replica.count(net, "S", "Other One"), 1, "the requester announces its new version")
  T.eq(b.session.pull, nil, "no pull is left running")
  T.eq(a.session.serving, nil, "and the source serves nothing")
  T.eq(b.session.merged.debug[a:Version("debug")], true, "the version of the source counts as merged")
  net:Advance(3600)
  T.eq(Replica.count(net, "Q"), 1, "no further pull request follows")
end

-- Message loss after batch 3: the timeout fires, the applied batches stay, a second pull completes the table
do
  local net, a = setup()
  for index = 1, 500 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  local losing = true
  net.dropIf = function(entry)
    local messageType, fields = codec.decode(entry.text)
    return losing and messageType == "D" and fields.batch > 3
  end
  local b = Replica.new(net, "Other One", { random = random })
  b:Login()
  net:Advance(60)
  T.ok(b.session.pull, "the pull waits for batch 4")
  T.eq(b.session.pull.nextBatch, 4, "three batches were applied")
  T.eq(b.session:StatusLines()[4], "pulling: debug from Nota Scam, waiting for batch 4", "the status shows the pull")
  local partial = b.sync:Count("debug")
  T.ok(partial > 0 and partial < 500, "a part of the records has arrived")
  net:Advance(60)
  T.eq(b.session.pull, nil, "the timeout ends the pull after 60 seconds without a batch")
  T.eq(b.sync:Count("debug"), partial, "the applied batches stay")
  T.eq(b.sync:GetTable("debug").syncedAt, nil, "a pull that was cut is not a completed one")
  T.eq(Replica.count(net, "Q"), 1, "the peer is not asked again at once")
  losing = false
  net:Advance(300)
  T.eq(Replica.count(net, "Q"), 2, "after its wait the peer is asked again")
  T.eq(b:Version("debug"), a:Version("debug"), "the second pull completes the table")
  T.eq(b.sync:Count("debug"), 500, "all records are there")
  -- The second pull carries only what the first one did not deliver
  local firstNonce, resent
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "Q" then
      resent = firstNonce and 0 or nil
      firstNonce = firstNonce or fields.nonce
    elseif messageType == "D" and resent then
      resent = resent + #fields.records
    end
  end
  T.eq(resent, 500 - partial, "the second pull sends only the records that were missing")
end

-- The source goes offline during the pull: the pull moves to another peer
do
  local net, a = setup({ sendRate = 2000 })
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  -- A second source with the same records and one more, so that both answer the hello
  local c = Replica.new(net, "Third One", { random = random })
  c:Login()
  net:Advance(200)
  T.eq(c:Version("debug"), a:Version("debug"), "the second source has pulled the records")
  c.sync:Put("debug", "extra", "only on the second source")
  local b = Replica.new(net, "Other One", { random = random })
  b:Login()
  advanceUntil(net, function()
    return b.session.pull
  end, 60, "the pull starts")
  net:Advance(1)
  T.ok(b.session.pull, "the pull is running")
  T.eq(b.session.pull.peer, "Third One", "the source is the peer with the greatest maxId")
  T.eq(#b:PeerNames(), 2, "both sources are known")
  c:Logout()
  T.ok(b.session.pull, "a pull is running again at once")
  T.eq(b.session.pull.peer, "Nota Scam", "it has moved to the other peer")
  net:Advance(200)
  T.eq(b:Version("debug"), a:Version("debug"), "the pull from the other peer completes the table")
  T.eq(b.sync:Count("debug"), 300, "with all its records")
end

-- Three peers with different data: the requester ends with the union
do
  local net = Fakenet.new({ random = random })
  local sources = {}
  for index, name in ipairs({ "Nota Scam", "Third One", "Fourth One" }) do
    local source = Replica.new(net, name, { random = random })
    for record = 1, 40 do
      source.sync:Put("debug", "source" .. index .. "key" .. record, "text " .. record)
    end
    sources[index] = source
  end
  -- The sources are logged in but have not found each other: each has only its own records
  for _, source in ipairs(sources) do
    source.transport:SetActive(true)
    source.session.discovered, source.session.helloSent = true, true
  end
  local b = Replica.new(net, "Other One", { random = random })
  b:Login()
  net:Advance(300)
  T.eq(#b:PeerNames(), 3, "the three peers answered the hello")
  T.eq(Replica.count(net, "Q", "Other One"), 3, "the requester pulled from each of them")
  T.eq(b.sync:Count("debug"), 120, "it ends with the union of their records")
  for index = 1, 3 do
    T.eq(b.sync:Get("debug", "source" .. index .. "key40"), "text 40", "with the records of source " .. index)
  end
  for index, source in ipairs(sources) do
    T.eq(b.session.merged.debug[source:Version("debug")], true, "the version of source " .. index .. " is merged")
  end
end

-- Hand-made answers: wrong nonce, third peer, wrong batch number, refusals, bad records
do
  local net = Fakenet.new({ random = random })
  local b = Replica.new(net, "Other One", { random = random })
  local versionId, store = b.ns.versionId, b.ns.syncStore
  local announced = otherVersion(b, net)
  local source = joinSource(net, "Nota Scam", { debug = announced })
  local third = joinRaw(net, "Third One")
  b:Login()
  net:Advance(60)
  T.eq(#source.queries, 1, "the requester asks the member that answered its hello")
  local query = source.queries[1]
  T.eq({ query.table, query.schema, query.clock }, { "debug", 1, {} }, "for the table, with its schema and clock")
  local now = math.floor(net:Now())
  local x1, x2 = versionId.make(now - 50, "XXXX", 0), versionId.make(now - 40, "XXXX", 0)
  local records = Replica.protocol.packRecords({ { key = "one", id = x1, payload = "first" } })
  local before = b:Version("debug")

  source:Send("D", "Other One", "debug", query.nonce + 1, 1, false, records)
  third:Send("D", "Other One", "debug", query.nonce, 1, false, records)
  source:Send("D", "Other One", "debug", query.nonce, 2, false, records)
  source:Send("D", "Other One", "character", query.nonce, 1, false, records)
  source:Send("B", "Other One", "debug", query.nonce + 1, "busy", 30)
  third:Send("B", "Other One", "debug", query.nonce, "busy", 30)
  net:Advance(5)
  T.eq(b:Version("debug"), before, "a delta with a wrong nonce, from a third peer, with a wrong batch number, "
    .. "or for another table changes nothing")
  T.ok(b.session.pull, "and a refusal with a wrong nonce or from a third peer does not end the pull")
  T.eq(b.session.pull.nextBatch, 1, "the pull still waits for batch 1")

  source:Send("D", "Other One", "debug", query.nonce, 1, false, records)
  net:Advance(5)
  T.eq(b.sync:Get("debug", "one"), "first", "the right batch is applied")
  source:Send("D", "Other One", "debug", query.nonce, 1, false, records)
  source:Send("D", "Other One", "debug", query.nonce, 3, false, records)
  net:Advance(5)
  T.eq(b.session.pull.nextBatch, 2, "a repeated batch and a batch that skips one are ignored")

  -- The last batch: a bad record stops its origin there, and the rest is applied
  local y1, yGone = versionId.make(now - 30, "YYYY", 0), versionId.make(now - 10, "YYYY", 0)
  local x3 = versionId.make(now - 20, "XXXX", 0)
  local future = versionId.make(now + 1000, "ZZZZ", 0)
  source:Send("D", "Other One", "debug", query.nonce, 2, true, Replica.protocol.packRecords({
    { key = "two", id = x2, payload = 5 },
    { key = "why", id = y1, payload = "of Y" },
    { key = "three", id = x3, payload = "third" },
    { key = "gone", id = yGone, tombstone = true },
    { key = "ahead", id = future, payload = "from the future" },
  }), { WWWW = versionId.make(now - 5, "WWWW", 0) })
  net:Advance(5)
  local tbl = b.sync:GetTable("debug")
  T.eq(b.sync:Get("debug", "two"), nil, "a record whose payload fails validate is dropped")
  T.eq(b.sync:Get("debug", "three"), nil, "and so is the later record of the same origin")
  T.eq(b.sync:Get("debug", "why"), "of Y", "the records of another origin are applied")
  T.eq(tbl.records.gone, { v = yGone, x = true }, "a tombstone is applied")
  T.eq(b.sync:Get("debug", "ahead"), nil, "a record with an id from the future is dropped")
  T.eq(tbl.clock, { XXXX = x1, YYYY = yGone },
    "the clock of the bad origin stays at its last good record, and the clock rest is not merged")
  T.eq(b.session.pull, nil, "the last batch ends the pull")
  T.eq(tbl.syncedAt, nil, "a pull with dropped records is not a completed one")
  T.eq(b.session.merged.debug[announced], nil, "and its source does not count as merged")
  T.eq(Replica.count(net, "S", "Other One"), 1, "the requester announces its new version")
  net:Advance(1700)
  T.eq(#source.queries, 1, "the peer that sent a bad record is not asked again for 30 minutes")
  advanceUntil(net, function()
    return #source.queries == 2
  end, 200, "the peer is asked again")
  T.eq(source.queries[2].clock, tbl.clock, "with the clock that the first pull left")

  -- A complete answer with a clock rest and wants
  local second = source.queries[2]
  now = math.floor(net:Now())
  local w1 = versionId.make(now - 5, "WWWW", 0)
  source:Send("D", "Other One", "debug", second.nonce, 1, true, Replica.protocol.packRecords({
    { key = "three", id = x3, payload = "third" },
  }), { WWWW = w1 }, { YYYY = y1 })
  net:Advance(5)
  T.eq(tbl.clock, { XXXX = x3, YYYY = yGone, WWWW = w1 }, "the clock rest is merged")
  T.eq(tbl.syncedAt ~= nil, true, "the pull counts as completed")
  T.eq(b.session.merged.debug[store.versionOfClock({ XXXX = x3, YYYY = y1, WWWW = w1 })], true,
    "the merged version is the one of the responder: the own clock, lowered by the wants")
  net:Advance(3600)
  T.eq(#source.queries, 2, "a peer whose version is merged is not asked again")
end

-- A clock rest with an id from the future is not merged
do
  local net = Fakenet.new({ random = random })
  local b = Replica.new(net, "Other One", { random = random })
  local versionId = b.ns.versionId
  local source = joinSource(net, "Nota Scam", { debug = otherVersion(b, net) }, function(source, request)
    local now = math.floor(net:Now())
    source:Send("D", "Other One", request.table, request.nonce, 1, true, {},
      { XXXX = versionId.make(now - 5, "XXXX", 0), YYYY = versionId.make(now + 1000, "YYYY", 0) })
  end)
  b:Login()
  net:Advance(100)
  T.eq(#source.queries, 1, "the pull ran")
  T.eq(b.sync:GetTable("debug").clock, {}, "no entry of a clock rest with a bad id is merged")
  T.eq(b.sync:GetTable("debug").syncedAt, nil, "and the pull does not count as completed")
end

-- Refusals: the peer is asked again after its retry time, and never sooner than 5 seconds
do
  local net = Fakenet.new({ random = random })
  local b = Replica.new(net, "Other One", { random = random })
  local retry = 30
  local source = joinSource(net, "Nota Scam", { debug = otherVersion(b, net) }, function(source, request)
    source:Send("B", "Other One", request.table, request.nonce, "busy", retry)
  end)
  b:Login()
  advanceUntil(net, function()
    return #source.queries == 1
  end, 60, "the first request is sent")
  net:Advance(1)
  T.eq(b.session.pull, nil, "the refusal ends the pull")
  retry = 0
  net:Advance(28)
  T.eq(#source.queries, 1, "the peer is not asked again before its retry time")
  net:Advance(4)
  T.eq(#source.queries, 2, "it is asked again after 30 seconds")
  T.ok(source.queries[2].nonce ~= source.queries[1].nonce, "with a new nonce")
  net:Advance(4)
  T.eq(#source.queries, 2, "a retry time of 0 still waits 5 seconds")
  net:Advance(3)
  T.eq(#source.queries, 3, "then the peer is asked again")
end

-- A table keyed by character: a record of a name outside the roster is counted as seen and not kept
do
  local net = Fakenet.new({ random = random })
  local b = Replica.new(net, "Other One", { random = random })
  local versionId = b.ns.versionId
  local ids = {}
  local source = joinSource(net, "Nota Scam", { character = otherVersion(b, net) }, function(source, request)
    local now = math.floor(net:Now())
    local function payload(level)
      return { class = "MAGE", level = level, origins = { "XXXX" } }
    end
    ids = { versionId.make(now - 30, "XXXX", 0), versionId.make(now - 20, "XXXX", 0),
      versionId.make(now - 10, "XXXX", 0) }
    source:Send("D", "Other One", request.table, request.nonce, 1, true, Replica.protocol.packRecords({
      { key = "Nota Scam", id = ids[1], payload = payload(10) },
      { key = "Left Guild", id = ids[2], payload = payload(20) },
      { key = "Other One", id = ids[3], payload = payload(30) },
    }))
  end)
  b:Login()
  net:Advance(100)
  T.eq(source.queries[1].table, "character", "the character table is pulled")
  T.eq(b.sync:Get("character", "Nota Scam").level, 10, "the record of a member is kept")
  T.eq(b.sync:Get("character", "Left Guild"), nil, "the record of a name outside the roster is not kept")
  T.eq(b.sync:Get("character", "Other One").level, 30, "the later record of the same origin is still applied")
  T.eq(b.sync:GetTable("character").clock, { XXXX = ids[3] }, "the clock counts all three records as seen")
  T.eq(b.sync:GetTable("character").syncedAt ~= nil, true, "the pull counts as completed")
end

-- No pull before the roster is filled
do
  local net, a = setup()
  a.sync:Put("debug", "key", "text")
  local b = Replica.new(net, "Other One", { random = random })
  local known = false
  b.session.parts.playerName = function()
    return known and "Other One" or "Not Yet Known"
  end
  b:Login()
  net:Advance(100)
  T.eq(b.session.discovered, true, "discovery is done")
  T.eq(Replica.count(net, "Q"), 0, "no pull request while the roster does not hold the own character")
  known = true
  b.session:OnRosterChanged()
  net:Advance(10)
  T.eq(Replica.count(net, "Q"), 1, "the pull starts when the roster is filled")
  T.eq(b:Version("debug"), a:Version("debug"), "and completes")

  -- A session that stops ends its pull
  local c = Replica.new(net, "Third One", { random = random })
  net.sendRate = 20
  c:Login()
  advanceUntil(net, function()
    return c.session.pull
  end, 120, "the pull starts")
  T.ok(c.session.pull, "a pull is running")
  c:Logout()
  T.eq(c.session.pull, nil, "a replica that logs out ends its pull")
  T.eq(c.session.merged, {}, "and forgets what it merged")
end

-- ApplyRemote: a validate function that raises on a payload is a refusal, not an error
do
  local net, a = setup()
  a.sync:RegisterTable({ name = "strict", schema = 1, keyKind = "free", maxRecordBytes = 100, writers = "anyone",
    validate = function(_, payload)
      return #payload.text > 0
    end })
  local id = a.ns.versionId.make(math.floor(net:Now()) - 5, "XXXX", 0)
  local changed, dropped
  local succeeded = pcall(function()
    changed, dropped = a.sync:ApplyRemote("strict", { { key = "k", id = id, payload = "not a table" } })
  end)
  T.eq({ succeeded, changed, dropped }, { true, {}, 1 }, "a payload on which validate raises is dropped")
  T.eq({ a.sync:ApplyRemote("unknown", { { key = "k", id = id, payload = "x" } }) }, { {}, 1 },
    "records for a table that is not registered are dropped")
  local withFunction = { text = "good", deep = { function() end } }
  T.eq({ a.sync:ApplyRemote("strict", { { key = "k", id = id, payload = withFunction } }) }, { {}, 1 },
    "a payload that holds a function is dropped")
end

-- The system line of a whisper to an offline name
do
  local comm = Replica.new(Fakenet.new({ random = random }), "Nota Scam", { random = random }).ns.syncComm
  local format = "No player named '%s' is currently playing."
  T.eq(comm.offlineNoticeName("No player named 'Nota Scam' is currently playing.", format), "Nota Scam",
    "the name is read out of the offline line")
  T.eq(comm.offlineNoticeName("No player named 'Nota Scam' is currently playing!", format), nil,
    "another line gives no name")
  T.eq(comm.offlineNoticeName("Nota Scam has gone offline.", format), nil, "the logout line gives no name")
  T.eq(comm.offlineNoticeName("Spieler (Nota Scam) nicht gefunden + 100%.", "Spieler (%s) nicht gefunden + 100%%."),
    nil, "a format with a doubled percent sign does not match a single one")
  T.eq(comm.offlineNoticeName("Spieler [Nota Scam] ist nicht online.", "Spieler [%s] ist nicht online."), "Nota Scam",
    "the magic characters of a format are taken as text")
end

T.finish()
