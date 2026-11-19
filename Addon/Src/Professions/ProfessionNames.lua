local addonName, ns = ...

-- Item names for the search by material (.agents/00-plan.md, section 5.4, "Item names"): asked from the
-- client and kept in memory for the session. Nothing is saved.
--
-- A name that the client does not have at once is requested, late and spread out on purpose: at a first
-- start many addons load their data, and this one must not add a burst to that. Nothing is requested in the
-- first seconds after login, and then at most `BATCH` names every `BATCH_SECONDS`.
--
-- The client and the timer are parts of a loader, so the host tests run it (Tests/sync_profnames.lua). It
-- needs LibStub and CallbackHandler-1.0.

---@class OOOOProfessionNamesParts What a name loader is built from
---@field nameOf fun(itemId: integer): string|nil The name that the client has now; nil when it is not loaded
---@field request fun(itemId: integer) Asks the client to load an item; the answer comes to `OnAnswer`
---@field now fun(): number Seconds; only differences are used
---@field after fun(seconds: number, fn: fun()): any Calls `fn` once, later
---@field listen (fun(listening: boolean))|nil Told when the first request opens and when none is open

---@class OOOOProfessionNamesModule
---@field current OOOOProfessionNameLoader|nil The loader of the game; made by `Start`
---@field frame table|nil The event frame
local names = {}
ns.professionNames = names

---Seconds after the start (the login) in which nothing is requested
names.START_DELAY = 10
---Seconds between the first wish for a name and the first request
names.PREPARE_DELAY = 0.5
---Requests that go out together
names.BATCH = 40
---Seconds between two groups of requests
names.BATCH_SECONDS = 0.2
---Shortest time in seconds between two calls of "OnNamesChanged"
names.CHANGE_INTERVAL = 0.5
---Seconds after which a request without an answer counts as failed
names.TIMEOUT = 15

---@class OOOOProfessionNameLoader
---@field nameOf fun(itemId: integer): string|nil
---@field request fun(itemId: integer)
---@field now fun(): number
---@field after fun(seconds: number, fn: fun()): any
---@field listen (fun(listening: boolean))|nil
---@field named table<integer, string> Item id -> name
---@field failed table<integer, boolean> Item ids without a name: they are not asked again in the session
---@field waiting table<integer, boolean> Item ids in the queue, not requested yet
---@field open table<integer, number> Item id -> time of its request, while the answer is out
---@field queue integer[] Item ids to request, in the order of the wishes
---@field position integer Index of the next entry of `queue`
---@field counts { named: integer, failed: integer, waiting: integer, open: integer }
---@field earliest number Time before which nothing is requested
---@field pumpTimer boolean|nil true while the next group of requests is scheduled
---@field changeTimer boolean|nil true while "OnNamesChanged" is scheduled
---@field timeoutTimer boolean|nil true while the check for lost requests is scheduled
---@field lastChange number|nil Time of the last "OnNamesChanged"
---@field callbacks table CallbackHandler registry; fires "OnNamesChanged"
---@field RegisterCallback fun(owner: any, event: string, handler: function|string, ...: any)
---@field UnregisterCallback fun(owner: any, event: string)
local Loader = {}
Loader.__index = Loader

---Makes a name loader. Its start delay runs from now.
---@param parts OOOOProfessionNamesParts
---@return OOOOProfessionNameLoader
function names.new(parts)
  local self = setmetatable({
    nameOf = parts.nameOf,
    request = parts.request,
    now = parts.now,
    after = parts.after,
    listen = parts.listen,
    named = {},
    failed = {},
    waiting = {},
    open = {},
    queue = {},
    position = 1,
    counts = { named = 0, failed = 0, waiting = 0, open = 0 },
    earliest = parts.now() + names.START_DELAY,
  }, Loader)
  ---`loader.RegisterCallback(owner, "OnNamesChanged", function(event) end)`: names have arrived, or ids
  ---have turned out to have none. At most one call in `CHANGE_INTERVAL` seconds.
  self.callbacks = LibStub("CallbackHandler-1.0"):New(self)
  return self
end

---Schedules "OnNamesChanged", so that many answers of one moment give one call.
function Loader:NoteChanged()
  if self.changeTimer then
    return
  end
  self.changeTimer = true
  local wait = self.lastChange and (self.lastChange + names.CHANGE_INTERVAL - self.now()) or 0
  self.after(math.max(0, wait), function()
    self.changeTimer = nil
    self.lastChange = self.now()
    self.callbacks:Fire("OnNamesChanged")
  end)
end

---Keeps the name of an item.
---@param itemId integer
---@param name string
local function setNamed(self, itemId, name)
  self.named[itemId] = name
  self.counts.named = self.counts.named + 1
end

---Closes an open request and tells the listener when it was the last one.
---@param itemId integer
local function closeRequest(self, itemId)
  self.open[itemId] = nil
  self.counts.open = self.counts.open - 1
  if self.counts.open == 0 and self.listen then
    self.listen(false)
  end
end

