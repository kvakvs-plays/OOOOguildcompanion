-- An in-memory guild network for host tests: a fake clock, fake timers, and endpoints that exchange text on
-- the channels GUILD and WHISPER with a delay and with loss. A member can go offline and leave the guild.
-- Nothing runs by itself: `net:Advance(seconds)` moves the clock and fires what is due, in time order.
--
-- Usage: local Fakenet = dofile("Tests/fakenet.lua"); local net = Fakenet.new({ random = random })

---@class FakenetOptions
---@field random fun(m: integer?, n: integer?): number Like math.random; decides delay and loss
---@field minDelay number? Shortest travel time of a message in seconds; default 0.05
---@field maxDelay number? Longest travel time; default 0.2
---@field loss number? Chance from 0 to 1 that a receiver does not get a message; default 0
---@field start number? Clock value at the start; default 1795000000

---@class FakenetTimer
---@field time number Clock value at which it fires
---@field cancelled boolean
---@field Cancel fun(self: FakenetTimer)

---@class FakenetLogEntry One sent message
---@field time number
---@field from string
---@field distribution string "GUILD" or "WHISPER"
---@field target string|nil
---@field text string

---@class FakenetEndpoint One member's connection
---@field name string
---@field net Fakenet
---@field receive (fun(text: string, distribution: string, sender: string))|nil Set by the test
---@field onRosterChanged (fun())|nil Set by the test; called when another member's roster entry changes

---@class Fakenet
---@field clock number
---@field minDelay number
---@field maxDelay number
---@field loss number
---@field log FakenetLogEntry[] Every message that an endpoint sent, also the lost ones
---@field guild table The roster as every member sees it, with the query functions of `ns.guildState`
local Fakenet = {}
Fakenet.__index = Fakenet

---@class FakenetEndpoint
local Endpoint = {}
Endpoint.__index = Endpoint

---Makes a network without members.
---@param options FakenetOptions
---@return Fakenet
function Fakenet.new(options)
  local net = setmetatable({
    random = options.random,
    minDelay = options.minDelay or 0.05,
    maxDelay = options.maxDelay or 0.2,
    loss = options.loss or 0,
    clock = options.start or 1795000000,
    timers = {},
    sequence = 0,
    members = {},
    endpoints = {},
    log = {},
  }, Fakenet)
  local members = net.members
  net.guild = {
    GetMember = function(_, name)
      return members[name]
    end,
    IsOnline = function(_, name)
      return members[name] ~= nil and members[name].online
    end,
    -- The fake roster is never stale
    NoteOnline = function() end,
  }
  return net
end

---Returns the clock value in seconds.
---@return number
function Fakenet:Now()
  return self.clock
end

