local addonName, ns = ...

-- The transport of the shared database: it sends the messages of SyncProtocol.lua and hands the received
-- ones, after the sender checks, to the session code (.agents/00-plan.md, section 6 and step 4.3).
--
-- `comm.new` builds a transport from parts that are passed in, so the host tests run it over a fake network
-- (Tests/fakenet.lua). `comm.Start` builds the one of the game on AceComm-3.0. Nothing at file scope uses
-- the WoW API.

---@class OOOOSyncGuildView What the transport asks about the guild; `ns.guildState` has this form
---@field GetMember fun(self: any, name: string): OOOOGuildMember|nil
---@field IsOnline fun(self: any, name: string): boolean
---@field NoteOnline fun(self: any, name: string)
---@field IsRosterComplete fun(self: any): boolean true when a missing name means a member who left
---@field IsOfficer fun(self: any, name: string|nil): boolean true for a character with an officer rank

---@alias OOOOSyncPriority "NORMAL"|"BULK"|"ALERT" Priority of ChatThrottleLib

---@class OOOOSyncCommParts What `comm.new` is built from
---@field codec OOOOSyncCodec
---@field guild OOOOSyncGuildView
---@field playerName fun(): string|nil Name of the logged-in character, as a sender shows it
---@field sendRaw fun(text: string, distribution: string, target: string|nil, priority: OOOOSyncPriority, onProgress: (fun(sent: integer, total: integer))|nil)
---@field setListening (fun(listening: boolean))|nil Starts and stops the delivery of received text
---@field notify fun(text: string) Prints one line for the user

---@class OOOOSyncTransport The interface between the network and the session code
---@field active boolean true while the character is in the guild; an inactive transport sends and takes nothing
---@field onMessage (fun(sender: string, messageType: string, fields: any))|nil Set by the session code
---@field drops table<string, integer> Reason -> number of received messages that were dropped for it
---@field Send fun(self: OOOOSyncTransport, messageType: string, target: string|nil, priority: OOOOSyncPriority, onProgress: (fun(sent: integer, total: integer))|nil, ...: any): boolean, string|nil
---@field Receive fun(self: OOOOSyncTransport, text: any, distribution: any, sender: any)
---@field SetActive fun(self: OOOOSyncTransport, active: boolean)

---@class OOOOSyncComm
---@field transport OOOOSyncTransport|nil The transport of the game; nil until `Start`
local comm = {}
ns.syncComm = comm

local protocol = ns.syncProtocol
local guildState = ns.guildState

---The one addon message prefix of the shared database
comm.PREFIX = "OOOO"
---Seconds after a whisper for which the "no player named" line of its target is hidden
comm.OFFLINE_NOTICE_SECONDS = 10
---The line that the client prints after a whisper to an offline name, when the client has no global for it
local OFFLINE_NOTICE_FORMAT = "No player named '%s' is currently playing."

---Reads the name out of the system line that the client prints after a whisper to an offline player.
---@param message string The system line
---@param format string The format of the line with one `%s`, as in `ERR_CHAT_PLAYER_NOT_FOUND_S`
---@return string|nil name nil when the line is another one
function comm.offlineNoticeName(message, format)
  -- Every magic character of the format is escaped; the escaped `%s` then becomes the capture
  local pattern = "^" .. format:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
  return message:match(pattern)
end

