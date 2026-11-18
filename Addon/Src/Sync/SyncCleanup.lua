local addonName, ns = ...

-- The local cleanup of the shared database (.agents/00-plan.md, section 4.4): old tombstones are removed
-- once per stay in the guild, and a table that was out of contact for too long is emptied before it is
-- pulled again. Nothing here sends a message.
--
-- This file adds its methods to the session of SyncSession.lua. It uses no WoW API, so the host tests run
-- it over the fake network (Tests/sync_cleanup.lua).

---@class OOOOSyncCleanupModule
local cleanup = {}
ns.syncCleanup = cleanup

local store = ns.syncStore
---@class OOOOSyncSession
---@field cleanedUp boolean|nil true once the cleanup of this stay in the guild has started
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
end

---Lets the cleanup run again after the next discovery. Called when the session stops.
function Session:StopCleanup()
  self.cleanedUp = false
end
