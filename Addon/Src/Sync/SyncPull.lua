local addonName, ns = ...

-- The pull of the shared database (.agents/00-plan.md, section 7.2): one replica asks a peer for the records
-- that it lacks (`Q`), and the peer answers with batches (`D`) or refuses (`B`).
--
-- This file adds the methods and the message handlers of the pull to the session of SyncSession.lua. It
-- uses no WoW API, so the host tests run it over the fake network (Tests/sync_pull.lua).

---@class OOOOSyncServing A pull that this replica answers
---@field peer string Character name of the requester
---@field table string Table name
---@field nonce integer The nonce of the pull request
---@field batches OOOOSyncWireRecord[][] The records that the requester lacks, cut into batches
---@field rest table<string, string> Clock entries that no record carries, for the last batch
---@field wants table<string, string> Origins for which the requester is ahead, for the last batch
---@field sent integer Number of batches handed to the transport
---@field left integer Number of batches that have left the send queue
---@field activeAt number Server time of the last step

---@class OOOOSyncActivePull The pull that this replica runs
---@field table string Table name
---@field peer string Character name of the source
---@field nonce integer The nonce of the pull request
---@field nextBatch integer Number of the batch that is expected next
---@field dropped integer Number of received records that were not applied
---@field startVersion string Table version at the start of the pull
---@field timer OOOOSyncTimer|nil Ends the pull when no batch comes

---@class OOOOSyncPullModule
local pull = {}
ns.syncPull = pull

local store = ns.syncStore
local versionId = ns.versionId
local protocol = ns.syncProtocol
---@class OOOOSyncSession
local Session = ns.syncSession.Session
local handlers = ns.syncSession.handlers

---Size of one delta batch in bytes, by `syncStore.recordSize`
pull.BATCH_BYTES = 2000
---Seconds after which a requester may ask again when this replica is busy
pull.RETRY_BUSY = 30
---Seconds after which a requester may ask again for a table that this replica cannot give
pull.RETRY_REFUSED = 3600
---Seconds without a step after which a pull that this replica answers counts as dead
pull.SERVE_TIMEOUT = 120
---Seconds without a batch after which the requester gives a pull up
pull.TIMEOUT = 60
---Seconds for which a peer is not asked again for a table after its pull timed out
pull.RETRY_AFTER_TIMEOUT = 300
---Seconds for which a peer is not asked again for a table after it sent a record that was dropped
pull.RETRY_AFTER_DROP = 1800
---Shortest wait in seconds after a refusal, whatever the refusal asks for
pull.MIN_RETRY = 5

---Stops a timer when it runs.
---@param timer OOOOSyncTimer|nil
local function cancel(timer)
  if timer then
    timer:Cancel()
  end
end

--------------------------------------------------------------------------------
-- Responder
--------------------------------------------------------------------------------

---Answers a pull request with a refusal.
---@param sender string
---@param request OOOOSyncPullRequest
---@param reason string A `protocol.REASON_*` value
---@param retry number Seconds after which the requester may ask again
function Session:Refuse(sender, request, reason, retry)
  self.parts.transport:Send("B", sender, "BULK", nil, request.table, request.nonce, reason, retry)
end

---Pull request: the sender asks for the records of one table that its clock does not cover.
---@param self OOOOSyncSession
---@param sender string
---@param request OOOOSyncPullRequest
function handlers.Q(self, sender, request)
  local tbl, definition = self.parts.sync:GetTable(request.table)
  -- A table that the user has turned off is refused like one that this replica does not have
  if not tbl or not definition or not self.parts.policy:IsEnabled(request.table) then
    return self:Refuse(sender, request, protocol.REASON_UNKNOWN, pull.RETRY_REFUSED)
  end
  if definition.schema ~= request.schema then
    return self:Refuse(sender, request, protocol.REASON_SCHEMA, pull.RETRY_REFUSED)
  end
  -- A table that was out of contact for too long can hold records that were deleted meanwhile. It gives
  -- nothing until its own pull has emptied and filled it again (SyncCleanup.lua).
  if self:IsStale(request.table) then
    return self:Refuse(sender, request, protocol.REASON_BUSY, pull.RETRY_BUSY)
  end
  -- The version of this table has changed since the guild heard it last, through records that others
  -- sent. The peers still list the old one, and this request may be the first of many that it causes:
  -- one summary lets the others see that they need not ask.
  local version = store.tableVersion(tbl)
  if self.announced[request.table] ~= version and self:MaySend() then
    self:Announce("S", { [request.table] = version })
  end
  local serving = self.serving
  -- A new request of the same peer replaces its old one, and a pull without a step for a long time is dead:
  -- the progress callback of its last batch never came
  if serving and (serving.peer == sender or self.parts.now() - serving.activeAt > pull.SERVE_TIMEOUT) then
    serving = nil
    self.serving = nil
  end
  if serving or not self:MayTransfer(request.table) then
    return self:Refuse(sender, request, protocol.REASON_BUSY, pull.RETRY_BUSY)
  end

  -- The selection is one pass and one sort over the table. The costly part, packing and serializing, is
  -- done batch by batch in `SendBatch`, each in its own frame.
  local records = store.selectDelta(tbl, request.clock)
  local batches = store.splitBatches(records, pull.BATCH_BYTES)
  if #batches == 0 then
    -- The last batch carries the clock rest and the wants, also when there is no record to send
    batches[1] = {}
  end
  serving = {
    peer = sender,
    table = request.table,
    nonce = request.nonce,
    batches = batches,
    rest = store.clockRest(tbl, request.clock, records),
    wants = store.wants(tbl, request.clock),
    sent = 0,
    left = 0,
    activeAt = self.parts.now(),
  }
  self.serving = serving
  self:SendBatch(serving)
