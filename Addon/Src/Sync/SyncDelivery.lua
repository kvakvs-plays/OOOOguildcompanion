local addonName, ns = ...

-- The delivery of a member's own records of a self table to the officers (.agents/00-plan.md, section 14.6).
-- An officer cannot fetch them: it does not know which member has new ones, and a member is no source. So
-- the officer tells a member with the whisper `K` up to which id it holds the member's writes, and the member
-- pushes its own records again while an online officer holds less than its newest write. Officers do not
-- need this among themselves: an officer is a pull source.
--
-- This file also gives `IsBehind` (14.6) and the line "held by" of `/oooo sync status`. It adds its methods
-- and the handler of `K` to the session of SyncSession.lua. It uses no WoW API, so the host tests run it over
-- the fake network (Tests/sync_delivery.lua). It loads after SyncPush.lua and SyncCleanup.lua.

---@class OOOOSyncHeldOwed A `K` that an officer owes a member
---@field member string Character name of the member
---@field table string
---@field origin string The character origin of the member's writes
---@field timer OOOOSyncTimer|nil Runs until the `K` is sent; nil while it waits for the conditions

---@class OOOOSyncDeliveryState What the session knows about the delivery, for the session only
---@field held table<string, table<string, string>> Member side: table -> officer -> the id up to which that
---officer holds the own writes of the character origin
---@field repeats table<string, table<string, integer>> Member side: table -> officer -> repeated pushes for it
---@field ownPushAt table<string, number> Table -> server time of the last push of own records
---@field owed table<string, OOOOSyncHeldOwed> Officer side: member, table, and origin -> the `K` to send
---@field timer OOOOSyncTimer|nil Runs until the next check of the repeated push

---@class OOOOSyncDeliveryModule
local delivery = {}
ns.syncDelivery = delivery

local versionId = ns.versionId
---@class OOOOSyncSession
---@field delivery OOOOSyncDeliveryState|nil Made when first needed; dropped by `StopDelivery`
local Session = ns.syncSession.Session
local handlers = ns.syncSession.handlers

---Seconds between two checks of a member whether an online officer holds less than its newest own write
delivery.CHECK_INTERVAL = 120
---Most repeated pushes of a member's own records for one officer and table, per session
delivery.MAX_REPEATS = 3
---Seconds after a push of own records in which the check sends nothing: the `K` of that push is on its way
delivery.GRACE_SECONDS = 30
---Seconds between a member's push and the officer's `K`: a random value in this range
delivery.HELD_DELAY_MIN, delivery.HELD_DELAY_MAX = 1, 5

---Stops a timer when it runs.
---@param timer OOOOSyncTimer|nil
local function cancel(timer)
  if timer then
    timer:Cancel()
  end
end

---Returns the delivery state of the session, made when first needed.
---@return OOOOSyncDeliveryState
function Session:Delivery()
  local state = self.delivery
  if not state then
    state = { held = {}, repeats = {}, ownPushAt = {}, owed = {} }
    self.delivery = state
  end
  return state
end

