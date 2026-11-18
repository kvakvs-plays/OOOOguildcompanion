local addonName, ns = ...

-- The local cleanup of the shared database (.agents/00-plan.md, section 4.4): old tombstones and the
-- records of characters who left the guild are removed once per stay in the guild, a table that was
-- out of contact for too long is emptied before it is pulled again, and the records over the age of their
-- table are removed at the start of a stay and then once per hour. Nothing here sends a message.
--
-- This file adds its methods to the session of SyncSession.lua. It uses no WoW API, so the host tests run
-- it over the fake network (Tests/sync_cleanup.lua).

---@class OOOOSyncCleanupModule
local cleanup = {}
ns.syncCleanup = cleanup

---Seconds between two removals of the records that are older than their table keeps them (plan section 5.3)
cleanup.EXPIRE_INTERVAL = 3600

local store = ns.syncStore
---@class OOOOSyncSession
---@field cleanedUp boolean|nil true once the cleanup of this stay in the guild has started
---@field rosterCleaned boolean|nil true once the roster cleanup of this stay in the guild has started
---@field expiryTimer OOOOSyncTimer|nil Runs until the next removal of records over the age of their table
local Session = ns.syncSession.Session

---Tells whether a table was out of contact for so long that it must be emptied before its next pull.
---Until then it is no source for others: it can hold records that were deleted meanwhile.
---@param tableName string
---@return boolean
function Session:IsStale(tableName)
  local tbl = self.parts.sync:GetTable(tableName)
  return tbl ~= nil and store.isStale(tbl, self.parts.now())
end

---Notes that a table holds no record whose tombstone can be gone everywhere: it is level with a peer, has
---completed a pull, or takes its first records from others.
---@param tableName string
---@param onlyIfUnset boolean? true: only for a table that never had contact
function Session:MarkFresh(tableName, onlyIfUnset)
  local tbl = self.parts.sync:GetTable(tableName)
  if tbl and not (onlyIfUnset and (tbl.freshAt or tbl.syncedAt)) then
    tbl.freshAt = math.floor(self.parts.now())
  end
end

---Empties a table that is stale, with its clock. The versions that this session counted as held are
---forgotten with the data, so the pull that follows takes everything again.
---@param tableName string
---@return boolean emptied
function Session:ResetIfStale(tableName)
  if not self:IsStale(tableName) or not self.parts.sync:Reset(tableName) then
    return false
  end
  self.merged[tableName] = nil
  self.heardOwn[tableName] = nil
  return true
end

---Runs the cleanup once per stay in the guild, after the first completed discovery: the old tombstones of
---each table are removed, one table after the other and each cut across frames.
function Session:CleanUp()
  if self.cleanedUp then
    return
  end
  self.cleanedUp = true
  local sync = self.parts.sync
  local index = 0
  local function nextTable()
    index = index + 1
    local name = sync.names[index]
    if name then
      sync:RemoveOldTombstones(name, self.parts.after, nextTable)
    end
  end
  nextTable()
  self:CleanRoster()
end

---Removes, once per stay in the guild, the records of characters who are no longer in the guild from the
---tables that are keyed by character. A record of such a name that arrives later is not stored either
---(`CheckRecord` in SyncPull.lua), so every replica ends without it and nothing has to be sent.
---
---It runs only when the roster cache lists every member: an empty roster after login, or one with entries
---left out, must not empty the database. Until then every roster update tries again.
function Session:CleanRoster()
  local guild = self.parts.guild
  if self.rosterCleaned or not self.discovered or not guild:IsRosterComplete() or not self:IsRosterReady() then
    return
  end
  self.rosterCleaned = true
  local sync = self.parts.sync
  local index = 0
  local function nextTable()
    index = index + 1
    local name = sync.names[index]
    if not name then
      return
    end
    if sync.definitions[name].keyKind ~= "character" then
      return nextTable()
    end
    sync:Sweep(name, function(key)
      local member = sync.keyName(key)
      -- The roster can change between two steps: when it is no longer complete, nothing more is removed
      return guild:IsRosterComplete() and not (member and guild:GetMember(member))
    end, self.parts.after, nextTable)
  end
  nextTable()
end

---Removes the records that are older than their table keeps them (`maxAge`), one table after the other and
---each cut across frames, and starts the timer of the next run. The first run is at the start of a stay in
---the guild; it needs neither peers nor the roster.
function Session:ExpireTables()
  if self.expiryTimer then
    self.expiryTimer:Cancel()
  end
  self.expiryTimer = self.parts.after(cleanup.EXPIRE_INTERVAL, function()
    self.expiryTimer = nil
    self:ExpireTables()
  end)
  local sync = self.parts.sync
  local index = 0
  local function nextTable()
    index = index + 1
    local name = sync.names[index]
    if name then
      sync:Expire(name, self.parts.after, nextTable)
    end
  end
  nextTable()
end

---Lets the cleanup run again after the next discovery, and stops the expiry. Called when the session stops.
function Session:StopCleanup()
  self.cleanedUp, self.rosterCleaned = false, false
  if self.expiryTimer then
    self.expiryTimer:Cancel()
    self.expiryTimer = nil
  end
end
