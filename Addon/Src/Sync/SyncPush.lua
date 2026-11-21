local addonName, ns = ...

-- The push of the shared database (.agents/00-plan.md, section 7.3): a replica sends new records to the
-- whole guild in `P`, and every replica that has no gap before them applies them without a pull.
--
-- This file adds the methods and the message handler of the push to the session of SyncSession.lua. It
-- uses no WoW API, so the host tests run it over the fake network (Tests/sync_push.lua).

---@class OOOOSyncPushModule
local push = {}
ns.syncPush = push

local store = ns.syncStore
local versionId = ns.versionId
local protocol = ns.syncProtocol
---@class OOOOSyncSession
local Session = ns.syncSession.Session
local handlers = ns.syncSession.handlers

---Size of one push message in bytes, by `syncStore.recordSize`; a larger push travels as several messages
push.BATCH_BYTES = 2000
---Seconds between hearing a version that differs and the pull that it asks for: a random value in this
---range. In most cases a push closes the difference in that time, and the delay keeps many peers from
---pulling from one member at the same moment.
push.PULL_DELAY_MIN, push.PULL_DELAY_MAX = 30, 120
---Seconds between two periodic summaries of a replica: a random value in this range. The summary repairs
---what a lost message has left behind: a replica that hears a version that differs from its own pulls.
push.SUMMARY_MIN, push.SUMMARY_MAX = 600, 900

---Stops a timer when it runs.
---@param timer OOOOSyncTimer|nil
local function cancel(timer)
  if timer then
    timer:Cancel()
  end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

---Sends records to the guild, as one `P` or as several when they do not fit into one. Each message names,
---for every origin of its records, the id before the first of them (`base`): a receiver whose clock is at
---or beyond the base has no gap and applies them. The last message carries the clock values that no
---record carries (`rest`). Each message also names the table version of this replica without its records
---(`was`) and with them (`version`): a receiver that holds the first and applies the message holds the
---second, and need not ask this replica for it.
---@param tableName string
---@param records OOOOSyncWireRecord[] In ascending id order
---@param base table<string, string> Origin -> the id that the receivers are expected to have seen
---@param tops table<string, string> Origin -> clock value of this table, for the origins of `base`
---@param isOwn boolean true: own new writes; false: records passed on after a pull
---@return boolean sent false when a message could not be handed to the transport
function Session:SendPush(tableName, records, base, tops, isOwn)
  local tbl, definition = self.parts.sync:GetTable(tableName)
  if not tbl or not definition then
    return false
  end
  local batches = store.splitBatches(records, push.BATCH_BYTES)
  if #batches == 0 then
    -- Nothing but clock values: the writes behind them were replaced by writes of other origins
    batches[1] = {}
  end
  ---Origin -> the last id of that origin in the messages so far
  local reached = {}
  for origin, id in pairs(base) do
    reached[origin] = id
  end
  ---The clock of this table with the pushed origins at the ids that the messages so far have reached
  local clock = {}
  for origin, id in pairs(tbl.clock) do
    clock[origin] = id
  end
  ---Returns the table version that belongs to `reached`.
  local function versionReached()
    for origin in pairs(base) do
      local id = reached[origin]
      clock[origin] = id ~= versionId.ZERO and id or nil
    end
    return store.versionOfClock(clock)
  end
  for index, batch in ipairs(batches) do
    local was = versionReached()
    local batchBase = {}
    for _, record in ipairs(batch) do
      local origin = versionId.originOf(record.id)
      batchBase[origin] = batchBase[origin] or reached[origin] or versionId.ZERO
    end
    for _, record in ipairs(batch) do
      reached[versionId.originOf(record.id)] = record.id
    end
    local rest
    if index == #batches then
      rest = {}
      for origin, top in pairs(tops) do
        if top > (reached[origin] or versionId.ZERO) then
          rest[origin] = top
          -- The rest is taken only by a receiver that has no gap before it
          batchBase[origin] = batchBase[origin] or reached[origin] or versionId.ZERO
          reached[origin] = top
        end
      end
    end
    local version = versionReached()
    if not self.parts.transport:Send("P", nil, "BULK", nil, tableName, definition.schema, version, was, isOwn,
      batchBase, protocol.packRecords(batch), rest) then
      return false
    end
    self.announced[tableName] = version
    self:ToldGuild()
  end
  return true
end

