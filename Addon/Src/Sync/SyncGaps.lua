local addonName, ns = ...

-- The gap check of the shared database (.agents/sync-design.md, section 4.5): it finds and fills holes that
-- the clock does not show. The clock of a table tells what the table has seen. A table that has lost records
-- below its clock (saved variables that were not written after a crash, a defect of the engine) has the same
-- table version as before, so no pull ever brings them back.
--
-- For a table with `gapCheckHours`, a replica tells the guild how many records it holds per hour of the last
-- hours, each hour with a checksum of its ids (`C`). A replica that holds fewer or other records in an hour
-- whispers the ids that it holds there to the sender (`G`) and gets the records that it lacks (`F`). When
-- they are more than one batch, the sender answers `split` instead, and the hour is halved, again and again,
-- until each half is answered with one short batch. A filled record is stored only when the clock covers it
-- already, and the clock never moves: everything above the clock stays the work of the pull.
--
-- This file adds its methods and message handlers to the session of SyncSession.lua. It uses no WoW API, so
-- the host tests run it over the fake network (Tests/sync_gaps.lua). It loads after SyncPull.lua.

---@class OOOOSyncGapWant An hour of a table in which a peer holds records that this replica may lack
---@field table string
---@field hour integer Number of the hour: its start is `hour * 3600`
---@field peer string Character name of the member to ask
---@field triesKey string Key of `tries`: the table, the hour, and the state of that hour on the peer's side
---@field notBefore number Server time before which the peer is not asked

---@class OOOOSyncGapRange A part of an hour with the ids that this replica holds in it
---@field from integer Server time
---@field to integer Server time
---@field ids string[] Sorted

---@class OOOOSyncGapRequestState The gap request that this replica runs
---@field want OOOOSyncGapWant
---@field ranges OOOOSyncGapRange[] The hour, cut so that the ids of each part fit into one message
---@field index integer Number of the range that is asked for now
---@field nonce integer The nonce of the request for that range
---@field nextBatch integer Number of the batch that is expected next
---@field splits integer Number of ranges of this request that were halved
---@field timer OOOOSyncTimer|nil Ends the request when no batch comes

---@class OOOOSyncGapServing A gap request that this replica answers
---@field peer string Character name of the requester
---@field table string
---@field nonce integer
---@field batches OOOOSyncWireRecord[][]
---@field sent integer Number of batches handed to the transport
---@field left integer Number of batches that have left the send queue
---@field activeAt number Server time of the last step

---@class OOOOSyncGapStats Numbers of this session, for `/oooo sync status`
---@field sent integer Messages with the own counts
---@field heard integer Messages with the counts of a peer that were compared
---@field differing integer Of those, the ones with an hour that differs
---@field requests integer Gap requests sent
---@field splits integer Of those, the ones that the peer answered with `split`: the range was halved
---@field timeouts integer Gap requests that got no answer
---@field filled integer Records stored into holes
---@field skipped integer Received records that were not stored
---@field served integer Gap requests of peers that were answered

---@class OOOOSyncGapState What the session knows about the gap check, for the session only
---@field timer OOOOSyncTimer|nil Runs until the next message with the own counts
---@field heard table<string, boolean> Table -> true when a peer has sent the counts of this replica since the
---own ones went out last
---@field sentAt table<string, number> Table -> server time of the last message with the own counts
---@field answerTimer OOOOSyncTimer|nil Runs until the counts are sent as an answer to a peer that holds less
---@field answerTables table<string, boolean> Set of the tables of that answer
---@field wants table<string, OOOOSyncGapWant> Table and hour -> the want; one per hour
---@field tries table<string, integer> `triesKey` -> gap requests for it that were answered in this session
---@field silent table<string, integer> Character name -> gap requests in a row that this peer did not answer
---@field pumpTimer OOOOSyncTimer|nil Runs until the next gap request is tried
---@field request OOOOSyncGapRequestState|nil
---@field serving OOOOSyncGapServing|nil
---@field stats OOOOSyncGapStats

---@class OOOOSyncGapsModule
local gaps = {}
ns.syncGaps = gaps

