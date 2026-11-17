-- Host test of the pull in Addon/Src/Sync/SyncPull.lua, with full replicas on the fake network and with
-- hand-made messages from members that run no session.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec

---Joins a member that runs no session and records the checked messages that it receives.
---@param net Fakenet
---@param name string
---@return table member { endpoint, got = { { type, fields, sender } }, Send(type, target, ...) }
local function joinRaw(net, name)
  local member = { endpoint = net:Join(name), got = {} }
  member.endpoint.receive = function(text, _, sender)
    local messageType, fields = codec.decode(text)
    -- A guild message also comes back to its sender
    if sender ~= name then
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
    return entry.from == "Nota Scam" and entry.distribution ~= "WHISPER"
  end), 1, "the batches travel as whispers; only the hello went to the guild")
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

T.finish()