end

---Sends the next batch of a pull that this replica answers. The batch after it is sent when this one has
---left the send queue, so the queue never holds more than one batch.
---@param serving OOOOSyncServing
function Session:SendBatch(serving)
  if self.serving ~= serving then
    return
  end
  -- The requester has gone, or this replica may not send any more: the requester's timeout does the rest
  if not self.parts.guild:IsOnline(serving.peer) or not self:MayTransfer(serving.table) then
    self.serving = nil
    return
  end
  local index = serving.sent + 1
  local isLast = index == #serving.batches
  serving.sent = index
  serving.activeAt = self.parts.now()
  local queued = self.parts.transport:Send("D", serving.peer, "BULK", function(sent, total)
    if sent < total or self.serving ~= serving or serving.left >= index then
      return
    end
    serving.left = index
    serving.activeAt = self.parts.now()
    if isLast then
      self.serving = nil
    else
      -- Through the timer: the callback can run inside `Send`, and the next batch belongs to a later frame
      self.parts.after(0, function()
        self:SendBatch(serving)
      end)
    end
  end, serving.table, serving.nonce, index, isLast, protocol.packRecords(serving.batches[index]),
    isLast and serving.rest or nil, isLast and serving.wants or nil)
  if not queued then
    self.serving = nil
  end
end

--------------------------------------------------------------------------------
-- Requester
--------------------------------------------------------------------------------

---Chooses the peer to pull a table from: among the peers whose table version differs from the own one and
---is not merged yet, the one with the greatest `maxId`; of several, the one that arrived first. A peer
---that has to wait (after a refusal, a timeout, or a bad record) is passed over until its time.
---The function has no side effects.
---@param peers OOOOSyncPeer[]
---@param tableName string
---@param ownVersion string Table version of this replica
---@param merged table<string, boolean>|nil Set of table versions whose data this replica holds already
---@param now number Server time
---@return OOOOSyncPeer|nil source nil when no peer can be asked now
---@return number|nil retryAt Earliest time at which a peer that has to wait can be asked
function pull.chooseSource(peers, tableName, ownVersion, merged, now)
  local best, bestMaxId, retryAt
  for _, peer in ipairs(peers) do
    local version = peer.versions[tableName]
    if version and version ~= ownVersion and not (merged and merged[version]) then
      local wait = peer.retryAt and peer.retryAt[tableName]
      if wait and wait > now then
        if not retryAt or wait < retryAt then
          retryAt = wait
        end
      else
        local maxId = version:sub(1, versionId.LENGTH)
        if not best or maxId > bestMaxId or (maxId == bestMaxId and peer.order < best.order) then
          best, bestMaxId = peer, maxId
        end
      end
    end
  end
  return best, retryAt
end

---Works out the table version of the replica that a pull came from, after the pull is complete: its clock
---is the clock of this table, except for the origins that it named in `wants`, where it is behind.
---@param tbl OOOOSyncTable
---@param wants table<string, string> Origin -> the responder's clock value; the zero id when it has none
---@return string version
function pull.responderVersion(tbl, wants)
  local clock = {}
  for origin, id in pairs(tbl.clock) do
    local theirs = wants[origin]
    if theirs == nil or theirs >= id then
      clock[origin] = id
    elseif theirs ~= versionId.ZERO and versionId.originOf(theirs) == origin then
      clock[origin] = theirs
    end
  end
  return store.versionOfClock(clock)
end

