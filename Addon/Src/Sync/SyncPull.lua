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

---@class OOOOSyncPullModule
local pull = {}
ns.syncPull = pull

local store = ns.syncStore
local protocol = ns.syncProtocol
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
  if not tbl or not definition then
    return self:Refuse(sender, request, protocol.REASON_UNKNOWN, pull.RETRY_REFUSED)
  end
  if definition.schema ~= request.schema then
    return self:Refuse(sender, request, protocol.REASON_SCHEMA, pull.RETRY_REFUSED)
  end
  local serving = self.serving
  -- A new request of the same peer replaces its old one, and a pull without a step for a long time is dead:
  -- the progress callback of its last batch never came
  if serving and (serving.peer == sender or self.parts.now() - serving.activeAt > pull.SERVE_TIMEOUT) then
    serving = nil
    self.serving = nil
  end
  if serving or not self:MaySend() then
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
  if not self.parts.guild:IsOnline(serving.peer) or not self:MaySend() then
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
-- Hooks of SyncSession.lua
--------------------------------------------------------------------------------

---Ends the pull that this replica answers. Called when the session stops.
function Session:StopPull()
  self.serving = nil
end

---Frees the responder when its requester has gone offline.
function Session:OnPullRosterChanged()
  local serving = self.serving
  if serving and not self.parts.guild:IsOnline(serving.peer) then
    self.serving = nil
  end
end

---Builds the lines about the pull for `/oooo sync status`.
---@return string[] lines Plain text; the caller escapes it for chat
function Session:PullStatusLines()
  local lines = {}
  local serving = self.serving
  if serving then
    lines[#lines + 1] = "serving: " .. serving.table .. " to " .. serving.peer .. ", batch " .. serving.sent
      .. " of " .. #serving.batches
  end
  return lines
end
