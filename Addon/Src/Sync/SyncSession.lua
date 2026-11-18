local addonName, ns = ...

-- The session of the shared database: what a replica does while the character is online. This stage holds
-- discovery (.agents/00-plan.md, section 7.1): the hello after login, the answers to the hellos of others,
-- and the list of peers. The pull is in SyncPull.lua, which adds its methods and message handlers to the
-- session of this file. The push is in SyncPush.lua, in the same way.
--
-- `session.new` builds a session from parts that are passed in, so the host tests run many of them over a
-- fake network (Tests/sync_discovery.lua). `session.Start` builds the one of the game. Nothing at file scope
-- uses the WoW API.

---@class OOOOSyncTimer What `after` returns; `C_Timer.NewTimer` gives this form
---@field Cancel fun(self: OOOOSyncTimer)

---@class OOOOSyncSessionParts What `session.new` is built from
---@field transport OOOOSyncTransport
---@field guild OOOOSyncGuildView
---@field sync OOOOSync The table registry, `ns.sync`
---@field now fun(): number Server time in seconds
---@field after fun(seconds: number, fn: fun()): OOOOSyncTimer Calls `fn` once, later
---@field random fun(): number Like math.random(): from 0 up to, not including, 1
---@field playerName fun(): string|nil Name of the logged-in character, as the roster shows it
---@field policy OOOOSyncPolicyView Tells what may send now (SyncPolicy.lua)

---@class OOOOSyncPeer An online guild member whose addon has announced itself
---@field name string Character name
---@field versions table<string, string> Table name -> the table version that the peer announced last
---@field lastSeen number Server time of the last message
---@field order integer Arrival order: 1 for the first peer of this session
---@field retryAt table<string, number>|nil Table name -> server time before which the peer is not asked for it

---@class OOOOSyncSession
---@field parts OOOOSyncSessionParts
---@field peers table<string, OOOOSyncPeer> Character name -> peer
---@field peerCount integer Number of peers that were ever added; gives `order`
---@field helloTimer OOOOSyncTimer|nil Runs until the hello is sent
---@field helloSent boolean true once the hello of this stay in the guild was sent
---@field helloHeld boolean true while the hello waits for the conditions to allow it
---@field collectTimer OOOOSyncTimer|nil Runs while the answers to the hello are collected
---@field discovered boolean true once the answers to the hello were collected
---@field answerTimer OOOOSyncTimer|nil Runs until the summary is sent
---@field answerTables table<string, boolean>|nil Set of table names that the pending summary will carry
---@field serving OOOOSyncServing|nil The pull that this replica answers (SyncPull.lua)
---@field pull OOOOSyncActivePull|nil The pull that this replica runs (SyncPull.lua)
---@field merged table<string, table<string, boolean>> Table name -> set of table versions whose data this
---replica holds already, from complete pulls of this session
---@field retryTimer OOOOSyncTimer|nil Runs until a peer that has to wait can be asked again
---@field pushTimers table<string, OOOOSyncTimer> Table name -> timer that runs until the table is pushed
---@field lastPushAt table<string, number> Table name -> server time of the last push of local changes
---@field delayedPullTimer OOOOSyncTimer|nil Runs until the pull that a differing version has asked for
---@field summaryTimer OOOOSyncTimer|nil Runs until the next periodic summary
---@field heardOwn table<string, string> Table name -> the own version, when a peer has announced it since the
---last periodic summary
---@field announced table<string, string> Table name -> the version that this replica has told the guild last
local Session = {}
Session.__index = Session

---@class OOOOSyncSessionModule
---@field current OOOOSyncSession|nil The session of the game; nil until `Start`
local session = {}
ns.syncSession = session

---The class of a session; SyncPull.lua adds the methods of the pull to it
session.Session = Session

local store = ns.syncStore

