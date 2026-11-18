-- Builds complete replicas of the shared database on a fake network (Tests/fakenet.lua) for the session
-- tests: each replica has its own namespace with the addon files loaded, its own stored database, a
-- transport, and a session.
--
-- Usage: local Replica = dofile("Tests/fixtures/replica.lua")(T)
--        local replica = Replica.new(net, "Nota Scam", { origin = "AAAA", random = random })

---The addon files of a replica, in load order
local FILES = {
  "Addon/Src/Slash.lua",
  "Addon/Src/Guild/GuildState.lua",
  "Addon/Src/Sync/Base94.lua",
  "Addon/Src/Sync/VersionId.lua",
  "Addon/Src/Sync/SyncStore.lua",
  "Addon/Src/Sync/SyncTables.lua",
  "Addon/Src/Sync/SyncCharacter.lua",
  "Addon/Src/Sync/SyncCommands.lua",
  "Addon/Src/Sync/SyncProtocol.lua",
  "Addon/Src/Sync/SyncComm.lua",
  "Addon/Src/Sync/SyncPolicy.lua",
  "Addon/Src/Sync/SyncSession.lua",
  "Addon/Src/Sync/SyncPull.lua",
  "Addon/Src/Sync/SyncPush.lua",
  "Addon/Src/Sync/SyncCleanup.lua",
}

---@param T TestHarness
return function(T)
  T.loadLibraries()
  _G.issecretvalue = _G.issecretvalue or function()
    return false
  end
  local serializer = dofile("Tests/fixtures/stub_serializer.lua")

  ---@class TestReplica
  ---@field name string Character name
  ---@field ns table The namespace of this replica's addon files
  ---@field sync table `ns.sync` of this replica
  ---@field data table The stored database, as `db.global.sync`
  ---@field endpoint FakenetEndpoint
  ---@field transport table
  ---@field session table
  ---@field notices string[] Lines that the replica printed for its user
  ---@field state table The conditions of the game for this replica; change them with `SetState`
  ---@field overrides table Table name -> policy override of this replica's user
  ---@field net Fakenet
  local Replica = {}
  Replica.__index = Replica

  ---Counter that gives every replica without an origin its own
  local made = 0

  ---Makes a replica and joins it to the network. It is online but does nothing until `Login`.
  ---@param net Fakenet
  ---@param name string Character name
  ---@param options { origin: string?, random: (fun(m: integer?, n: integer?): number), rankIndex: integer? }
  ---@return TestReplica
  function Replica.new(net, name, options)
    made = made + 1
    local ns = T.loadAll(FILES)
    local self = setmetatable({ name = name, ns = ns, sync = ns.sync, notices = {}, net = net }, Replica)
    function ns.print(text)
      self.notices[#self.notices + 1] = text
    end
    self.state = { inCombat = false, inRaid = false, inInstance = false, resting = false }
    self.overrides = {}
    self.data = { origin = options.origin or ns.base94.encode(made, 4), tables = {} }
    ns.sync:Initialize(self.data, function()
      return math.floor(net:Now())
    end, options.random, function()
      return name
    end)
    self.endpoint = net:Join(name, options.rankIndex)
    self.transport = ns.syncComm.new({
      codec = ns.syncProtocol.new(serializer),
      guild = net.guild,
      playerName = function()
        return name
      end,
      notify = ns.print,
      sendRaw = function(...)
        self.endpoint:Send(...)
      end,
    })
    self.session = ns.syncSession.new({
      transport = self.transport,
      guild = net.guild,
      sync = ns.sync,
      now = function()
        return net:Now()
      end,
      after = function(seconds, fn)
        return self.endpoint:After(seconds, fn)
      end,
      random = options.random,
      playerName = function()
        return name
      end,
      policy = ns.syncPolicy.new({
        sync = ns.sync,
        overrides = function()
          return self.overrides
        end,
        state = function()
          return self.state
        end,
      }),
    })
    self.endpoint.receive = function(text, distribution, sender)
      self.transport:Receive(text, distribution, sender)
    end
    self.endpoint.onRosterChanged = function()
      self.session:OnRosterChanged()
    end
    if Replica.withoutPush then
      -- The fields hide the methods of the session class
      local function nothing() end
      self.session.SchedulePush, self.session.MarkUnpushed, self.session.ScheduleDelayedPull = nothing, nothing,
        nothing
      self.session.ScheduleSummary = nothing
      self.session.PushWanted = function()
        return false
      end
    end
    return self
  end

  ---Set to true by a test of discovery or of the pull alone: its replicas then push nothing and schedule no
  ---pull for a version that they hear, so every message in the log belongs to what the test looks at.
  Replica.withoutPush = false

  ---The guild check passes: the transport listens and the session starts.
  function Replica:Login()
    self.net:SetOnline(self.name, true)
    self.transport:SetActive(true)
    self.session:OnGuildStateChanged(true)
  end

  ---The character logs out: the roster shows it offline and its session ends.
  function Replica:Logout()
    self.session:Stop()
    self.transport:SetActive(false)
    self.net:SetOnline(self.name, false)
  end

  ---Changes the conditions of the game for this replica and tells its session.
  ---@param changes table Fields of the state: inCombat, inRaid, inInstance, resting
  function Replica:SetState(changes)
    for field, value in pairs(changes) do
      self.state[field] = value
    end
    self.session:OnConditionsChanged()
  end

  ---Returns the table version of one table.
  ---@param tableName string
  ---@return string
  function Replica:Version(tableName)
    return self.ns.syncStore.tableVersion(self.sync:GetTable(tableName))
  end

  ---Returns the names of the peers, in arrival order.
  ---@return string[]
  function Replica:PeerNames()
    local names = {}
    for index, peer in ipairs(self.session:PeerList()) do
      names[index] = peer.name
    end
    return names
  end

  ---Codec for reading the message log of a network
  Replica.protocol = T.loadAll({ "Addon/Src/Sync/Base94.lua", "Addon/Src/Sync/VersionId.lua",
    "Addon/Src/Sync/SyncStore.lua", "Addon/Src/Sync/SyncProtocol.lua" }).syncProtocol
  Replica.codec = Replica.protocol.new(serializer)

  ---Counts the logged messages of one type, optionally from one sender and from a time on.
  ---@param net Fakenet
  ---@param messageType string
  ---@param from string?
  ---@param since number?
  ---@return integer
  function Replica.count(net, messageType, from, since)
    return net:Count(function(entry)
      return Replica.codec.decode(entry.text) == messageType and (not from or entry.from == from)
        and (not since or entry.time >= since)
    end)
  end

  return Replica
end
