-- Host test of Addon/Src/Sync/SyncComm.lua (the sender checks and the transport interface) and of
-- Tests/fakenet.lua (clock, timers, delay, loss, members that go offline).
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")

T.loadLibraries()
---A value that stands for a secret one
local SECRET = {}
_G.issecretvalue = function(value)
  return value == SECRET
end

local ns = T.loadAll({ "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncProtocol.lua",
  "Addon/Src/Sync/SyncComm.lua" })
local comm, protocol = ns.syncComm, ns.syncProtocol
local codec = protocol.new(dofile("Tests/fixtures/stub_serializer.lua"))
local random = T.newRandom()

local VERSIONS = { debug = "!!!!!aB3$!!~^~~~" }
-- A whisper type for this test; the real ones come with the pull (plan stage 5)
protocol.CHANNELS.X = "WHISPER"

---Joins a member to the network and gives it a transport that records what it hands on.
---@return table member { endpoint, transport, got = messages handed to the session code, notices }
local function join(net, name, guild)
  local member = { got = {}, notices = {} }
  member.endpoint = net:Join(name)
  member.transport = comm.new({
    codec = codec,
    guild = guild or net.guild,
    playerName = function()
      return name
    end,
    notify = function(text)
      member.notices[#member.notices + 1] = text
    end,
    sendRaw = function(...)
      member.endpoint:Send(...)
    end,
  })
  member.transport.onMessage = function(sender, messageType, fields)
    member.got[#member.got + 1] = { sender = sender, type = messageType, fields = fields, time = net:Now() }
  end
  member.endpoint.receive = function(text, distribution, sender)
    member.transport:Receive(text, distribution, sender)
  end
  member.transport:SetActive(true)
  return member
end

-- Two replicas exchange one message
do
  local net = Fakenet.new({ random = random })
  local a, b = join(net, "Nota Scam"), join(net, "Other One")
  local progress = {}
  T.eq({ a.transport:Send("H", nil, "NORMAL", function(sent, total)
    progress[#progress + 1] = sent .. "/" .. total
  end, VERSIONS) }, { true }, "a send in the guild is queued")
  T.eq(#b.got, 0, "nothing arrives before the clock moves")
  net:Advance(1)
  T.eq(progress, { #net.log[1].text .. "/" .. #net.log[1].text },
    "the progress callback is called when the text has left")
  T.eq(#b.got, 1, "the other replica gets the message")
  T.eq(b.got[1].sender, "Nota Scam", "with the sender")
  T.eq(b.got[1].type, "H", "with the type")
  T.eq(b.got[1].fields, VERSIONS, "and with the fields")
  T.eq(#a.got, 0, "the sender does not get its own guild message")
  T.eq(a.transport.drops.own, 1, "the copy that came back was dropped as its own")
  T.eq(net.log[1].distribution, "GUILD", "a hello goes out on GUILD")
end

-- The sender filter
do
  local net = Fakenet.new({ random = random })
  local b = join(net, "Other One")
  net:Join("Nota Scam")
  local hello = codec.encode("H", VERSIONS)
  local transport = b.transport

  transport:Receive(hello, "GUILD", "Nota Scam")
  T.eq(#b.got, 1, "a message of a roster member passes")
  transport:Receive(hello, "GUILD", "Nota Scam-CAMWOW EU4")
  T.eq(#b.got, 2, "a realm suffix is cut off the sender")
  T.eq(b.got[2].sender, "Nota Scam", "and the session code gets the plain name")

  transport:Receive(hello, "GUILD", "Other One")
  T.eq(transport.drops.own, 1, "a message from the own name is dropped")
  transport:Receive(hello, "GUILD", "Stranger")
  T.eq(transport.drops.stranger, 1, "a message from a name outside the roster is dropped")
  transport:Receive(hello, "WHISPER", "Nota Scam")
  T.eq(transport.drops.channel, 1, "a guild type that arrives as a whisper is dropped")
  transport:Receive(codec.encode("X"), "GUILD", "Nota Scam")
  T.eq(transport.drops.invalid, 1, "a type without checks is dropped as invalid")
  transport:Receive(hello, "RAID", "Nota Scam")
  T.eq(transport.drops.channel, 2, "another channel is dropped")
  transport:Receive("not a message", "GUILD", "Nota Scam")
  T.eq(transport.drops.invalid, 2, "text that is not a message is dropped")
  for _, arguments in ipairs({ { SECRET, "GUILD", "Nota Scam" }, { hello, SECRET, "Nota Scam" },
    { hello, "GUILD", SECRET } }) do
    transport:Receive(arguments[1], arguments[2], arguments[3])
  end
  T.eq(transport.drops.secret, 3, "a secret text, channel, or sender is dropped")
  transport:Receive(hello, "GUILD", 5)
  T.eq(transport.drops.sender, 1, "a sender that is not a string is dropped")
  T.eq(#b.got, 2, "none of the dropped messages reached the session code")

  -- A newer protocol version: one notice per session
  local newer = dofile("Tests/fixtures/stub_serializer.lua"):Serialize(protocol.VERSION + 1, "H", VERSIONS)
  transport:Receive(newer, "GUILD", "Nota Scam")
  transport:Receive(newer, "GUILD", "Nota Scam")
  T.eq(transport.drops.newer, 2, "messages of a newer version are dropped")
  T.eq(#b.notices, 1, "the user is told once")
  transport:Receive(newer, "GUILD", "Stranger")
  T.eq(transport.drops.newer, 2, "a newer version from a stranger is dropped as a stranger")

  -- Off: outside the guild
  transport:SetActive(false)
  transport:Receive(hello, "GUILD", "Nota Scam")
  T.eq(transport.drops.inactive, 1, "an inactive transport drops what arrives")
  T.eq({ transport:Send("H", nil, "NORMAL", nil, VERSIONS) }, { false, "not in the guild" },
    "an inactive transport sends nothing")
  T.eq(net:Count(), 0, "nothing went to the network")
  T.eq(#b.got, 2, "and nothing reached the session code")
end

-- Listening follows the active state
do
  local listening = {}
  local transport = comm.new({
    codec = codec,
    guild = {},
    playerName = function() end,
    notify = function() end,
    sendRaw = function() end,
    setListening = function(value)
      listening[#listening + 1] = value
    end,
  })
  transport:SetActive(true)
  transport:SetActive(true)
  transport:SetActive(false)
  T.eq(listening, { true, false }, "listening is switched once per change")
end

-- A stale roster: a message from a member that the cache shows offline
do
  local noted = {}
  local guild = {
    GetMember = function(_, name)
      return name == "Nota Scam" and { online = false, rankIndex = 5 } or nil
    end,
    IsOnline = function()
      return false
    end,
    NoteOnline = function(_, name)
      noted[#noted + 1] = name
    end,
  }
  local net = Fakenet.new({ random = random })
  local b = join(net, "Other One", guild)
  b.transport:Receive(codec.encode("H", VERSIONS), "GUILD", "Nota Scam")
  T.eq(#b.got, 1, "the message of a member shown offline passes")
  T.eq(noted, { "Nota Scam" }, "and the guild state is told that the member is online")
end

-- Whispers
do
  local net = Fakenet.new({ random = random })
  local a, b = join(net, "Nota Scam"), join(net, "Other One")
  local c = join(net, "Third One")
  local received = {}
  for _, member in ipairs({ a, b, c }) do
    member.endpoint.receive = function(text, distribution, sender)
      received[#received + 1] = member.endpoint.name .. " " .. distribution .. " " .. sender .. " " .. text
    end
  end
  T.eq({ a.transport:Send("X", "Other One", "BULK", nil) }, { true }, "a whisper to an online member is queued")
  net:Advance(1)
  T.eq(received, { "Other One WHISPER Nota Scam " .. codec.encode("X") }, "only the target gets the whisper")
  T.eq({ a.transport:Send("X", "Nota Scam", "BULK", nil) }, { false, "target is the own character" },
    "a whisper to the own character is refused")
  T.eq({ a.transport:Send("X", nil, "BULK", nil) }, { false, "target is not online" },
    "a whisper without a target is refused")
  T.eq({ a.transport:Send("X", "Stranger", "BULK", nil) }, { false, "target is not online" },
    "a whisper to a name outside the roster is refused")
  net:SetOnline("Other One", false)
  T.eq({ a.transport:Send("X", "Other One", "BULK", nil) }, { false, "target is not online" },
    "a whisper to an offline member is refused")
  T.eq({ a.transport:Send("Z", nil, "BULK", nil) }, { false, "unknown type" }, "an unknown type is refused")
  T.eq(net:Count(), 1, "the refused sends did not reach the network")
end

-- The send queue of a member: texts leave in order, at the send rate
do
  local net = Fakenet.new({ random = random, sendRate = 100, minDelay = 0, maxDelay = 0 })
  local a, b = net:Join("Nota Scam"), net:Join("Other One")
  local arrived, left = {}, {}
  b.receive = function(text)
    arrived[#arrived + 1] = #text .. "@" .. (net:Now() - 1795000000)
  end
  local function note(sent)
    left[#left + 1] = sent .. "@" .. (net:Now() - 1795000000)
  end
  a:Send(string.rep("x", 200), "WHISPER", "Other One", "BULK", note)
  a:Send(string.rep("y", 100), "WHISPER", "Other One", "BULK", note)
  net:Advance(1.9)
  T.eq(arrived, {}, "a text of 200 bytes has not left after 1.9 seconds at 100 bytes per second")
  net:Advance(0.2)
  T.eq(arrived, { "200@2.0" }, "it arrives after 2 seconds")
  net:Advance(10)
  T.eq(arrived, { "200@2.0", "100@3.0" }, "the second text leaves after the first")
  T.eq(left, { "200@2.0", "100@3.0" }, "the progress callback follows the queue")
  a:Send(string.rep("z", 100), "WHISPER", "Other One", "BULK", note)
  net:SetOnline("Nota Scam", false)
  net:Advance(10)
  T.eq(#arrived, 2, "a text in the queue of a member that goes offline is not sent")
  T.eq(#left, 2, "and its progress callback is not called")

  -- A drop rule of the test
  net:SetOnline("Nota Scam", true)
  net.dropIf = function(entry, to)
    return to == "Other One" and entry.text:sub(1, 1) == "q"
  end
  a:Send("q lost", "WHISPER", "Other One")
  a:Send("r kept", "WHISPER", "Other One")
  net:Advance(10)
  T.eq(#arrived, 3, "the drop rule loses the messages that it names")
end

-- The fake timer
do
  local net = Fakenet.new({ random = random, start = 1000 })
  local fired = {}
  local function note(label)
    return function()
      fired[#fired + 1] = label .. "@" .. net:Now()
    end
  end
  net:After(5, note("five"))
  net:After(2, note("two"))
  local cancelled = net:After(3, note("three"))
  net:After(2, note("two again"))
  net:After(2, function()
    -- A timer made by a timer fires in the same Advance when it is due
    net:After(1, note("nested"))
  end)
  cancelled:Cancel()
  net:Advance(1)
  T.eq(fired, {}, "nothing fires before its time")
  T.eq(net:Now(), 1001, "the clock moves by the given seconds")
  net:Advance(3)
  T.eq(fired, { "two@1002", "two again@1002", "nested@1003" },
    "timers fire in time order, at their own time, and a cancelled one does not fire")
  net:Advance(10)
  T.eq(fired[4], "five@1005", "a later timer fires in a later Advance")
  T.eq(net:Now(), 1014, "the clock ends at the limit")
  net:Advance(100)
  T.eq(#fired, 4, "each timer fires once")
end

-- Delay, loss, and offline members
do
  local net = Fakenet.new({ random = random, minDelay = 2, maxDelay = 3 })
  local a, b = join(net, "Nota Scam"), join(net, "Other One")
  a.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  net:Advance(1.9)
  T.eq(#b.got, 0, "a delayed message has not arrived before the shortest delay")
  net:Advance(1.2)
  T.eq(#b.got, 1, "it arrives within the longest delay")
  T.ok(b.got[1].time - net.log[1].time >= 2 and b.got[1].time - net.log[1].time <= 3,
    "the travel time is between the two limits")

  net.loss = 1
  a.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  net:Advance(10)
  T.eq(#b.got, 1, "a lost message does not reach the handler")
  T.eq(net:Count(), 2, "the lost message is in the log")
  net.loss = 0

  -- Offline at the time of arrival
  a.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  net:SetOnline("Other One", false)
  net:Advance(10)
  T.eq(#b.got, 1, "a member that went offline gets nothing")
  T.eq(net.guild:IsOnline("Other One"), false, "the roster shows the member offline")
  b.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  T.eq(net:Count(), 3, "an offline member sends nothing")

  -- Roster notices and timers of a member
  local notices, ticks = 0, 0
  a.endpoint.onRosterChanged = function()
    notices = notices + 1
  end
  b.endpoint:After(5, function()
    ticks = ticks + 1
  end)
  net:Advance(10)
  T.eq(ticks, 0, "a timer of an offline member does not fire")
  net:SetOnline("Other One", true)
  T.eq(notices, 1, "the others are told when a member comes online")
  b.endpoint:After(5, function()
    ticks = ticks + 1
  end)
  net:Advance(10)
  T.eq(ticks, 1, "a timer of an online member fires")
  net:Leave("Other One")
  T.eq(notices, 2, "the others are told when a member leaves")
  T.eq(net.guild:GetMember("Other One"), nil, "a member who left is not in the roster")
  a.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  net:Advance(10)
  T.eq(#b.got, 1, "a member who left gets nothing")

  -- With 50% loss some of 200 messages arrive and some do not
  local c = join(net, "Third One")
  net.loss = 0.5
  for _ = 1, 200 do
    a.transport:Send("H", nil, "NORMAL", nil, VERSIONS)
  end
  net:Advance(10)
  T.ok(#c.got > 50 and #c.got < 150, "half of the messages are lost, more or less")
end

T.finish()