---Seconds between entering the guild state "in" and the hello: a random value in this range, so that the
---members who log in after a server restart do not all send at once
session.HELLO_DELAY_MIN, session.HELLO_DELAY_MAX = 20, 40
---Seconds between a hello of another member and the answer: a random value in this range. A peer that
---hears the same answer from another peer in that time stays silent.
session.ANSWER_DELAY_MIN, session.ANSWER_DELAY_MAX = 1, 8
---Seconds for which the answers to the own hello are collected, from the moment at which it has left
session.COLLECT_SECONDS = 10
---Seconds after which the collecting starts also when the send queue has not reported the hello as sent
session.HELLO_SEND_LIMIT = 60

---Makes a session. It does nothing until `OnGuildStateChanged(true)`.
---@param parts OOOOSyncSessionParts
---@return OOOOSyncSession
function session.new(parts)
  local self = setmetatable({
    parts = parts,
    peers = {},
    peerCount = 0,
    helloSent = false,
    helloHeld = false,
    discovered = false,
    merged = {},
    pushTimers = {},
    lastPushAt = {},
    heardOwn = {},
    announced = {},
  }, Session)
  -- A local write starts the push timer of its table (SyncPush.lua)
  parts.sync.RegisterCallback(self, "OnRecordChanged", function(_event, tableName, _key, _payload, isRemote)
    if not isRemote then
      self:SchedulePush(tableName)
    end
  end)
  parts.transport.onMessage = function(sender, messageType, fields)
    self:OnMessage(sender, messageType, fields)
  end
  return self
end

---Stops a timer when it runs.
---@param timer OOOOSyncTimer|nil
local function cancel(timer)
  if timer then
    timer:Cancel()
  end
end

---Gives a random number of seconds in a range, with a fraction.
---@param low number
---@param high number
---@return number
function Session:RandomDelay(low, high)
  return low + self.parts.random() * (high - low)
end

---Tells whether this replica may send the messages that belong to no table, hello and summary: not in
---combat.
---@return boolean
function Session:MaySend()
  return self.parts.policy:MayTalk()
end

---Tells whether a table may send its records, or ask for records, now: its policy and the conditions.
---@param tableName string
---@return boolean
function Session:MayTransfer(tableName)
  return self.parts.policy:MaySend(tableName)
end

---Returns the table version of every table that takes part in the exchange: what a hello carries.
---A table that the user has turned off is left out, so nobody answers for it.
---@return table<string, string> versions Table name -> table version; empty while the database is not ready
function Session:LocalVersions()
  local sync, versions = self.parts.sync, {}
  for _, name in ipairs(sync.names) do
    local tbl = sync:GetTable(name)
    if tbl and self.parts.policy:IsEnabled(name) then
      versions[name] = store.tableVersion(tbl)
    end
  end
  return versions
end

---Sends table versions to the guild in a message of the given type, hello or summary, and remembers
---them as announced.
---@param messageType "H"|"S"
---@param versions table<string, string>
---@param onProgress (fun(sent: integer, total: integer))|nil
---@return boolean queued
function Session:Announce(messageType, versions, onProgress)
  if not self.parts.transport:Send(messageType, nil, "NORMAL", onProgress, versions) then
    return false
  end
  for name, version in pairs(versions) do
    self.announced[name] = version
  end
  return true
end

---Follows the conditions of the game: what was held back while they forbade sending goes on.
function Session:OnConditionsChanged()
  if self.helloHeld then
    self:SendHello()
  end
  self:PumpPulls()
  self:SchedulePushes()
end

---Follows the guild state: inside the guild the hello timer starts, outside it everything stops.
---@param inGuild boolean
function Session:OnGuildStateChanged(inGuild)
  if not inGuild then
    self:Stop()
    return
  end
  if self.helloSent or self.helloTimer then
    return
  end
  self.helloTimer = self.parts.after(self:RandomDelay(session.HELLO_DELAY_MIN, session.HELLO_DELAY_MAX), function()
    self.helloTimer = nil
    self:SendHello()
  end)
end

---Stops all timers and forgets the peers.
function Session:Stop()
  cancel(self.helloTimer)
  cancel(self.collectTimer)
  cancel(self.answerTimer)
  self.helloTimer, self.collectTimer, self.answerTimer, self.answerTables = nil, nil, nil, nil
  self.helloSent, self.helloHeld, self.discovered = false, false, false
  self.peers = {}
  self:StopPull()
  self:StopPush()