---Lists the records of a table that one origin wrote after an id, in ascending id order.
---@param tbl OOOOSyncTable
---@param origin string
---@param after string An id; `versionId.ZERO` for all records of the origin
---@return OOOOSyncWireRecord[]
local function recordsOf(tbl, origin, after)
  local records = {}
  for key, record in pairs(tbl.records) do
    if record.v > after and versionId.originOf(record.v) == origin then
      records[#records + 1] = { key = key, id = record.v, payload = record.d, tombstone = record.x }
    end
  end
  table.sort(records, function(a, b)
    return a.id < b.id
  end)
  return records
end

---Returns the id of this install's last pushed write in a table.
---@param tbl OOOOSyncTable
---@return string id `versionId.ZERO` when nothing was pushed
local function pushedId(tbl)
  -- The value comes from the saved variables
  return versionId.isWellFormed(tbl.pushed) and tbl.pushed or versionId.ZERO
end

---Tells whether this character may push records of a table at all. A member sends nothing of an officer
---table (plan section 14.3): the same saved data can belong to an officer character and to a member alt, and
---the unsent writes of the officer then wait, with their push mark, until the officer character logs in.
---@param tableName string
---@return boolean
function Session:MayPush(tableName)
  local definition = self.parts.sync.definitions[tableName]
  return not (definition and definition.writers == "officer") or self:IsOfficerSelf()
end

---Pushes the local changes of a table: this install's own records after its last pushed id, with that id
---as base. It does nothing while the table may not send, and while a pull of the table runs or is about to
---start: the push after that pull carries the same records, with a base that fits its responder.
---`SchedulePushes` tries again when the conditions change and when the pulls have ended.
---@param tableName string
function Session:PushLocal(tableName)
  local sync = self.parts.sync
  local tbl = sync:GetTable(tableName)
  local origin = sync:GetOrigin()
  if not tbl or not origin or not sync.dirtySince[tableName] or not self:MayTransfer(tableName)
    or self:IsPullPending(tableName) or not self:MayPush(tableName) then
    return
  end
  local top, pushed = tbl.clock[origin], pushedId(tbl)
  if top and top > pushed then
    if not self:SendPush(tableName, recordsOf(tbl, origin, pushed), { [origin] = pushed }, { [origin] = top },
      true) then
      -- Not in the guild: the change stays unsent
      return
    end
    tbl.pushed = top
    self.lastPushAt[tableName] = self.parts.now()
  end
  sync.dirtySince[tableName] = nil
end

---Starts the push timer of a table that has unsent local changes: it fires when `pushDelay` has passed
---since the first unsent change and `minInterval` since the last push of the table.
---@param tableName string
function Session:SchedulePush(tableName)
  local dirtySince = self.parts.sync.dirtySince[tableName]
  local effective = self.parts.policy:Get(tableName)
  if not dirtySince or not effective or self.pushTimers[tableName] or not self.parts.transport.active then
    return
  end
  local due = dirtySince + effective.pushDelay
  local lastPushAt = self.lastPushAt[tableName]
  if lastPushAt and lastPushAt + effective.minInterval > due then
    due = lastPushAt + effective.minInterval
  end
  self.pushTimers[tableName] = self.parts.after(math.max(0, due - self.parts.now()), function()
    self.pushTimers[tableName] = nil
    self:PushLocal(tableName)
  end)
end

---Starts the push timers of all tables with unsent local changes. Called when the conditions change:
---a push that was due while its table could not send goes out now.
function Session:SchedulePushes()
  for _, name in ipairs(self.parts.sync.names) do
    self:SchedulePush(name)
  end
end

---Finds the tables in which this install has writes that were never pushed, after a login: the mark of
---an unsent change lives in memory only, the last pushed id in the saved variables.
function Session:MarkUnpushed()
  local sync = self.parts.sync
  local origin = sync:GetOrigin()
  for _, name in ipairs(sync.names) do
    local tbl = sync:GetTable(name)
    local top = tbl and origin and tbl.clock[origin]
    if tbl and top and top > pushedId(tbl) then
      sync.dirtySince[name] = sync.dirtySince[name] or math.floor(self.parts.now())
    end
  end
  self:SchedulePushes()
end

---Pushes, after a complete pull, the records that the responder lacks: those of the origins that it named
---in `wants`, with its clock values as base. All peers in the state of the responder can apply them at
---once, so none of them has to pull from this replica.
---@param tableName string
---@param wants table<string, string> Origin -> the responder's clock value; the zero id when it has none
---@return boolean pushed true when a push went out
function Session:PushWanted(tableName, wants)
  local sync = self.parts.sync
  local tbl = sync:GetTable(tableName)
  if not tbl or not self:MayTransfer(tableName) or not self:MayPush(tableName) then
    return false
  end
  local base, tops = {}, {}
  for origin, theirs in pairs(wants) do
    local top = tbl.clock[origin]
    if top and top > theirs and (theirs == versionId.ZERO or versionId.originOf(theirs) == origin) then
      base[origin], tops[origin] = theirs, top
    end
  end
  if next(base) == nil then
    return false
  end
  local records = {}
  for key, record in pairs(tbl.records) do
    local after = base[versionId.originOf(record.v)]
    if after and record.v > after then
      records[#records + 1] = { key = key, id = record.v, payload = record.d, tombstone = record.x }
    end
  end
  table.sort(records, function(a, b)
    return a.id < b.id
  end)
  if not self:SendPush(tableName, records, base, tops, false) then
    return false
  end
  -- The push has carried this install's own writes up to the top: nothing of them is left to push
  local own = sync:GetOrigin()
  if own and tops[own] then
    if tops[own] > pushedId(tbl) then
      tbl.pushed = tops[own]
    end
    sync.dirtySince[tableName] = nil
    self.lastPushAt[tableName] = self.parts.now()
  end
  return true
end

---Starts the timer of the next periodic summary.
function Session:ScheduleSummary()
  cancel(self.summaryTimer)
  self.summaryTimer = self.parts.after(self:RandomDelay(push.SUMMARY_MIN, push.SUMMARY_MAX), function()
    self.summaryTimer = nil
    self:SendSummary()
    self:ScheduleSummary()
  end)
end

---Sends the periodic summary: the versions of the tables whose version no peer has announced since the
---last one. Replicas in the same state therefore send one summary between them, more or less, and a
---replica in another state hears it and pulls.
function Session:SendSummary()
  local own, heard = self:LocalVersions(), self.heardOwn
  self.heardOwn = {}
  if not self:MaySend() then
    return
  end
  local summary = {}
  for name, version in pairs(own) do
    if heard[name] ~= version then
      summary[name] = version
    end
  end
  if next(summary) ~= nil then
    self:Announce("S", summary)
  end
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

---Push: the sender gives new records to everybody. For each origin they are applied only when the clock
---of this table is at or beyond the base of that origin. Otherwise this replica has a gap before them: the
---records are ignored, and a pull is scheduled. In a push of own writes (`own`), a record whose key does not
---belong to the sender is dropped with the later records of its origin.
---A push of a member into an officer table is ignored whole, whatever its `own` flag says: no record, no
---clock entry, no pull. Only its version is kept with the peer (plan section 14.3).
---@param self OOOOSyncSession
---@param sender string
---@param pushed OOOOSyncPush
function handlers.P(self, sender, pushed)
  local sync = self.parts.sync
  local tbl, definition = sync:GetTable(pushed.table)
  if not tbl or not definition or definition.schema ~= pushed.schema
    or not self.parts.policy:IsEnabled(pushed.table) then
    return
  end
  local protected = self:IsProtected(pushed.table)
  if protected and not self:IsOfficerName(sender) then
    self:NoteVersions(sender, { [pushed.table] = pushed.version }, false)
    return
  end
  -- This replica holds what the sender had before the push when it has, or has had, that table version
  local merged = self.merged[pushed.table]
  local heldBefore = store.tableVersion(tbl) == pushed.was or (merged ~= nil and merged[pushed.was] == true)
  ---Origin -> true when this table has a gap before the pushed records of the origin
  local hasGap = {}
  local isWhole = true
  for origin, base in pairs(pushed.base) do
    hasGap[origin] = (tbl.clock[origin] or versionId.ZERO) < base
    isWhole = isWhole and not hasGap[origin]
  end
  local accepted = {}
  for _, record in ipairs(pushed.records) do
    -- An origin without a base cannot be checked for a gap
    if hasGap[versionId.originOf(record.id)] == false then
      accepted[#accepted + 1] = record
    end
  end
  if #accepted > 0 then
    self:MarkFresh(pushed.table, true)
  end
  local _, dropped = sync:ApplyRemote(pushed.table, accepted, function(record, recordDefinition)
    -- Own new writes come from their writer, so the owner rule can be checked. Records that the sender
    -- passes on after a pull cannot: any member may pass on the records of any other (plan section 5.2).
    -- An officer is trusted with every record of a protected table.
    if pushed.own and not protected and not sync:MayWrite(recordDefinition, record.key, sender, true) then
      return false
    end
    return self:CheckRecord(record, recordDefinition)
  end)
  if dropped == 0 then
    local now = math.floor(self.parts.now())
    local rest = {}
    for origin, id in pairs(pushed.rest) do
      if hasGap[origin] == false and versionId.isValid(id, now) then
        rest[origin] = id
      else
        isWhole = false
      end
    end
    store.mergeClock(tbl, rest)
    if isWhole and heldBefore then
      -- All of the push was taken on top of what the sender had before: this replica holds the sender's
      -- version, also when other writes have made its own version another one
      self:RememberOwnVersion(pushed.table, pushed.version)
    end
  end
  self:NoteVersions(sender, { [pushed.table] = pushed.version }, false)
end

--------------------------------------------------------------------------------
-- The pull that a differing version asks for
--------------------------------------------------------------------------------

---Tells whether a version that a peer announced for a table holds back the own answer to a hello and the own
---periodic summary. In a protected table an officer's announcement is not held back by a member's, because a
---member is no source (plan section 14.5); another officer with the same version still holds it back.
---@param tableName string
---@param sender string
---@return boolean
function Session:HoldsBack(tableName, sender)
  return not self:IsProtected(tableName) or self:IsOfficerName(sender) or not self:IsOfficerSelf()
end

---Takes note of table versions that a peer has announced, in a hello, a summary, or a push: the peer list
---follows, a pending answer with the same version is dropped, and a version that differs from the own one
---schedules a pull. A version that a member announces for a protected table is kept with the peer, but it
---schedules no pull (plan section 14.5).
---@param sender string
---@param versions table<string, string>
---@param isComplete boolean true when the message lists all tables of the sender (a hello)
function Session:NoteVersions(sender, versions, isComplete)
  local own = self:LocalVersions()
  ---The versions that hold back what this replica would announce
  local heard = {}
  for name, version in pairs(versions) do
    if self:HoldsBack(name, sender) then
      heard[name] = version
    end
  end
  self:SuppressAnswer(heard, own)
  self:TouchPeer(sender, versions, isComplete)
  for name, version in pairs(own) do
    self:RememberOwnVersion(name, version)
    if heard[name] == version then
      -- A peer has announced the version of this replica: the next periodic summary can leave it out
      self.heardOwn[name] = version
    end
  end
  local differs = false
  for name, version in pairs(versions) do
    local merged = self.merged[name]
    if own[name] then
      if own[name] == version or (merged and merged[version]) then
        -- This replica holds all that an online peer holds: nothing in the table is out of date
        self:MarkFresh(name)
      elseif self:IsVouched(name, sender) then
        differs = true
      end
    end
  end
  if differs then
    self:ScheduleDelayedPull()
  end
end

---Counts a table version that this replica has itself as merged. The clock only grows, so the replica
---holds for ever what a table with that version holds. A peer whose last announced version is one that
---this replica has passed is then not asked: its entry in the peer list is only out of date.
---@param tableName string
---@param version string The current table version of this replica
function Session:RememberOwnVersion(tableName, version)
  local merged = self.merged[tableName]
  if not merged then
    merged = {}
    self.merged[tableName] = merged
  end
  merged[version] = true
end

---Starts the timer of a pull, when none runs: after a random time `PumpPulls` compares the versions again
---and asks a peer only when one still differs. Before discovery has ended nothing is scheduled, because
---its end starts the pulls anyway.
function Session:ScheduleDelayedPull()
  if self.delayedPullTimer or not self.discovered then
    return
  end
  self.delayedPullTimer = self.parts.after(self:RandomDelay(push.PULL_DELAY_MIN, push.PULL_DELAY_MAX), function()
    self.delayedPullTimer = nil
    self:PumpPulls()
  end)
end

--------------------------------------------------------------------------------
-- Hooks of SyncSession.lua
--------------------------------------------------------------------------------

---Stops the timers of the push. Called when the session stops. Unsent changes stay marked.
function Session:StopPush()
  for name, timer in pairs(self.pushTimers) do
    timer:Cancel()
    self.pushTimers[name] = nil
  end
  cancel(self.delayedPullTimer)
  cancel(self.summaryTimer)
  self.delayedPullTimer, self.summaryTimer = nil, nil
  self.lastPushAt, self.heardOwn, self.announced = {}, {}, {}
end