---Makes a transport.
---@param parts OOOOSyncCommParts
---@return OOOOSyncTransport
function comm.new(parts)
  local codec, guild = parts.codec, parts.guild
  ---@type OOOOSyncTransport
  ---@diagnostic disable-next-line: missing-fields
  local transport = { active = false, drops = {} }
  ---true once the user was told that a member has a newer addon version
  local toldNewer = false

  ---Counts a received message that is not handed on.
  ---@param reason string
  local function drop(reason)
    transport.drops[reason] = (transport.drops[reason] or 0) + 1
  end

  ---Turns the transport on or off. Off: nothing is sent, and what arrives is dropped.
  ---@param active boolean
  function transport:SetActive(active)
    if active == self.active then
      return
    end
    self.active = active
    if parts.setListening then
      parts.setListening(active)
    end
  end

  ---Sends a message on the channel of its type. The call returns at once; the text leaves through the send
  ---queue, which keeps to the limits of the server.
  ---@param messageType string A key of `protocol.CHANNELS`
  ---@param target string|nil Receiver of a whisper type; ignored for a guild type
  ---@param priority OOOOSyncPriority
  ---@param onProgress (fun(sent: integer, total: integer))|nil Called as parts of the text leave the queue
  ---@param ... any Fields of the type
  ---@return boolean queued false when nothing was sent
  ---@return string|nil reason Why nothing was sent
  function transport:Send(messageType, target, priority, onProgress, ...)
    if not self.active then
      return false, "not in the guild"
    end
    local distribution = protocol.CHANNELS[messageType]
    if not distribution then
      return false, "unknown type"
    end
    if distribution == "WHISPER" then
      -- A whisper to an offline name prints a system line in the chat frame of the sender (AGENTS.md)
      if type(target) ~= "string" or not guild:IsOnline(target) then
        return false, "target is not online"
      end
      if target == parts.playerName() then
        return false, "target is the own character"
      end
    else
      target = nil
    end
    parts.sendRaw(codec.encode(messageType, ...), distribution, target, priority, onProgress)
    return true
  end

  ---Takes a received text, checks the sender and the message, and calls `onMessage`.
  ---Every argument comes from another client or can be secret.
  ---@param text any
  ---@param distribution any "GUILD" or "WHISPER"
  ---@param sender any Character name of the sender
  function transport:Receive(text, distribution, sender)
    if not self.active then
      return drop("inactive")
    end
    if issecretvalue(text) or issecretvalue(distribution) or issecretvalue(sender) then
      return drop("secret")
    end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then
      return drop("channel")
    end
    local name = guildState.normalizeName(sender)
    if not name then
      return drop("sender")
    end
    -- A guild message also comes back to its sender
    if name == parts.playerName() then
      return drop("own")
    end
    local member = guild:GetMember(name)
    if not member then
      return drop("stranger")
    end
    local messageType, fields = codec.decode(text)
    if not messageType then
      if fields == protocol.NEWER and not toldNewer then
        toldNewer = true
        parts.notify("A guild member has a newer version of the addon. Update it to keep the shared data in step.")
      end
      return drop(fields == protocol.NEWER and "newer" or "invalid")
    end
    if protocol.CHANNELS[messageType] ~= distribution then
      return drop("channel")
    end
    if not member.online then
      guild:NoteOnline(name)
    end
    if self.onMessage then
      self.onMessage(name, messageType, fields)
    end
  end

  return transport
end

---Builds the transport of the game on AceComm-3.0 and AceSerializer-3.0 and ties it to the guild state:
---the prefix is registered when the character is in the guild, and the handler is removed outside it.
---SyncSession.lua calls it on PLAYER_LOGIN, before the guild state starts.
---@return OOOOSyncTransport
function comm.Start()
  if comm.transport then
    return comm.transport
  end
  local aceComm = LibStub("AceComm-3.0")
  ---Owner of the AceComm registration
  local receiver = aceComm:Embed({})
  ---Target of an addon whisper -> clock time (`GetTime`) at which the last part of a whisper left
  local whisperedAt = {}
  local transport
  transport = comm.new({
    codec = protocol.new(LibStub("AceSerializer-3.0")),
    guild = guildState,
    playerName = ns.syncCharacter.playerName,
    notify = ns.print,
    sendRaw = function(text, distribution, target, priority, onProgress)
      if distribution == "WHISPER" then
        whisperedAt[target] = GetTime()
      end
      -- AceComm cuts a long text into parts of 255 bytes, and ChatThrottleLib queues them
      receiver:SendCommMessage(comm.PREFIX, text, distribution, target, priority, function(_argument, sent, total)
        if distribution == "WHISPER" then
          whisperedAt[target] = GetTime()
        end
        if onProgress then
          onProgress(sent, total)
        end
      end)
    end,
    setListening = function(listening)
      if listening then
        -- This also registers the prefix with the client
        receiver:RegisterComm(comm.PREFIX, function(_prefix, text, distribution, sender)
          transport:Receive(text, distribution, sender)
        end)
      else
        receiver:UnregisterComm(comm.PREFIX)
      end
    end,
  })
  comm.transport = transport

  -- An addon whisper to a member who has just gone offline prints a system line (AGENTS.md). The transport
  -- whispers only to members that the roster shows online, but the roster can be behind.
  local format = type(_G.ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and _G.ERR_CHAT_PLAYER_NOT_FOUND_S
    or OFFLINE_NOTICE_FORMAT
  -- The filter functions moved into ChatFrameUtil in the Mainline UI; the old global is the fallback
  local addFilter = (_G.ChatFrameUtil and _G.ChatFrameUtil.AddMessageEventFilter) or _G.ChatFrame_AddMessageEventFilter
  if addFilter then
    addFilter("CHAT_MSG_SYSTEM", function(_chatFrame, _event, message)
      if issecretvalue(message) or type(message) ~= "string" then
        return false
      end
      local name = comm.offlineNoticeName(message, format)
      local at = name and whisperedAt[name]
      -- true hides the line
      return at ~= nil and GetTime() - at <= comm.OFFLINE_NOTICE_SECONDS
    end)
  end
  guildState.RegisterCallback(comm, "OnGuildStateChanged", function(_event, inGuild)
    transport:SetActive(inGuild)
  end)
  return transport
end