end

---Sends the hello with the versions of all tables and starts collecting the answers. While the conditions
---forbid sending, the hello is held and goes out with `OnConditionsChanged`.
function Session:SendHello()
  if self.helloSent then
    return
  end
  self.helloHeld = not self:MaySend()
  if self.helloHeld then
    return
  end
  local function done()
    self.collectTimer = nil
    self:OnDiscoveryDone()
  end
  -- The answers are collected from the moment at which the hello has left the send queue: after a login the
  -- queue can hold it back for some seconds. The first timer covers a queue that never reports.
  local timer = self.parts.after(session.HELLO_SEND_LIMIT + session.COLLECT_SECONDS, done)
  self.collectTimer = timer
  local queued = self:Announce("H", self:LocalVersions(), function(sent, total)
    if sent >= total and self.collectTimer == timer then
      timer:Cancel()
      self.collectTimer = self.parts.after(session.COLLECT_SECONDS, done)
    end
  end)
  if not queued then
    timer:Cancel()
    self.collectTimer = nil
    return
  end
  self.helloSent = true
end

---Called when the answers to the own hello have been collected. The peers that differ are then known.
function Session:OnDiscoveryDone()
  self.discovered = true
  self:PumpPulls()
  self:MarkUnpushed()
  self:ScheduleSummary()
end

---Adds the sender to the peer list, or renews its entry.
---@param sender string
---@param versions table<string, string> The versions of the message
---@param isComplete boolean true when the message lists all tables of the sender (a hello)
---@return OOOOSyncPeer
function Session:TouchPeer(sender, versions, isComplete)
  local peer = self.peers[sender]
  if not peer then
    self.peerCount = self.peerCount + 1
    peer = { name = sender, versions = {}, lastSeen = 0, order = self.peerCount }
    self.peers[sender] = peer
  end
  peer.lastSeen = self.parts.now()
  if isComplete then
    peer.versions = versions
  else
    for name, version in pairs(versions) do
      peer.versions[name] = version
    end
  end
  return peer
end

---Takes out of the pending answer the tables for which a peer has just announced the version that this
---replica has: the member who asked has then heard it already.
---@param versions table<string, string> Versions that a peer announced
---@param own table<string, string> Versions of this replica
function Session:SuppressAnswer(versions, own)
  local tables = self.answerTables
  if not tables then
    return
  end
  for name in pairs(tables) do
    if versions[name] == own[name] then
      tables[name] = nil
    end
  end
  if next(tables) == nil then
    cancel(self.answerTimer)
    self.answerTimer, self.answerTables = nil, nil
  end
end

---Sends the pending summary: the current versions of the tables that are still in it.
function Session:SendAnswer()
  local tables = self.answerTables
  self.answerTimer, self.answerTables = nil, nil
  if not tables or not self:MaySend() then
    return
  end
  local own, answer = self:LocalVersions(), {}
  for name in pairs(tables) do
    answer[name] = own[name]
  end
  if next(answer) ~= nil then
    self:Announce("S", answer)
  end
end

---Message type -> handler. `fields` were checked by SyncProtocol.lua. SyncPull.lua adds the pull types.
---@type table<string, fun(self: OOOOSyncSession, sender: string, fields: any)>
local handlers = {}
session.handlers = handlers

---Hello: the sender asks who has other versions. The answer waits a random time and lists the tables that
---differ, without those that another peer announces meanwhile with the version of this replica.
---@param self OOOOSyncSession
---@param sender string
---@param versions table<string, string>
function handlers.H(self, sender, versions)
  local own = self:LocalVersions()
  self:NoteVersions(sender, versions, true)
  local tables = self.answerTables
  for name, version in pairs(own) do
    -- A table that the sender does not list is one that its addon version does not have
    if versions[name] and versions[name] ~= version then
      tables = tables or {}
      tables[name] = true
    end
  end
  if tables and not self.answerTimer then
    self.answerTables = tables
    self.answerTimer = self.parts.after(self:RandomDelay(session.ANSWER_DELAY_MIN, session.ANSWER_DELAY_MAX),
      function()
        self:SendAnswer()
      end)
  end