---Tells whether the roster cache is filled: it then holds the own character. Before that, no record of a
---character table could be checked against the roster.
---@return boolean
function Session:IsRosterReady()
  local name = self.parts.playerName()
  return name ~= nil and self.parts.guild:GetMember(name) ~= nil
end

---Starts the next pull when none runs: the first table, in the order of registration, for which a peer can
---be asked. This is the queue of the pull: the other tables wait until this function runs again, after the
---pull has ended. When peers have to wait, a timer calls it again at the earliest time.
function Session:PumpPulls()
  if self.pull or not self.discovered or not self:IsRosterReady() then
    return
  end
  cancel(self.retryTimer)
  self.retryTimer = nil
  local sync, peers, now = self.parts.sync, self:PeerList(), self.parts.now()
  local earliest
  for _, name in ipairs(sync.names) do
    local tbl = sync:GetTable(name)
    -- A table that may not send now waits for `OnConditionsChanged`
    if tbl and self:MayTransfer(name) then
      local source, retryAt = pull.chooseSource(peers, name, store.tableVersion(tbl), self.merged[name], now)
      if source and self:StartPull(name, source) then
        return
      end
      if retryAt and (not earliest or retryAt < earliest) then
        earliest = retryAt
      end
    end
  end
  if earliest then
    self.retryTimer = self.parts.after(earliest - now + 1, function()
      self.retryTimer = nil
      self:PumpPulls()
    end)
  end
  -- No pull is left to run: the pushes that waited for one go on (SyncPush.lua)
  self:SchedulePushes()
end

---Tells whether a pull of a table runs or will start as soon as the running one has ended.
---@param tableName string
---@return boolean
function Session:IsPullPending(tableName)
  local active = self.pull
  if active and active.table == tableName then
    return true
  end
  local tbl = self.parts.sync:GetTable(tableName)
  if not tbl or not self.discovered or not self:IsRosterReady() or not self:MayTransfer(tableName) then
    return false
  end
  return pull.chooseSource(self:PeerList(), tableName, store.tableVersion(tbl), self.merged[tableName],
    self.parts.now()) ~= nil
end

---Makes a peer wait before it is asked again for a table.
---@param peerName string
---@param tableName string
---@param seconds number
function Session:DeferPeer(peerName, tableName, seconds)
  local peer = self.peers[peerName]
  if peer then
    peer.retryAt = peer.retryAt or {}
    peer.retryAt[tableName] = self.parts.now() + seconds
  end
end

---Sends the pull request for a table to a peer and starts the timeout.
---@param tableName string
---@param source OOOOSyncPeer
---@return boolean started false when the request could not be sent
function Session:StartPull(tableName, source)
  local tbl, definition = self.parts.sync:GetTable(tableName)
  if not tbl or not definition then
    return false
  end
  -- A table that was away for longer than tombstones live starts again from nothing (SyncCleanup.lua)
  self:ResetIfStale(tableName)
  local nonce =math.floor(self.parts.random() * (protocol.MAX_NONCE - 1)) + 1
  if not self.parts.transport:Send("Q", source.name, "BULK", nil, tableName, definition.schema, nonce,
    store.digest(tbl)) then
    self:DeferPeer(source.name, tableName, pull.RETRY_AFTER_TIMEOUT)
    return false
  end
  self.pull = {
    table = tableName,
    peer = source.name,
    nonce = nonce,
    nextBatch = 1,
    dropped = 0,
    startVersion = store.tableVersion(tbl),
  }
  self:ArmPullTimer()
  return true
end

---Starts the timeout of the running pull again: it ends the pull when no batch comes for `pull.TIMEOUT`.
function Session:ArmPullTimer()
  local active = self.pull
  if not active then
    return
  end
  cancel(active.timer)
  active.timer = self.parts.after(pull.TIMEOUT, function()
    if self.pull == active then
      -- What was applied stays: the batches came in id order, so the table is in a valid, shorter state
      self:ClosePull(pull.RETRY_AFTER_TIMEOUT)
      self:PumpPulls()
    end
  end)
end

---Ends the running pull.
---@param retrySeconds number|nil Seconds for which the peer is not asked again for the table; nil: no wait
function Session:ClosePull(retrySeconds)
  local active = self.pull
  if not active then
    return
  end
  cancel(active.timer)
  self.pull = nil
  if retrySeconds then
    self:DeferPeer(active.peer, active.table, retrySeconds)
  end
end