---Calls `fn` once, `seconds` from now. Timers of the same moment fire in the order in which they were made.
---@param seconds number
---@param fn fun()
---@return FakenetTimer
function Fakenet:After(seconds, fn)
  self.sequence = self.sequence + 1
  local timer = { time = self.clock + math.max(0, seconds), sequence = self.sequence, fn = fn, cancelled = false }
  function timer:Cancel()
    self.cancelled = true
  end
  self.timers[#self.timers + 1] = timer
  return timer
end

---Takes the earliest timer that is due at `limit` out of the list.
---@param limit number
---@return FakenetTimer|nil
function Fakenet:NextTimer(limit)
  local best
  for index, timer in ipairs(self.timers) do
    if timer.time <= limit then
      local other = best and self.timers[best]
      if not other or timer.time < other.time or (timer.time == other.time and timer.sequence < other.sequence) then
        best = index
      end
    end
  end
  return best and table.remove(self.timers, best)
end

---Moves the clock forward and fires the timers and deliveries that are due, in time order. A timer that is
---made while the clock moves fires in the same call when it is due.
---@param seconds number
function Fakenet:Advance(seconds)
  local limit = self.clock + seconds
  while true do
    local timer = self:NextTimer(limit)
    if not timer then
      break
    end
    if not timer.cancelled then
      self.clock = timer.time
      timer.fn()
    end
  end
  self.clock = limit
end

---Adds a member, online. A name that was in the guild before gets a new connection.
---@param name string Character name
---@param rankIndex integer? Rank index from 0; default 5
---@return FakenetEndpoint
function Fakenet:Join(name, rankIndex)
  local endpoint = setmetatable({ name = name, net = self }, Endpoint)
  self.members[name] = { online = true, rankIndex = rankIndex or 5 }
  self.endpoints[name] = endpoint
  self:RosterChanged(name)
  return endpoint
end

---Tells every other online member that the roster has changed.
---@param except string Name of the member whose entry changed
function Fakenet:RosterChanged(except)
  for name, endpoint in pairs(self.endpoints) do
    if name ~= except and self.members[name].online and endpoint.onRosterChanged then
      endpoint.onRosterChanged()
    end
  end
end

---Takes a member offline or brings it back. An offline member sends and receives nothing, and its timers
---made with `endpoint:After` do not fire.
---@param name string
---@param online boolean
function Fakenet:SetOnline(name, online)
  local member = assert(self.members[name], "not a member: " .. name)
  if member.online ~= online then
    -- A new table: a cache that kept the old entry must not change behind its back
    self.members[name] = { online = online, rankIndex = member.rankIndex }
    self:RosterChanged(name)
  end
end

---Removes a member from the guild.
---@param name string
function Fakenet:Leave(name)
  self.members[name] = nil
  self.endpoints[name] = nil
  self:RosterChanged(name)
end

---Schedules the delivery of one message to one member; the message can get lost.
---@param entry FakenetLogEntry
---@param to string
function Fakenet:Deliver(entry, to)
  if self.loss > 0 and self.random() < self.loss then
    return
  end
  local delay = self.minDelay + self.random() * (self.maxDelay - self.minDelay)
  self:After(delay, function()
    local member, endpoint = self.members[to], self.endpoints[to]
    if member and member.online and endpoint.receive then
      endpoint.receive(entry.text, entry.distribution, entry.from)
    end
  end)
end

---Counts the logged messages for which `match` gives true; all of them without `match`.
---@param match (fun(entry: FakenetLogEntry): boolean)?
---@return integer
function Fakenet:Count(match)
  local count = 0
  for _, entry in ipairs(self.log) do
    if not match or match(entry) then
      count = count + 1
    end
  end
  return count
end

---Tells whether the member of this endpoint is online.
---@return boolean
function Endpoint:IsOnline()
  local member = self.net.members[self.name]
  return member ~= nil and member.online and self.net.endpoints[self.name] == self
end

---Sends a text, like the game does: a GUILD message reaches every online member, the sender too; a WHISPER
---reaches its target when it is online. The arguments are those of `sendRaw` in SyncComm.lua.
---@param text string
---@param distribution string "GUILD" or "WHISPER"
---@param target string|nil
---@param _priority string?
---@param onProgress (fun(sent: integer, total: integer))?
function Endpoint:Send(text, distribution, target, _priority, onProgress)
  local net = self.net
  if not self:IsOnline() then
    return
  end
  local entry = { time = net.clock, from = self.name, distribution = distribution, target = target, text = text }
  net.log[#net.log + 1] = entry
  if distribution == "GUILD" then
    -- Sorted, so that one seed gives one run
    local names = {}
    for name, member in pairs(net.members) do
      if member.online then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      net:Deliver(entry, name)
    end
  elseif distribution == "WHISPER" then
    if target and net.members[target] and net.members[target].online then
      net:Deliver(entry, target)
    end
  else
    error("unknown distribution: " .. tostring(distribution))
  end
  if onProgress then
    onProgress(#text, #text)
  end
end

---Like `net:After`, but the timer does not fire while this member is offline or gone: a client that has
---logged out runs nothing.
---@param seconds number
---@param fn fun()
---@return FakenetTimer
function Endpoint:After(seconds, fn)
  return self.net:After(seconds, function()
    if self:IsOnline() then
      fn()
    end
  end)
end

return Fakenet