---Lists the online officer peers: the officers whose addon has announced itself.
---@return string[] names In the arrival order of the peers
function Session:OnlineOfficers()
  local names = {}
  for _, peer in ipairs(self:PeerList()) do
    if self:IsOfficerName(peer.name) and self.parts.guild:IsOnline(peer.name) then
      names[#names + 1] = peer.name
    end
  end
  return names
end

--------------------------------------------------------------------------------
-- Officer side: the whisper `K`
--------------------------------------------------------------------------------

---Takes note, on an officer, of a member's push into a self table: for each origin of its records that name
---the sender, the officer whispers `K` after a random 1 to 5 seconds. It does so also when it held the records
---already or ignored them for a gap; the id then is its older clock value, or the zero id. One `K` is
---pending per member, table, and origin.
---@param sender string The member who pushed
---@param pushed OOOOSyncPush
function Session:OweHeld(sender, pushed)
  if not self:IsOfficerSelf() then
    return
  end
  local sync = self.parts.sync
  local origins = {}
  for _, record in ipairs(pushed.records) do
    if sync.keyName(record.key) == sender then
      origins[versionId.originOf(record.id)] = true
    end
  end
  local owed = self:Delivery().owed
  for origin in pairs(origins) do
    local key = sender .. "\0" .. pushed.table .. "\0" .. origin
    if not owed[key] then
      local entry = { member = sender, table = pushed.table, origin = origin }
      owed[key] = entry
      entry.timer = self.parts.after(self:RandomDelay(delivery.HELD_DELAY_MIN, delivery.HELD_DELAY_MAX), function()
        entry.timer = nil
        self:SendHeld(key)
      end)
    end
  end
end

---Whispers a `K` that is owed, with the clock value that the officer holds now. While the table may not send,
---it stays owed and `SendOwedHeld` sends it when the conditions change.
---@param key string
function Session:SendHeld(key)
  local state = self:Delivery()
  local entry = state.owed[key]
  if not entry or entry.timer or not self:MayTransfer(entry.table) then
    return
  end
  state.owed[key] = nil
  local tbl = self.parts.sync:GetTable(entry.table)
  if not tbl then
    return
  end
  -- A member who has gone offline gets nothing: the transport refuses the whisper
  self:Whisper("K", entry.member, "BULK", nil, entry.table, entry.origin, tbl.clock[entry.origin] or versionId.ZERO)
end

---Sends the owed `K` that waited for the conditions. Called by `OnConditionsChanged`.
function Session:SendOwedHeld()
  local owed = self.delivery and self.delivery.owed
  if not owed then
    return
  end
  local keys = {}
  for key, entry in pairs(owed) do
    if not entry.timer then
      keys[#keys + 1] = key
    end
  end
  for _, key in ipairs(keys) do
    self:SendHeld(key)
  end
end

--------------------------------------------------------------------------------
-- Member side: what the officers hold, and the repeated push
--------------------------------------------------------------------------------

---Notes up to which id an officer holds the own writes of the character origin in a self table.
---@param tableName string
---@param officer string
---@param id string
function Session:NoteHeld(tableName, officer, id)
  local held = self:Delivery().held
  held[tableName] = held[tableName] or {}
  held[tableName][officer] = id
end

---Forgets what a member knew about an officer: its hello is a new login. Called by the handler of `H`.
---@param name string
function Session:ForgetHeld(name)
  local state = self.delivery
  if not state then
    return
  end
  for _, byOfficer in pairs(state.held) do
    byOfficer[name] = nil
  end
  for _, byOfficer in pairs(state.repeats) do
    byOfficer[name] = nil
  end
end

---Takes from announced versions what an officer holds: an officer that announces the own table version of a
---self table holds every own write. Called by `NoteVersions`.
---@param sender string
---@param versions table<string, string> What the sender announced
---@param own table<string, string> The own table versions
function Session:NoteHeldVersions(sender, versions, own)
  local sync = self.parts.sync
  for name, version in pairs(versions) do
    local definition = sync.definitions[name]
    if definition and definition.writers == "self" and version == own[name] and self:PushesOwnOnly(name)
      and self:IsOfficerName(sender) then
      local tbl, origin = sync:GetTable(name), sync:OriginFor(name)
      local top = tbl and origin and tbl.clock[origin]
      if top then
        self:NoteHeld(name, sender, top)
      end
    end
  end
end

---Takes from a complete pull what its source holds: an officer whose wants do not name the own character
---origin holds every own write; otherwise it holds up to its value in the wants, and `PushWanted` pushes the
---rest at once. Called by `FinishPull` before `PushWanted`.
---@param tableName string
---@param source string
---@param wants table<string, string>
function Session:NoteHeldAfterPull(tableName, source, wants)
  if not self:PushesOwnOnly(tableName) or not self:IsOfficerName(source) then
    return
  end
  local sync = self.parts.sync
  local tbl, origin = sync:GetTable(tableName), sync:OriginFor(tableName)
  local top = tbl and origin and tbl.clock[origin]
  if top and origin then
    self:NoteHeld(tableName, source, wants[origin] or top)
  end
end

---Notes the time of a push of own records. Called by `PushLocal` and `PushWanted`.
---@param tableName string
function Session:NoteOwnPush(tableName)
  self:Delivery().ownPushAt[tableName] = self.parts.now()
end

---Pushes the own records of a self table again, from an id on, in the form of `PushLocal`: the own flag set
---and the id as base. Each officer that it is for counts one repeated push.
---@param tableName string
---@param from string The id that the receivers are expected to hold; the zero id for all own records
---@param officers string[] The officers that hold less than the newest own write
---@return boolean pushed
function Session:RepeatPush(tableName, from, officers)
  local records, origin, top = self:OwnSlice(tableName, from)
  if not origin or not top or top <= from or #records == 0 then
    return false
  end
  if not self:SendPush(tableName, records, { [origin] = from }, { [origin] = top }, true) then
    return false
  end
  self.lastPushAt[tableName] = self.parts.now()
  self:NoteOwnPush(tableName)
  self:MarkOwnPushed(tableName, top)
  local repeats = self:Delivery().repeats
  repeats[tableName] = repeats[tableName] or {}
  for _, officer in ipairs(officers) do
    repeats[tableName][officer] = (repeats[tableName][officer] or 0) + 1
  end
  return true
end

---Held: an officer tells this member up to which id it holds the member's writes of a character origin. A
---`K` from a sender that is no officer, for another origin, or for a table that is no self table is ignored.
---When the officer holds less than the newest own write, the own records after its id are pushed at once,
---when the conditions allow; otherwise the check does it later.
---@param self OOOOSyncSession
---@param sender string
---@param held OOOOSyncHeld
function handlers.K(self, sender, held)
  local sync = self.parts.sync
  local tbl, definition = sync:GetTable(held.table)
  if not tbl or not definition or definition.writers ~= "self" or not self.parts.policy:IsEnabled(held.table)
    or not self:PushesOwnOnly(held.table) or not self:IsOfficerName(sender) then
    return
  end
  local origin = sync:OriginFor(held.table)
  if held.origin ~= origin then
    return
  end
  self:TouchPeer(sender, {}, false)
  self:NoteHeld(held.table, sender, held.id)
  local top = tbl.clock[origin]
  if not top or held.id >= top then
    return
  end
  -- The officer holds all that was pushed: the push of the unsent changes, which is due, brings the rest
  if sync.dirtySince[held.table] and held.id >= self:PushMark(held.table) then
    return
  end
  local repeats = self:Delivery().repeats[held.table]
  if self:MayTransfer(held.table) and (not repeats or (repeats[sender] or 0) < delivery.MAX_REPEATS) then
    self:RepeatPush(held.table, held.id, { sender })
  end
end

---Pushes the own records of each self table again when an online officer peer holds less than the newest
---own write: from the smallest id that those officers hold (the zero id when one is unknown), at most
---`MAX_REPEATS` times per officer. A table with unsent changes or a pull that runs or is due waits: the push
---after them carries the same records.
function Session:CheckDelivery()
  local sync = self.parts.sync
  local state, now = self:Delivery(), self.parts.now()
  for _, name in ipairs(sync.names) do
    local pushedAt = state.ownPushAt[name]
    if self:PushesOwnOnly(name) and not sync.dirtySince[name] and self:MayTransfer(name)
      and not (pushedAt and now - pushedAt < delivery.GRACE_SECONDS) and not self:IsPullPending(name) then
      local tbl, origin = sync:GetTable(name), sync:OriginFor(name)
      local top = tbl and origin and tbl.clock[origin]
      if top then
        local held, repeats = state.held[name] or {}, state.repeats[name] or {}
        local from, officers = nil, {}
        for _, officer in ipairs(self:OnlineOfficers()) do
          local value = held[officer]
          if (repeats[officer] or 0) < delivery.MAX_REPEATS and (not value or value < top) then
            officers[#officers + 1] = officer
            value = value or versionId.ZERO
            if not from or value < from then
              from = value
            end
          end
        end
        if from then
          self:RepeatPush(name, from, officers)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- IsBehind and the status
--------------------------------------------------------------------------------

---Tells whether a peer of any rank has announced a version of a protected table with a greater `maxId` than
---the own one, which no online officer can supply: no online officer peer has announced a version with a
---`maxId` at least as great (the normal pull would bring that). A version that is the own one, or merged, is
---left out. A member with a modified addon can only cause a false warning.
---@param tableName string
---@return boolean
function Session:IsBehind(tableName)
  if not self:IsProtected(tableName) then
    return false
  end
  local tbl = self.parts.sync:GetTable(tableName)
  if not tbl then
    return false
  end
  local own, merged = self:LocalVersions()[tableName], self.merged[tableName]
  local newest
  for _, peer in pairs(self.peers) do
    local version = peer.versions[tableName]
    if version and version ~= own and not (merged and merged[version]) then
      local maxId = version:sub(1, versionId.LENGTH)
      if maxId > tbl.maxId and (not newest or maxId > newest) then
        newest = maxId
      end
    end
  end
  if not newest then
    return false
  end
  for _, officer in ipairs(self:OnlineOfficers()) do
    local version = self.peers[officer].versions[tableName]
    if version and version:sub(1, versionId.LENGTH) >= newest then
      return false
    end
  end
  return true
end

---Tells for `/oooo sync status` how many online officers hold the own writes of a self table.
---@param tableName string
---@return string|nil text "held by N of M officers online"; nil when the character is an officer, the table
---is no self table, or the character has no write there
function Session:HeldStatus(tableName)
  if not self:PushesOwnOnly(tableName) then
    return nil
  end
  local sync = self.parts.sync
  local tbl, origin = sync:GetTable(tableName), sync:OriginFor(tableName)
  local top = tbl and origin and tbl.clock[origin]
  if not top then
    return nil
  end
  local held = self.delivery and self.delivery.held[tableName] or {}
  local officers, holding = self:OnlineOfficers(), 0
  for _, officer in ipairs(officers) do
    if held[officer] and held[officer] >= top then
      holding = holding + 1
    end
  end
  return "held by " .. holding .. " of " .. #officers .. " officers online"
end

--------------------------------------------------------------------------------
-- Hooks of SyncSession.lua
--------------------------------------------------------------------------------

---Starts the check of the repeated push, every `CHECK_INTERVAL` seconds. Called when discovery has ended.
function Session:StartDelivery()
  local state = self:Delivery()
  if state.timer then
    return
  end
  state.timer = self.parts.after(delivery.CHECK_INTERVAL, function()
    state.timer = nil
    if self.delivery == state then
      self:CheckDelivery()
      self:StartDelivery()
    end
  end)
end

---Stops the timers of the delivery and forgets what it knew. Called when the session stops.
function Session:StopDelivery()
  local state = self.delivery
  if not state then
    return
  end
  cancel(state.timer)
  for _, entry in pairs(state.owed) do
    cancel(entry.timer)
  end
  self.delivery = nil
end