---Marks requests without an answer as failed, so that the count of open names ends.
function Loader:CheckTimeouts()
  self.timeoutTimer = nil
  local now = self.now()
  local lost = {}
  for itemId, sentAt in pairs(self.open) do
    if now - sentAt >= names.TIMEOUT then
      lost[#lost + 1] = itemId
    end
  end
  for _, itemId in ipairs(lost) do
    closeRequest(self, itemId)
    self.failed[itemId] = true
    self.counts.failed = self.counts.failed + 1
  end
  if #lost > 0 then
    self:NoteChanged()
  end
  if self.counts.open > 0 then
    self.timeoutTimer = true
    self.after(names.TIMEOUT, function()
      self:CheckTimeouts()
    end)
  end
end

---Sends the next group of requests and schedules the one after it.
function Loader:Pump()
  local sent, changed = 0, false
  while sent < names.BATCH and self.position <= #self.queue do
    local itemId = self.queue[self.position]
    self.position = self.position + 1
    self.waiting[itemId] = nil
    self.counts.waiting = self.counts.waiting - 1
    -- The client can have loaded the item meanwhile
    local name = self.nameOf(itemId)
    if name then
      setNamed(self, itemId, name)
      changed = true
    else
      if self.counts.open == 0 and self.listen then
        self.listen(true)
      end
      self.open[itemId] = self.now()
      self.counts.open = self.counts.open + 1
      sent = sent + 1
      self.request(itemId)
    end
  end
  if changed then
    self:NoteChanged()
  end
  if self.position <= #self.queue then
    self:SchedulePump(names.BATCH_SECONDS)
  else
    self.queue, self.position = {}, 1
  end
  if self.counts.open > 0 and not self.timeoutTimer then
    self.timeoutTimer = true
    self.after(names.TIMEOUT, function()
      self:CheckTimeouts()
    end)
  end
end

---Schedules the next group of requests, not before the end of the start delay.
---@param delay number Seconds
function Loader:SchedulePump(delay)
  if self.pumpTimer then
    return
  end
  self.pumpTimer = true
  self.after(math.max(delay, self.earliest - self.now()), function()
    self.pumpTimer = nil
    self:Pump()
  end)
end

---Returns the name of an item. Without a name the item joins the queue of requests; it is never requested
---at once. The name then comes with "OnNamesChanged".
---@param itemId integer
---@return string|nil name nil while the name is not loaded, and for an item that has none
function Loader:Name(itemId)
  local name = self.named[itemId]
  if name then
    return name
  end
  if self.failed[itemId] or self.waiting[itemId] or self.open[itemId] then
    return nil
  end
  name = self.nameOf(itemId)
  if name then
    setNamed(self, itemId, name)
    return name
  end
  self.waiting[itemId] = true
  self.counts.waiting = self.counts.waiting + 1
  self.queue[#self.queue + 1] = itemId
  self:SchedulePump(names.PREPARE_DELAY)
  return nil
end

---Asks for many names, when the search window opens. The requests go out in groups (see the file comment).
---@param itemIds integer[]
function Loader:Prepare(itemIds)
  for _, itemId in ipairs(itemIds) do
    self:Name(itemId)
  end
end

---Takes the answer of the client to a request.
---@param itemId any Item id; not a secret value
---@param success any true when the item was loaded
function Loader:OnAnswer(itemId, success)
  if not self.open[itemId] then
    return
  end
  closeRequest(self, itemId)
  local name = success == true and self.nameOf(itemId) or nil
  if name then
    setNamed(self, itemId, name)
  else
    -- An id that exists without data never gets a name
    self.failed[itemId] = true
    self.counts.failed = self.counts.failed + 1
  end
  self:NoteChanged()
end

---Returns how far the loading is, for the line "Loading names: 310 of 800".
---@return integer done Ids with a name or known to have none
---@return integer total All ids that were asked for in this session
function Loader:Progress()
  local counts = self.counts
  local done = counts.named + counts.failed
  return done, done + counts.waiting + counts.open
end

---Builds the line of `/oooo sync prof names`.
---@return string
function Loader:StatusLine()
  local counts = self.counts
  return "item names: " .. counts.named .. " named, " .. counts.failed .. " failed, " .. counts.waiting
    .. " waiting, " .. counts.open .. " open"
end

--------------------------------------------------------------------------------
-- The loader of the game
--------------------------------------------------------------------------------

---Makes the loader of the game. Core.lua calls it on PLAYER_LOGIN, so that the start delay runs from the login.
function names.Start()
  if names.current then
    return
  end
  local frame = CreateFrame("Frame")
  names.frame = frame
  frame:SetScript("OnEvent", function(_frame, _event, itemId, success)
    if not issecretvalue(itemId) and not issecretvalue(success) then
      names.current:OnAnswer(itemId, success)
    end
  end)
  names.current = names.new({
    nameOf = function(itemId)
      local name = C_Item.GetItemNameByID(itemId)
      if not issecretvalue(name) and type(name) == "string" and name ~= "" then
        return name
      end
      return nil
    end,
    request = function(itemId)
      C_Item.RequestLoadItemDataByID(itemId)
    end,
    now = GetTime,
    after = C_Timer.After,
    -- The answers came with this event in every run of the probe `nameload`
    listen = function(listening)
      if listening then
        frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
      else
        frame:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
      end
    end,
  })
end