---The further check of a received record, after those of `sync:ApplyRemote`: in a table that is keyed by
---character, a record of a name that is not in the guild roster is not kept. Every replica removes such
---records by itself, so the clock still counts the record as seen.
---@param record OOOOSyncWireRecord
---@param definition OOOOSyncTableDefinition
---@return boolean|"seen"
function Session:CheckRecord(record, definition)
  if definition.keyKind == "character" then
    local name = self.parts.sync.keyName(record.key)
    if not name or not self.parts.guild:GetMember(name) then
      return "seen"
    end
  end
  return true
end

---Delta: one batch of the answer to the pull request of this replica.
---@param self OOOOSyncSession
---@param sender string
---@param delta OOOOSyncDelta
function handlers.D(self, sender, delta)
  local active = self.pull
  if not active or sender ~= active.peer or delta.table ~= active.table or delta.nonce ~= active.nonce
    or delta.batch ~= active.nextBatch then
    return
  end
  if #delta.records > 0 then
    self:MarkFresh(active.table, true)
  end
  local _, dropped = self.parts.sync:ApplyRemote(active.table, delta.records, function(record, definition)
    return self:CheckRecord(record, definition)
  end)
  active.dropped = active.dropped + dropped
  active.nextBatch = active.nextBatch + 1
  if delta.last then
    self:FinishPull(active, delta)
  else
    self:ArmPullTimer()
  end
end

---Ends a pull whose last batch has arrived. When every record was applied, the clock rest is merged: this
---table has then seen all that the responder has seen, and the responder's version counts as merged.
---@param active OOOOSyncActivePull
---@param delta OOOOSyncDelta The last batch
function Session:FinishPull(active, delta)
  local tbl = self.parts.sync:GetTable(active.table)
  if not tbl then
    self:ClosePull(nil)
    return
  end
  local now = math.floor(self.parts.now())
  local isComplete = active.dropped == 0
  for _, id in pairs(delta.rest) do
    -- An id from the future would lift the clock over writes that are still to come
    if not versionId.isValid(id, now) then
      isComplete = false
    end
  end
  local hasPushed = false
  if isComplete then
    store.mergeClock(tbl, delta.rest)
    tbl.syncedAt = now
    self:MarkFresh(active.table)
    local version = pull.responderVersion(tbl, delta.wants)
    self.merged[active.table] = self.merged[active.table] or {}
    self.merged[active.table][version] = true
    local peer = self.peers[active.peer]
    if peer then
      peer.versions[active.table] = version
    end
    self:ClosePull(nil)
    -- What the responder lacks goes to the whole guild (SyncPush.lua)
    hasPushed = self:PushWanted(active.table, delta.wants)
  else
    -- The peer would send the same bad record again
    self:ClosePull(pull.RETRY_AFTER_DROP)
  end
  local version = store.tableVersion(tbl)
  -- A push carries the new version already
  if version ~= active.startVersion and not hasPushed then
    self:Announce("S", { [active.table] = version })
  end
  self:PumpPulls()
end

---Busy: the peer refuses the pull request of this replica.
---@param self OOOOSyncSession
---@param sender string
---@param busy OOOOSyncBusy
function handlers.B(self, sender, busy)
  local active = self.pull
  if not active or sender ~= active.peer or busy.table ~= active.table or busy.nonce ~= active.nonce then
    return
  end
  self:ClosePull(math.max(busy.retry, pull.MIN_RETRY))
  self:PumpPulls()
end

--------------------------------------------------------------------------------
-- Hooks of SyncSession.lua
--------------------------------------------------------------------------------

---Ends the pull that this replica answers and the one that it runs. Called when the session stops.
function Session:StopPull()
  self.serving = nil
  self:ClosePull(nil)
  cancel(self.retryTimer)
  self.retryTimer = nil
  self.merged = {}
end

---Follows the roster: frees the responder when its requester has gone offline, moves the running pull to
---another peer when its source has gone offline, and starts the pulls that waited for the roster.
function Session:OnPullRosterChanged()
  local guild = self.parts.guild
  local serving = self.serving
  if serving and not guild:IsOnline(serving.peer) then
    self.serving = nil
  end
  local active = self.pull
  if active and not guild:IsOnline(active.peer) then
    self:ClosePull(nil)
  end
  self:PumpPulls()
end

---Builds the lines about the pull for `/oooo sync status`.
---@return string[] lines Plain text; the caller escapes it for chat
function Session:PullStatusLines()
  local lines = {}
  local active = self.pull
  if active then
    lines[#lines + 1] = "pulling: " .. active.table .. " from " .. active.peer .. ", waiting for batch "
      .. active.nextBatch
  end
  local serving = self.serving
  if serving then
    lines[#lines + 1] = "serving: " .. serving.table .. " to " .. serving.peer .. ", batch " .. serving.sent
      .. " of " .. #serving.batches
  end
  return lines
end
