-- Host test of the priority rule of Addon/Src/Sync/SyncComm.lua (a text of several parts always goes as
-- BULK), with the embedded AceComm-3.0 and ChatThrottleLib. Both load on the host with the few client
-- functions below. What leaves through `C_ChatInfo.SendAddonMessage` comes straight back as a
-- CHAT_MSG_ADDON event, so one AceComm is the sender and the receiver.
local T = dofile("Tests/harness.lua")

T.loadLibraries()

---Seconds of the client clock (`GetTime`)
local clock = 1000
---Frames that the libraries made, by name or by number
local frames = {}
---Every addon message that left, in order: { text, distribution }
local wire = {}
local PREFIX = "OOOO"
local SENDER = "Nota Scam"

_G.issecretvalue = function()
  return false
end
_G.GetTime = function()
  return clock
end
_G.GetFramerate = function()
  return 60
end
_G.unpack = _G.unpack or table.unpack
rawset(table, "wipe", rawget(table, "wipe") or function(t)
  for key in pairs(t) do
    t[key] = nil
  end
  return t
end)
_G.Enum = _G.Enum or {}
_G.geterrorhandler = function()
  return function(message)
    error(message, 0)
  end
end
_G.Ambiguate = function(name)
  return name
end
-- ChatThrottleLib hooks the send functions only to measure traffic that goes past it; there is none here
_G.hooksecurefunc = function() end
_G.CreateFrame = function(_frameType, name)
  local frame = { scripts = {} }
  function frame:SetScript(script, handler)
    self.scripts[script] = handler
  end
  function frame.Show() end
  function frame.Hide() end
  function frame.RegisterEvent() end
  function frame.UnregisterAllEvents() end
  frames[name or #frames + 1] = frame
  return frame
end
_G.C_ChatInfo = {
  RegisterAddonMessagePrefix = function()
    return true
  end,
  SendAddonMessage = function(prefix, text, distribution)
    wire[#wire + 1] = { text = text, distribution = distribution }
    local aceFrame = frames.AceComm30Frame
    aceFrame.scripts.OnEvent(aceFrame, "CHAT_MSG_ADDON", prefix, text, distribution, SENDER)
    return 0
  end,
  SendAddonMessageLogged = function()
    return 0
  end,
}

assert(loadfile("Addon/Ace3/AceComm-3.0/ChatThrottleLib.lua"))()
assert(loadfile("Addon/Ace3/AceComm-3.0/AceComm-3.0.lua"))()
local throttle = _G.ChatThrottleLib
local aceComm = _G.LibStub("AceComm-3.0")

local ns = T.loadAll({ "Addon/Src/Guild/GuildState.lua", "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua", "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncProtocol.lua",
  "Addon/Src/Sync/SyncComm.lua" })
local comm, protocol = ns.syncComm, ns.syncProtocol
local codec = protocol.new(dofile("Tests/fixtures/stub_serializer.lua"))

---Lets the client clock run, with the frame updates in which ChatThrottleLib sends from its queues.
---@param seconds number
local function advance(seconds)
  for _ = 1, math.floor(seconds * 10 + 0.5) do
    clock = clock + 0.1
    throttle.Frame.scripts.OnUpdate(throttle.Frame, 0.1)
  end
end

local guild = {
  GetMember = function()
    return { online = true, rankIndex = 5 }
  end,
  IsOnline = function()
    return true
  end,
  NoteOnline = function() end,
}

---Makes a transport on the AceComm of this test.
---@param name string Character name
---@param onMessage (fun(sender: string, messageType: string, fields: any))|nil Makes it listen
---@return table transport
---@return table priorities The priority of every text that the transport handed to AceComm, in order
local function newTransport(name, onMessage)
  local receiver = aceComm:Embed({})
  local priorities = {}
  local transport
  transport = comm.new({
    codec = codec,
    guild = guild,
    playerName = function()
      return name
    end,
    notify = function() end,
    sendRaw = function(text, distribution, target, priority)
      priorities[#priorities + 1] = priority
      receiver:SendCommMessage(PREFIX, text, distribution, target, priority)
    end,
    setListening = onMessage and function(listening)
      if listening then
        receiver:RegisterComm(PREFIX, function(_prefix, text, distribution, sender)
          transport:Receive(text, distribution, sender)
        end)
      else
        receiver:UnregisterComm(PREFIX)
      end
    end or nil,
  })
  transport.onMessage = onMessage
  transport:SetActive(true)
  return transport, priorities
end

---Tables in a hello of this test: two parts
local HELLO_TABLES = 12
---Tables in the long summary: so many parts that hellos leave meanwhile, whichever queue goes first
local SUMMARY_TABLES = 40

---Versions of a number of tables.
---@param label integer Tells the messages apart: it is in every table name
---@param tables integer
---@return table<string, string> versions
local function versionsOf(label, tables)
  local versions = {}
  for index = 1, tables do
    versions[("m%02dtable%02d"):format(label, index)] = "!!!!!aB3$!!~^~~~"
  end
  return versions
end

---What the listening transport handed on, in order: the type, the label, and the number of tables, or
---"mixed" for a message with tables of several labels
---@type string[]
local arrived = {}
local listener = newTransport("Other One", function(_sender, messageType, fields)
  local label, tables = nil, 0
  for name in pairs(fields) do
    local own = name:sub(2, 3)
    label = (label == nil or label == own) and own or "mixed"
    tables = tables + 1
  end
  arrived[#arrived + 1] = messageType .. tostring(label) .. "x" .. tables
end)
local sender, priorities = newTransport(SENDER, nil)

T.ok(#codec.encode("H", versionsOf(1, HELLO_TABLES)) > comm.SINGLE_PART_BYTES, "a hello of this test needs two parts")
T.ok(#codec.encode("S", versionsOf(1, SUMMARY_TABLES)) > 4 * comm.SINGLE_PART_BYTES,
  "the long summary needs five parts or more")
T.ok(#codec.encode("S", versionsOf(1, 1)) <= comm.SINGLE_PART_BYTES, "the short summary needs one part")

---Sends 18 hellos as BULK, which stand for pushes, and after the 14th one summary as NORMAL. The first
---hellos use up the burst of ChatThrottleLib, so the summary meets a queue.
---@param send fun(messageType: string, priority: string, versions: table<string, string>)
---@param summaryTables integer
---@return string[] expected What arrives when nothing is lost, in the order of the sends
local function exchange(send, summaryTables)
  -- Past the first seconds, in which ChatThrottleLib sends very little, and with empty queues
  advance(120)
  arrived, wire = {}, {}
  listener.drops.invalid = nil
  local expected = {}
  for label = 1, 18 do
    send("H", "BULK", versionsOf(label, HELLO_TABLES))
    expected[#expected + 1] = ("H%02dx%d"):format(label, HELLO_TABLES)
    if label == 14 then
      send("S", "NORMAL", versionsOf(99, summaryTables))
      expected[#expected + 1] = "S99x" .. summaryTables
    end
  end
  advance(120)
  return expected
end

-- The libraries alone, as the transport used them before the rule: the parts of the long summary leave
-- between the parts of the hellos, and messages are lost. Mixed parts can even give a text that passes
-- the checks, with tables of two messages. This is why the rule exists; should these checks fail after an
-- update of the libraries, AceComm keeps the texts apart and the rule can go.
do
  local raw = aceComm:Embed({})
  local expected = exchange(function(messageType, priority, versions)
    raw:SendCommMessage(PREFIX, codec.encode(messageType, versions), "GUILD", nil, priority)
  end, SUMMARY_TABLES)
  local intact, wanted = 0, {}
  for _, label in ipairs(expected) do
    wanted[label] = true
  end
  for _, label in ipairs(arrived) do
    intact = intact + (wanted[label] and 1 or 0)
  end
  T.ok(intact < #expected, "with two priorities, texts of several parts are lost")
end

-- Through the transport: the long summary goes as BULK, behind the hellos, and everything arrives
do
  local first = #priorities + 1
  local expected = exchange(function(messageType, priority, versions)
    sender:Send(messageType, nil, priority, nil, versions)
  end, SUMMARY_TABLES)
  T.eq(arrived, expected, "with the rule every text arrives, in the order of the sends")
  T.eq(listener.drops.invalid, nil, "and nothing arrives as a text that is no message")
  for index = first, #priorities do
    T.eq(priorities[index], "BULK", "every text of several parts was sent as BULK")
  end
end

-- A summary of one part keeps its priority: it passes the queue of the hellos and breaks none of them
do
  local first = #priorities + 1
  local expected = exchange(function(messageType, priority, versions)
    sender:Send(messageType, nil, priority, nil, versions)
  end, 1)
  -- The 15th send was the summary
  T.eq(priorities[first + 14], "NORMAL", "a text of one part keeps the priority of the caller")
  local position
  for index, label in ipairs(arrived) do
    position = label == "S99x1" and index or position
  end
  T.eq(#arrived, #expected, "every text arrives")
  T.ok(position and position < #arrived, "the short summary does not wait for the whole queue")
  T.eq(listener.drops.invalid, nil, "and nothing arrives as a text that is no message")
  table.sort(arrived)
  table.sort(expected)
  T.eq(arrived, expected, "each text arrives once")
end

-- The limit is the size of one addon message
do
  local sent = {}
  local transport = comm.new({
    codec = {
      encode = function(_messageType, length)
        return string.rep("x", length)
      end,
    },
    guild = guild,
    playerName = function()
      return SENDER
    end,
    notify = function() end,
    sendRaw = function(text, _distribution, _target, priority)
      sent[#sent + 1] = #text .. " " .. priority
    end,
  })
  transport:SetActive(true)
  for _, priority in ipairs({ "NORMAL", "ALERT", "BULK" }) do
    transport:Send("H", nil, priority, nil, 255)
    transport:Send("H", nil, priority, nil, 256)
  end
  T.eq(sent, { "255 NORMAL", "256 BULK", "255 ALERT", "256 BULK", "255 BULK", "256 BULK" },
    "a text of 255 bytes keeps its priority, and one of 256 bytes goes as BULK")
end

T.finish()