end

---Summary: the sender announces the versions of some of its tables.
---@param self OOOOSyncSession
---@param sender string
---@param versions table<string, string>
function handlers.S(self, sender, versions)
  self:NoteVersions(sender, versions, false)
end

---Takes a checked message from the transport.
---@param sender string Character name of a roster member, never the own one
---@param messageType string
---@param fields any
function Session:OnMessage(sender, messageType, fields)
  local handler = handlers[messageType]
  if handler then
    handler(self, sender, fields)
  end
end

---Drops the peers that the roster no longer shows online.
function Session:OnRosterChanged()
  for name in pairs(self.peers) do
    if not self.parts.guild:IsOnline(name) then
      self.peers[name] = nil
    end
  end
  self:OnPullRosterChanged()
end

---Returns the peers in the order in which they arrived.
---@return OOOOSyncPeer[]
function Session:PeerList()
  local list = {}
  for _, peer in pairs(self.peers) do
    list[#list + 1] = peer
  end
  table.sort(list, function(a, b)
    return a.order < b.order
  end)
  return list
end

---Lists the tables for which a peer has announced another version than this replica has.
---@param peer OOOOSyncPeer
---@return string[] names Sorted
function Session:DifferingTables(peer)
  local own, names = self:LocalVersions(), {}
  for name, version in pairs(peer.versions) do
    if own[name] and own[name] ~= version then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---Tells in a word whether a table may send now, for `/oooo sync status`.
---@param tableName string
---@return string state "yes", "off" (turned off by the user), or "no" with the condition that is not met
function Session:SendState(tableName)
  local effective = self.parts.policy:Get(tableName)
  if not effective or not effective.enabled then
    return "off"
  end
  return self:MayTransfer(tableName) and "yes" or ("no, needs " .. effective.when)
end

---Builds the lines about discovery and the peers for `/oooo sync status`.
---@return string[] lines Plain text; the caller escapes it for chat
function Session:StatusLines()
  local state
  if self.discovered then
    state = "done"
  elseif self.helloSent then
    state = "collecting answers"
  elseif self.helloHeld then
    state = "the hello waits until the fight is over"
  elseif self.helloTimer then
    state = "waiting to send the hello"
  else
    state = "not started (not in the guild)"
  end
  local peers = self:PeerList()
  local lines = { "discovery: " .. state, "peers: " .. #peers }
  local now = self.parts.now()
  for _, peer in ipairs(peers) do
    local differing = self:DifferingTables(peer)
    lines[#lines + 1] = "  " .. peer.name .. ": last message " .. math.floor(now - peer.lastSeen) .. " s ago, "
      .. (#differing > 0 and ("differs in " .. table.concat(differing, ", ")) or "no known difference")
  end
  for _, line in ipairs(self:PullStatusLines()) do
    lines[#lines + 1] = line
  end
  return lines
end

---Builds the session of the game on the transport of SyncComm.lua and ties it to the guild state.
---Core.lua calls it on PLAYER_LOGIN, after `ns.syncComm.Start` and before the guild state starts.
---@return OOOOSyncSession
function session.Start()
  if session.current then
    return session.current
  end
  local current = session.new({
    transport = ns.syncComm.Start(),
    guild = ns.guildState,
    sync = ns.sync,
    now = GetServerTime,
    after = C_Timer.NewTimer,
    random = math.random,
    playerName = ns.syncCharacter.playerName,
    policy = ns.syncPolicy.new({
      sync = ns.sync,
      overrides = function()
        return ns.db.profile.sync.tables
      end,
      state = function()
        return ns.syncPolicy.state
      end,
    }),
  })
  session.current = current
  ns.guildState.RegisterCallback(session, "OnGuildStateChanged", function(_event, inGuild)
    current:OnGuildStateChanged(inGuild)
  end)
  ns.guildState.RegisterCallback(session, "OnRosterChanged", function()
    current:OnRosterChanged()
  end)
  ns.syncPolicy.RegisterCallback(session, "OnConditionsChanged", function()
    current:OnConditionsChanged()
  end)
  ns.syncPolicy.Start()
  return current
end