local store = ns.syncStore
local versionId = ns.versionId
local protocol = ns.syncProtocol
local pull = ns.syncPull
---@class OOOOSyncSession
---@field gaps OOOOSyncGapState|nil Made when first needed; dropped by `StopGaps`
local Session = ns.syncSession.Session
local handlers = ns.syncSession.handlers

---Seconds that a record must be old before it is counted. A record that is younger can still be on its way
---by the normal paths: the push of its writer, the periodic summary of every 10 to 15 minutes, and the pull
---that follows it.
gaps.SETTLE_SECONDS = 1200
---Seconds by which the cut time of a received message may be later than the own one would be
gaps.CUT_SLACK = 300
---Seconds by which it may be earlier: a message that waited longer in a send queue is not compared
gaps.CUT_MAX_AGE = 3600
---Seconds between the end of discovery and the first message with the counts: a random value in this range.
---The same wait applies after a round in which a table could not send or had a pull to run.
gaps.FIRST_MIN, gaps.FIRST_MAX = 120, 300
---Seconds between two messages with the counts: a random value in this range. Replicas with equal counts
---send one message between them, more or less, like the periodic summary.
gaps.COUNTS_MIN, gaps.COUNTS_MAX = 1200, 1800
---Seconds between the counts of a peer that holds less and the own counts as the answer: a random value in
---this range. A replica that hears its own counts from another peer in that time stays silent.
gaps.ANSWER_DELAY_MIN, gaps.ANSWER_DELAY_MAX = 2, 10
---Seconds in which the own counts of a table are sent at most once as an answer
gaps.ANSWER_INTERVAL = 300
---Seconds between counts that differ and the gap request: a random value in this range, so that many
---replicas with the same hole do not all ask one member at the same moment
gaps.REQUEST_DELAY_MIN, gaps.REQUEST_DELAY_MAX = 5, 30
---Seconds after which a want that had to wait (conditions, a pull, a busy peer) is tried again
gaps.RETRY_SECONDS = 30
---Seconds without a batch after which the requester gives a gap request up
gaps.TIMEOUT = 60
---Seconds without a step after which a gap request that this replica answers counts as dead
gaps.SERVE_TIMEOUT = 120
---Most answered gap requests per table, hour, and state of that hour on the other side, in one session. A
---difference that a fill cannot close (a record that this replica refuses) is then not asked for again and
---again.
gaps.MAX_TRIES = 2
---Gap requests in a row without an answer after which a peer is not asked again in this session. A request
---without an answer is no try: the message was lost, or the peer has gone.
gaps.MAX_SILENT = 3
---Most ids in one gap request: about the size of one batch (11 bytes each). An hour in which this replica
---holds more is halved until every part has fewer, before anything is asked.
gaps.MAX_IDS = 200
---Most ranges that are halved for one hour and peer. An honest peer needs about one per batch of records
---that this replica lacks, so this is an hour with thousands of missing records, or a peer that answers
---`split` whatever it is asked.
gaps.MAX_SPLITS = 200
---Size of one fill batch in bytes, by `syncStore.recordSize`. It is also the most that a peer sends as the
---answer to one gap request: when a range holds more for the requester, the peer answers `split`, and the
---requester halves the range and asks for both halves (`SplitGapRange`).
gaps.BATCH_BYTES = pull.BATCH_BYTES

---Stops a timer when it runs.
---@param timer OOOOSyncTimer|nil
local function cancel(timer)
  if timer then
    timer:Cancel()
  end
end

---Returns the cut time of the counts at a moment: records from that time on are too young to be counted.
---@param now number Server time
---@return integer cut
function gaps.cutTime(now)
  return math.floor(now) - gaps.SETTLE_SECONDS
end

---Cuts a time range into parts with at most `maxIds` ids each, by halving it. A single second with more ids
---than that is left out: a request with only a part of its ids would be answered with records that this
---replica holds.
---@param ids string[] The ids of the range, sorted
---@param from integer Server time, the start of the range
---@param to integer Server time, the end of the range
---@param maxIds integer
---@return OOOOSyncGapRange[] ranges In the order of time
function gaps.splitRange(ids, from, to, maxIds)
  local ranges = {}
  ---@param first integer Index of the first id of the part
  ---@param last integer Index of its last id; `first - 1` for a part without ids
  ---@param partFrom integer
  ---@param partTo integer
  local function split(first, last, partFrom, partTo)
    if last - first + 1 <= maxIds then
      local part = {}
      for index = first, last do
        part[#part + 1] = ids[index]
      end
      ranges[#ranges + 1] = { from = partFrom, to = partTo, ids = part }
      return
    end
    if partTo - partFrom <= 1 then
      return
    end
    local middle = partFrom + math.floor((partTo - partFrom) / 2)
    local prefix = versionId.timePrefix(middle)
    local cut = first
    while cut <= last and ids[cut] < prefix do
      cut = cut + 1
    end
    split(first, cut - 1, partFrom, middle)
    split(cut, last, middle, partTo)
  end
  split(1, #ids, from, to)
  return ranges
end

---Returns the state of the gap check, made when first needed.
---@return OOOOSyncGapState
function Session:Gaps()
  local state = self.gaps
  if not state then
    state = {
      heard = {},
      sentAt = {},
      answerTables = {},
      wants = {},
      tries = {},
      silent = {},
      stats = { sent = 0, heard = 0, differing = 0, requests = 0, splits = 0, timeouts = 0, filled = 0, skipped = 0,
        served = 0 },
    }
    self.gaps = state
  end
  return state
end

---Returns the number of hours that a table compares; nil for a table without the gap check, and for one that
---the user has turned off.
---@param tableName string
---@return integer|nil hours
function Session:GapHours(tableName)
  local definition = self.parts.sync.definitions[tableName]
  if not definition or not definition.gapCheckHours or not self.parts.policy:IsEnabled(tableName) then
    return nil
  end
  return definition.gapCheckHours
end

--------------------------------------------------------------------------------
-- The counts
--------------------------------------------------------------------------------

---Counts the records of a table per hour for a message with the counts: `hours` hours, of which the last is
---the hour of the second before `cut`, counted up to `cut`.
---@param tableName string
---@param cut integer Server time
---@param hours integer
---@return integer[]|nil counts nil when the table cannot be used or the hours start before the time 0
---@return integer[]|nil sums
---@return integer|nil firstHour Number of the first hour
function Session:GapCounts(tableName, cut, hours)
  local tbl = self.parts.sync:GetTable(tableName)
  local first = math.floor((cut - 1) / store.HOUR) - hours + 1
  if not tbl or first < 0 then
    return nil
  end
  local counts, sums = store.hourCounts(tbl, first, hours, cut)
  return counts, sums, first
end

---Sends the counts per hour of a table to the guild.
---@param tableName string
---@return boolean sent
function Session:SendCounts(tableName)
  local hours = self:GapHours(tableName)
  if not hours then
    return false
  end
  local now = self.parts.now()
  local cut = gaps.cutTime(now)
  local counts, sums = self:GapCounts(tableName, cut, hours)
  if not counts or not sums then
    return false
  end
  -- The message fits into one part of the transport (4 bytes per hour), and it travels in the queue of the
  -- pushes, so it never overtakes one
  if not self.parts.transport:Send("C", nil, "BULK", nil, tableName, cut, protocol.packCounts(counts, sums)) then
    return false
  end
  local state = self:Gaps()
  state.sentAt[tableName] = now
  state.heard[tableName] = nil
  state.answerTables[tableName] = nil
  state.stats.sent = state.stats.sent + 1
  self:ToldGuild()
  return true
end

---Tells whether a table may take part in the gap check now: it may send, and no pull of it runs or is about
---to start. What the clock shows as missing is the work of the pull, and the counts are compared after it.
---@param tableName string
---@return boolean
function Session:MayCheckGaps(tableName)
  return self.discovered and self:MayTransfer(tableName) and not self:IsPullPending(tableName)
end

---Sends the counts of every table with the gap check whose counts no peer has sent since the last round.
---@param always boolean? true: also the tables whose counts a peer has sent (`/oooo sync gaps`)
---@return boolean held true when a table had to wait: it may not send now, or it has a pull to run
---@return integer sent Number of messages
function Session:SendDueCounts(always)
  local state = self:Gaps()
  local held, sent = false, 0
  for _, name in ipairs(self.parts.sync.names) do
    if self:GapHours(name) then
      if not self:MayCheckGaps(name) then
        held = true
      elseif state.heard[name] and not always then
        -- A peer has told the guild the same counts: one message per round is enough
        state.heard[name] = nil
      elseif self:SendCounts(name) then
        sent = sent + 1
      end
    end
  end
  return held, sent
end

---Starts the timer of the next message with the counts.
---@param soon boolean? true: the short wait of the first round
function Session:ScheduleCounts(soon)
  local state = self:Gaps()
  cancel(state.timer)
  local delay = soon and self:RandomDelay(gaps.FIRST_MIN, gaps.FIRST_MAX)
    or self:RandomDelay(gaps.COUNTS_MIN, gaps.COUNTS_MAX)
  state.timer = self.parts.after(delay, function()
    state.timer = nil
    if self.gaps ~= state then
      return
    end
    local held = self:SendDueCounts()
    self:ScheduleCounts(held)
  end)
end

---Notes that a peer holds less than this replica in an hour of a table: the own counts go to the guild after
---a short random wait, so that the peer sees what it lacks and asks. They are left out when another peer
---sends the same counts in that time, and when this replica has sent them a moment ago.
---@param tableName string
function Session:OweCounts(tableName)
  local state = self:Gaps()
  local sentAt = state.sentAt[tableName]
  if sentAt and self.parts.now() - sentAt < gaps.ANSWER_INTERVAL then
    return
  end
  state.answerTables[tableName] = true
  if state.answerTimer then
    return
  end
  state.answerTimer = self.parts.after(self:RandomDelay(gaps.ANSWER_DELAY_MIN, gaps.ANSWER_DELAY_MAX), function()
    state.answerTimer = nil
    if self.gaps ~= state then
      return
    end
    local tables = state.answerTables
    state.answerTables = {}
    for name in pairs(tables) do
      if self:MayCheckGaps(name) then
        self:SendCounts(name)
      end
    end
  end)
end

---Counts: the sender tells how many records it holds per hour of a table. An hour in which it holds as many
---records as this replica or more, and not the same ones, is an hour in which this replica may lack records:
---it is asked for. An hour in which the sender holds fewer is the sender's to ask for; it learns that from
---the counts of this replica.
---@param self OOOOSyncSession
---@param sender string
---@param message OOOOSyncCounts
function handlers.C(self, sender, message)
  local tableName = message.table
  local hours = self:GapHours(tableName)
  if not hours or not self.discovered then
    return
  end
  -- The sender has the addon, whatever its tables hold
  self:TouchPeer(sender, {}, false)
  local ownCut = gaps.cutTime(self.parts.now())
  if #message.counts > hours or message.cut > ownCut + gaps.CUT_SLACK or message.cut < ownCut - gaps.CUT_MAX_AGE
    or self:IsPullPending(tableName) then
    return
  end
  local counts, sums, first = self:GapCounts(tableName, message.cut, #message.counts)
  if not counts or not sums or not first then
    return
  end
  local state = self:Gaps()
  state.stats.heard = state.stats.heard + 1
  local isEqual, senderLacks, wanted = true, false, false
  for index = 1, #counts do
    local own, theirs = math.min(counts[index], store.MAX_HOUR_COUNT), message.counts[index]
    if own ~= theirs or sums[index] ~= message.sums[index] then
      isEqual = false
      if theirs >= own then
        wanted = self:WantGap(tableName, first + index - 1, sender, theirs .. ":" .. message.sums[index]) or wanted
      else
        senderLacks = true
      end
    end
  end
  if isEqual then
    if #counts == hours then
      state.heard[tableName] = true
      state.answerTables[tableName] = nil
    end
    return
  end
  state.stats.differing = state.stats.differing + 1
  if senderLacks then
    self:OweCounts(tableName)
  end
  if wanted then
    self:ScheduleGapPump()
  end
end

--------------------------------------------------------------------------------
-- Requester
--------------------------------------------------------------------------------

---Notes an hour of a table in which a peer holds records that this replica may lack. One want is kept per
---table and hour; a later one names the peer that was heard last.
---@param tableName string
---@param hour integer Number of the hour
---@param peer string
---@param peerState string What tells the state of that hour on the peer's side: its count and checksum, or
---the name of a peer whose request showed the hole
---@return boolean wanted false when that state was asked for often enough in this session, or the peer has
---left too many requests without an answer
function Session:WantGap(tableName, hour, peer, peerState)
  local state = self:Gaps()
  local triesKey = tableName .. "\0" .. hour .. "\0" .. peerState
  if (state.tries[triesKey] or 0) >= gaps.MAX_TRIES or (state.silent[peer] or 0) >= gaps.MAX_SILENT then
    return false
  end
  local key = tableName .. "\0" .. hour
  local want = state.wants[key]
  if want then
    want.peer, want.triesKey = peer, triesKey
  else
    state.wants[key] = { table = tableName, hour = hour, peer = peer, triesKey = triesKey, notBefore = 0 }
  end
  return true
end

---Starts the timer of the next gap request, when none runs.
---@param delay number? Seconds; without it, the random wait after counts that differ
function Session:ScheduleGapPump(delay)
  local state = self:Gaps()
  if state.pumpTimer then
    return
  end
  state.pumpTimer = self.parts.after(delay or self:RandomDelay(gaps.REQUEST_DELAY_MIN, gaps.REQUEST_DELAY_MAX),
    function()
      state.pumpTimer = nil
      if self.gaps == state then
        self:PumpGaps()
      end
    end)
end

---Starts the next gap request when none runs: the earliest hour that can be asked for now. One request runs
---at a time. A want whose peer has gone is dropped; one that has to wait (the conditions, a pull of its
---table, a busy peer) is tried again later.
function Session:PumpGaps()
  local state = self.gaps
  if not state or state.request or not self.discovered then
    return
  end
  local keys = {}
  for key in pairs(state.wants) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local first, second = state.wants[a], state.wants[b]
    if first.table ~= second.table then
      return first.table < second.table
    end
    return first.hour < second.hour
  end)
  local now = self.parts.now()
  local waiting = false
  for _, key in ipairs(keys) do
    local want = state.wants[key]
    if not self.peers[want.peer] or not self.parts.guild:IsOnline(want.peer) or not self:GapHours(want.table)
      or (state.silent[want.peer] or 0) >= gaps.MAX_SILENT then
      state.wants[key] = nil
    elseif want.notBefore > now or not self:MayCheckGaps(want.table) then
      waiting = true
    else
      state.wants[key] = nil
      if self:StartGapRequest(want) then
        return
      end
    end
  end
  if waiting then
    self:ScheduleGapPump(gaps.RETRY_SECONDS)
  end
end

---Starts the gap request for one hour: the ids that this replica holds in the settled part of the hour go to
---the peer, in as many messages as their number needs.
---@param want OOOOSyncGapWant
---@return boolean started false when there is nothing to ask or the request could not be sent
function Session:StartGapRequest(want)
  local state = self:Gaps()
  local tbl = self.parts.sync:GetTable(want.table)
  local from = want.hour * store.HOUR
  local to = math.min(from + store.HOUR, gaps.cutTime(self.parts.now()))
  if not tbl or to <= from then
    return false
  end
  local request = {
    want = want,
    ranges = gaps.splitRange(store.idsInRange(tbl, from, to), from, to, gaps.MAX_IDS),
    index = 0,
    nonce = 0,
    nextBatch = 1,
    splits = 0,
  }
  state.tries[want.triesKey] = (state.tries[want.triesKey] or 0) + 1
  state.request = request
  self:NotifyProgress()
  return self:SendGapRequest(request)
end

---Sends the request for the next range of the running gap request, or ends the request after the last one.
---@param request OOOOSyncGapRequestState
---@return boolean sent false when the request has ended
function Session:SendGapRequest(request)
  local state = self:Gaps()
  if state.request ~= request then
    return false
  end
  cancel(request.timer)
  request.timer = nil
  local want = request.want
  local range = request.ranges[request.index + 1]
  local _, definition = self.parts.sync:GetTable(want.table)
  local nonce = math.floor(self.parts.random() * (protocol.MAX_NONCE - 1)) + 1
  if not range or not definition or not self:Whisper("G", want.peer, "BULK", nil, want.table, definition.schema,
    nonce, range.from, range.to, table.concat(range.ids)) then
    -- The hour is done, or the peer has gone: the next want follows in a later frame
    state.request = nil
    self:NotifyProgress()
    self:ScheduleGapPump(0)
    return false
  end
  request.index = request.index + 1
  request.nonce = nonce
  request.nextBatch = 1
  state.stats.requests = state.stats.requests + 1
  self:ArmGapTimer(request)
  return true
end

---Starts the timeout of the running gap request again: it ends the request when no batch comes for
---`gaps.TIMEOUT`. What was stored stays: every filled record stands for itself. The hour is asked for again
---when counts that differ are heard again; a peer that stays silent is left alone after `MAX_SILENT` requests.
---@param request OOOOSyncGapRequestState
function Session:ArmGapTimer(request)
  cancel(request.timer)
  request.timer = self.parts.after(gaps.TIMEOUT, function()
    local state = self.gaps
    if state and state.request == request then
      local want = request.want
      state.request = nil
      state.stats.timeouts = state.stats.timeouts + 1
      state.tries[want.triesKey] = math.max(0, (state.tries[want.triesKey] or 1) - 1)
      state.silent[want.peer] = (state.silent[want.peer] or 0) + 1
      self:NotifyProgress()
      self:PumpGaps()
    end
  end)
end

---Fill: one batch of the answer to the gap request of this replica. Each record is stored only when it lies
---in the range that was asked for and below the clock (`sync:FillRemote`).
---@param self OOOOSyncSession
---@param sender string
---@param fill OOOOSyncFill
function handlers.F(self, sender, fill)
  local state = self.gaps
  local request = state and state.request
  if not state or not request or sender ~= request.want.peer or fill.table ~= request.want.table
    or fill.nonce ~= request.nonce or fill.batch ~= request.nextBatch then
    return
  end
  state.silent[sender] = nil
  local range = request.ranges[request.index]
  local filled, skipped = self.parts.sync:FillRemote(fill.table, fill.records, range.from, range.to,
    function(record, definition)
      return self:CheckRecord(record, definition)
    end)
  state.stats.filled = state.stats.filled + #filled
  state.stats.skipped = state.stats.skipped + skipped
  request.nextBatch = request.nextBatch + 1
  if fill.last then
    self:SendGapRequest(request)
  else
    self:ArmGapTimer(request)
  end
end

---The handler of a refusal in SyncPull.lua; a refusal of a gap request has the same form
local pullBusy = handlers.B

---Halves the range that the running gap request has just asked for, after the peer has answered that it
---holds too much there for one batch: the two halves take the place of the range, each with its part of the
---ids, and the first of them is asked for next. Halving goes on, answer by answer, until what the peer has
---to send for a range fits into one batch.
---@param request OOOOSyncGapRequestState
function Session:SplitGapRange(request)
  local index = request.index
  local range = request.ranges[index]
  request.splits = request.splits + 1
  if request.splits > gaps.MAX_SPLITS then
    -- What was filled stays; the rest of the hour is left
    request.ranges = {}
    request.index = 0
  -- A single second cannot be halved; the peer answers such a range in full, so this is a peer that errs
  elseif range and range.to - range.from > 1 then
    local middle = range.from + math.floor((range.to - range.from) / 2)
    local prefix = versionId.timePrefix(middle)
    local lower, upper = {}, {}
    for _, id in ipairs(range.ids) do
      if id < prefix then
        lower[#lower + 1] = id
      else
        upper[#upper + 1] = id
      end
    end
    table.remove(request.ranges, index)
    table.insert(request.ranges, index, { from = middle, to = range.to, ids = upper })
    table.insert(request.ranges, index, { from = range.from, to = middle, ids = lower })
    request.index = index - 1
  end
  self:SendGapRequest(request)
end

---Busy: the peer refuses a request of this replica. A gap request that is refused with `split` goes on with
---the halves of its range. One that is refused because the peer is busy waits, and for another reason (the
---peer lacks the table or has another schema) it is dropped. Any other refusal belongs to the pull.
---@param self OOOOSyncSession
---@param sender string
---@param busy OOOOSyncBusy
function handlers.B(self, sender, busy)
  local state = self.gaps
  local request = state and state.request
  if not state or not request or sender ~= request.want.peer or busy.table ~= request.want.table
    or busy.nonce ~= request.nonce then
    return pullBusy(self, sender, busy)
  end
  -- The peer is there and answers
  state.silent[sender] = nil
  if busy.reason == protocol.REASON_SPLIT then
    state.stats.splits = state.stats.splits + 1
    return self:SplitGapRange(request)
  end
  cancel(request.timer)
  state.request = nil
  self:NotifyProgress()
  local want = request.want
  if busy.reason == protocol.REASON_BUSY then
    -- Nothing was asked: the try does not count
    state.tries[want.triesKey] = math.max(0, (state.tries[want.triesKey] or 1) - 1)
    local key = want.table .. "\0" .. want.hour
    if not state.wants[key] then
      want.notBefore = self.parts.now() + math.max(busy.retry, pull.MIN_RETRY)
      state.wants[key] = want
    end
  end
  self:PumpGaps()
end

--------------------------------------------------------------------------------
-- Responder
--------------------------------------------------------------------------------

---Gap request: the sender names a time range of a table and the ids that it holds there, and asks for the
---records that it lacks. The ids also show what this replica lacks itself: it then asks the sender in turn.
---@param self OOOOSyncSession
---@param sender string
---@param request OOOOSyncGapRequest
function handlers.G(self, sender, request)
  local tbl, definition = self.parts.sync:GetTable(request.table)
  if not tbl or not definition or not self:GapHours(request.table) then
    return self:Refuse(sender, request, protocol.REASON_UNKNOWN, pull.RETRY_REFUSED)
  end
  if definition.schema ~= request.schema then
    return self:Refuse(sender, request, protocol.REASON_SCHEMA, pull.RETRY_REFUSED)
  end
  self:TouchPeer(sender, {}, false)
  local now = self.parts.now()
  local state = self:Gaps()
  local serving = state.serving
  -- A new request of the same peer replaces its old one, and one without a step for a long time is dead
  if serving and (serving.peer == sender or now - serving.activeAt > gaps.SERVE_TIMEOUT) then
    serving = nil
    state.serving = nil
  end
  -- One transfer at a time: a pull that this replica answers comes first. A stale table gives nothing until
  -- its own pull has emptied and filled it (SyncCleanup.lua).
  local pulling = self.serving
  if serving or (pulling and now - pulling.activeAt <= pull.SERVE_TIMEOUT) or self:IsStale(request.table)
    or not self:MayTransfer(request.table) then
    return self:Refuse(sender, request, protocol.REASON_BUSY, pull.RETRY_BUSY)
  end
  local records, lacking = store.selectMissing(tbl, request.from, request.to, request.have)
  local batches = store.splitBatches(records, gaps.BATCH_BYTES)
  if #batches > 1 and request.to - request.from > 1 then
    -- Too much for one answer: the requester halves the range and asks for both halves, until an answer is
    -- one batch. Every exchange stays short, so nobody waits long for this replica and a lost message costs
    -- little. Only a single second, which cannot be halved, is answered with more batches.
    self:Refuse(sender, request, protocol.REASON_SPLIT, 0)
  else
    if #batches == 0 then
      -- The requester waits for a last batch, also when it lacks nothing
      batches[1] = {}
    end
    serving = {
      peer = sender,
      table = request.table,
      nonce = request.nonce,
      batches = batches,
      sent = 0,
      left = 0,
      activeAt = now,
    }
    state.serving = serving
    state.stats.served = state.stats.served + 1
    self:SendFill(serving)
  end
  if lacking > 0 and self:WantGap(request.table, math.floor(request.from / store.HOUR), sender, "?" .. sender) then
    self:ScheduleGapPump()
  end
end

---Sends the next batch of a gap request that this replica answers. The batch after it is sent when this one
---has left the send queue, like the batches of a pull.
---@param serving OOOOSyncGapServing
function Session:SendFill(serving)
  local state = self.gaps
  if not state or state.serving ~= serving then
    return
  end
  -- The requester has gone, or this replica may not send any more: the requester's timeout does the rest
  if not self.parts.guild:IsOnline(serving.peer) or not self:MayTransfer(serving.table) then
    state.serving = nil
    return
  end
  local index = serving.sent + 1
  local isLast = index == #serving.batches
  serving.sent = index
  serving.activeAt = self.parts.now()
  local queued = self:Whisper("F", serving.peer, "BULK", function(sent, total)
    if sent < total or state.serving ~= serving or serving.left >= index then
      return
    end
    serving.left = index
    serving.activeAt = self.parts.now()
    if isLast then
      state.serving = nil
    else
      -- Through the timer: the callback can run inside `Send`, and the next batch belongs to a later frame
      self.parts.after(0, function()
        self:SendFill(serving)
      end)
    end
  end, serving.table, serving.nonce, index, isLast, protocol.packRecords(serving.batches[index]))
  if not queued then
    state.serving = nil
  end
end

--------------------------------------------------------------------------------
-- Hooks of SyncSession.lua
--------------------------------------------------------------------------------

---Starts the gap check: the first message with the counts follows after a short wait. Called when discovery
---has ended.
function Session:StartGaps()
  local state = self:Gaps()
  if not state.timer then
    self:ScheduleCounts(true)
  end
end

---Stops the timers of the gap check and forgets what it knew. Called when the session stops.
function Session:StopGaps()
  local state = self.gaps
  if not state then
    return
  end
  cancel(state.timer)
  cancel(state.answerTimer)
  cancel(state.pumpTimer)
  if state.request then
    cancel(state.request.timer)
  end
  self.gaps = nil
end

---Builds the lines about the gap check for `/oooo sync status`.
---@return string[] lines Plain text; the caller escapes it for chat
function Session:GapStatusLines()
  local state = self.gaps
  if not state then
    return {}
  end
  local stats = state.stats
  local waiting = 0
  for _ in pairs(state.wants) do
    waiting = waiting + 1
  end
  -- Nothing was sent or heard yet: there is nothing to tell
  if stats.sent + stats.heard + stats.served + waiting == 0 and not state.request then
    return {}
  end
  local lines = { "gap check: counts sent " .. stats.sent .. ", heard " .. stats.heard .. " (" .. stats.differing
    .. " with other counts); " .. stats.requests .. " requests (" .. stats.splits .. " halved, " .. stats.timeouts
    .. " without answer), "
    .. stats.filled .. " records filled, " .. stats.skipped .. " not taken; " .. waiting .. " hours wait; "
    .. stats.served .. " requests answered" }
  local request = state.request
  if request then
    lines[#lines + 1] = "filling: " .. request.want.table .. " from " .. request.want.peer .. ", part "
      .. request.index .. " of " .. #request.ranges
  end
  return lines
end

ns.syncSlash:Register("gaps", "gaps - compare the records per hour with the other members now", function()
  local current = ns.syncSession.current
  if not current or not current.discovered then
    ns.print("The shared database has not found the other members yet.")
    return
  end
  local held, sent = current:SendDueCounts(true)
  ns.print("gap check: " .. sent .. " tables told to the guild" .. (held and "; a table has to wait (a fight, "
    .. "or a pull that runs first)" or "") .. ". A member who holds other records answers within some seconds.")
  for _, line in ipairs(current:GapStatusLines()) do
    ns.print(ns.syncCommands.escape(line))
  end
end)
