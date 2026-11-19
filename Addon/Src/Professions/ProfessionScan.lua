local addonName, ns = ...

-- The scan of the own professions (.agents/00-plan.md, section 5.4, steps 12.3 and 12.4): it reads the
-- professions and the known recipes of the logged-in character and writes them into the table `profession`.
--
-- The client is behind a small reader (`OOOOProfessionReader`), so the rules run on the host with a stub
-- (Tests/sync_profscan.lua). Nothing at file scope uses the WoW API.

---@class OOOOProfessionEntry One profession of the character, as the client lists it
---@field id integer Skill line id
---@field level integer Skill level; 0 when the client does not show it yet
---@field max integer Highest level of the learned rank
---@field name string|nil Name in the language of the client

---@class OOOOProfessionReader What the scan asks the client. A value that is secret makes a function
---return nil, and the scan then ends without a write.
---@field readProfessions fun(): OOOOProfessionEntry[]|nil, string|nil The professions of the character; nil
---and a reason when they cannot be read. An empty list right after login is normal.
---@field isOwnWindow fun(): boolean|nil true while a profession window shows the own recipes and its data is
---ready; false for no window and for foreign data (a link, the guild, an NPC)
---@field readRecipes fun(): integer|nil, any The profession id of the open window and all its recipe ids,
---learned or not; nil and a reason when the window names no profession
---@field isLearned fun(recipeId: any): boolean|nil Whether the id is a recipe that the character knows
---@field recipeProfession fun(recipeId: integer): integer|nil, integer|nil The skill line of a recipe and its
---parent skill line; nil when the client cannot tell

---@class OOOOProfessionScanParts What a scanner is built from
---@field reader OOOOProfessionReader
---@field sync OOOOSync
---@field playerName fun(): string|nil Name of the logged-in character as the roster shows it
---@field now fun(): number Seconds; only differences are used
---@field after fun(seconds: number, fn: fun()): any Calls `fn` once, later
---@field print fun(text: string) Prints one line for the user

---@class OOOOProfessionScanModule
---@field current OOOOProfessionScanner|nil The scanner of the game; nil until the character is in the guild
---@field frame table|nil The event frame
local scan = {}
ns.professionScan = scan

local data = ns.professionData
local TABLE = data.TABLE

---Shortest time in seconds between two reads of the list of professions that events ask for
scan.READ_INTERVAL = 5
---Shortest time in seconds between two scans of the profession window
scan.SCAN_INTERVAL = 2
---Seconds between the event of the window and its scan, so that the client has filled the list
scan.SCAN_SETTLE = 0.2
---Recipes that one frame asks the client about
scan.CHUNK = 100
---Seconds between the two reads that must both lack a profession before its record is deleted
scan.UNLEARN_SECONDS = 5
---Reads of an empty list after the start that are repeated, one every `READ_INTERVAL`
scan.EMPTY_RETRIES = 6
---Seconds after which a learned recipe that the client does not show as learned yet is asked once more
scan.NEW_RECIPE_RETRY = 2

---Skill line ids of the professions that have recipes: the six crafting ones, Cooking, First Aid, Mining
scan.RECIPE_PROFESSIONS = {
  [164] = true, [165] = true, [171] = true, [197] = true, [202] = true, [333] = true,
  [185] = true, [129] = true, [186] = true,
}

---@class OOOOProfessionScanner
---@field reader OOOOProfessionReader
---@field sync OOOOSync
---@field playerName fun(): string|nil
---@field now fun(): number
---@field after fun(seconds: number, fn: fun()): any
---@field print fun(text: string)
---@field active boolean true while the character is in the guild
---@field professions table<integer, OOOOProfessionEntry>|nil The last list that was read, by skill line id
---@field names table<integer, string> Skill line id -> name of the profession, from every list read
---@field seenAny boolean true once a read has shown a profession: only then is a missing one believed
---@field missingSince table<integer, number> Skill line id -> time of the first read that lacked it
---@field lastRead number|nil Time of the last read of the list
---@field readTimer boolean|nil true while a read is scheduled
---@field emptyReads integer Reads of an empty list that were repeated
---@field lastScan number|nil Time of the last scan of the window
---@field scanPending boolean|nil true while a scan is scheduled or running
---@field scanning boolean|nil true while a scan runs across frames
---@field scanAgain boolean|nil true when the window changed while a scan ran
---@field hinted boolean|nil true once the hint about windows to open was considered in this session
---@field listStatus string What the last read of the list did, for `/oooo sync prof`
---@field scanStatus string What the last scan of the window did
---@field recipeStatus string|nil What the last learned recipe did
local Scanner = {}
Scanner.__index = Scanner
scan.Scanner = Scanner

---Makes a scanner. It does nothing until `SetActive(true)`.
---@param parts OOOOProfessionScanParts
---@return OOOOProfessionScanner
function scan.new(parts)
  return setmetatable({
    reader = parts.reader,
    sync = parts.sync,
    playerName = parts.playerName,
    now = parts.now,
    after = parts.after,
    print = parts.print,
    active = false,
    names = {},
    seenAny = false,
    missingSince = {},
    emptyReads = 0,
    listStatus = "not read in this session",
    scanStatus = "no window was scanned in this session",
  }, Scanner)
end

---Starts or stops the scanner: it works only while the character is in the guild.
---@param active boolean
function Scanner:SetActive(active)
  if self.active == active then
    return
  end
  self.active = active
  if active then
    self:ScheduleRead()
  end
end

--------------------------------------------------------------------------------
-- The list of professions
--------------------------------------------------------------------------------

---Writes the record of one profession: its levels, and the stored recipes joined with newly found ones.
---A profession whose level the client does not show yet gets no record.
---@param name string Name of the logged-in character
---@param entry OOOOProfessionEntry
---@param newIds integer[]|nil Recipe ids to add
---@return boolean|nil written As `ns.sync:Put`
---@return string|nil reason
function Scanner:WriteRecord(name, entry, newIds)
  if entry.level < 1 or entry.max < 1 then
    return nil, "no level"
  end
  local key = data.key(name, entry.id)
  local stored = self.sync:Get(TABLE, key)
  local recipes = stored and stored.r
  if newIds then
    -- A scan only adds: it can be partial, and a recipe cannot be unlearned alone
    recipes = data.mergeRecipes(recipes, newIds)
  end
  return self.sync:Put(TABLE, key, {
    l = math.min(entry.level, data.MAX_LEVEL),
    m = math.min(entry.max, data.MAX_LEVEL),
    s = stored and stored.s,
    r = recipes,
  })
end

---Deletes the records of professions that the character no longer has. One read is not believed: the record
---goes when two reads at least `UNLEARN_SECONDS` apart lack the profession.
---@param name string Name of the logged-in character
---@param present table<integer, OOOOProfessionEntry>
---@param believed boolean false for the read that was the first to show any profession: it only asks for
---another read
function Scanner:CheckUnlearned(name, present, believed)
  local now = self.now()
  ---Skill line ids with a record and without a profession; collected first, because the loop must not write
  local missing = {}
  for key in self.sync:Iterate(TABLE) do
    local owner, professionId = data.parseKey(key)
    if owner == name and professionId and not present[professionId] then
      missing[#missing + 1] = professionId
    end
  end
  for professionId in pairs(self.missingSince) do
    if present[professionId] then
      self.missingSince[professionId] = nil
    end
  end
  local again = false
  for _, professionId in ipairs(missing) do
    local since = self.missingSince[professionId]
    if believed and since and now - since >= scan.UNLEARN_SECONDS then
      self.missingSince[professionId] = nil
      self.sync:Delete(TABLE, data.key(name, professionId))
    else
      if believed then
        self.missingSince[professionId] = since or now
      end
      again = true
    end
  end
  if again then
    self:ScheduleRead(scan.UNLEARN_SECONDS + 1)
  end
end

---Tells the user once per session which profession windows to open: those of professions with recipes whose
---record has no recipe list yet. The recipes can be read only while the window is open.
---@param list OOOOProfessionEntry[]
---@param name string Name of the logged-in character
function Scanner:Hint(list, name)
  if self.hinted then
    return
  end
  self.hinted = true
  local names = {}
  for _, entry in ipairs(list) do
    if scan.RECIPE_PROFESSIONS[entry.id] and entry.level >= 1 then
      local stored = self.sync:Get(TABLE, data.key(name, entry.id))
      if not (stored and stored.r) then
        names[#names + 1] = entry.name or ("#" .. entry.id)
      end
    end
  end
  if #names == 0 then
    return
  end
  local last = table.remove(names)
  local text = #names > 0 and (table.concat(names, ", ") .. " and " .. last .. " windows") or (last .. " window")
  self.print("Open your " .. text .. " once, so that the guild can see what you craft.")
end

---Reads the list of professions and writes what changed: the levels of each profession, and the delete of
---a profession that is gone.
---@return table<integer, OOOOProfessionEntry>|nil present The professions by skill line id; nil when the
---list cannot be read
function Scanner:ReadProfessions()
  self.lastRead = self.now()
  if not self.active then
    return nil
  end
  local list, reason = self.reader.readProfessions()
  if not list then
    self.listStatus = "not readable: " .. tostring(reason)
    return nil
  end
  local name = self.playerName()
  if not name then
    self.listStatus = "the character name is not readable"
    return nil
  end
  local present = {}
  for _, entry in ipairs(list) do
    present[entry.id] = entry
    self.names[entry.id] = entry.name or self.names[entry.id]
  end
  self.professions = present
  if #list == 0 and not self.seenAny then
    -- Right after login the client can answer with nothing; that is no reason to delete a record
    self.listStatus = "the client listed no profession"
    if self.emptyReads < scan.EMPTY_RETRIES then
      self.emptyReads = self.emptyReads + 1
      self:ScheduleRead(scan.READ_INTERVAL)
    end
    return present
  end
  local believed = self.seenAny
  self.seenAny = true
  local written = 0
  for _, entry in ipairs(list) do
    if self:WriteRecord(name, entry) then
      written = written + 1
    end
  end
  self.listStatus = #list .. " professions, " .. written .. " records written"
  self:CheckUnlearned(name, present, believed)
  self:Hint(list, name)
  return present
end

---Asks for a read of the list of professions, at most one in `READ_INTERVAL` seconds.
---@param minDelay number? Seconds to wait at least
function Scanner:ScheduleRead(minDelay)
  if self.readTimer or not self.active then
    return
  end
  local wait = self.lastRead and (self.lastRead + scan.READ_INTERVAL - self.now()) or 0
  self.readTimer = true
  self.after(math.max(minDelay or 0, wait, 0), function()
    self.readTimer = nil
    self:ReadProfessions()
  end)
end

--------------------------------------------------------------------------------
-- The recipes of the open window
--------------------------------------------------------------------------------

---Ends a scan of the window with its result, and starts the scan that an event asked for meanwhile.
---@param self OOOOProfessionScanner
---@param status string
local function finishScan(self, status)
  self.scanPending, self.scanning = nil, nil
  self.scanStatus = status
  if self.scanAgain then
    self.scanAgain = nil
    self:ScheduleScan()
  end
end

---Scans the open profession window: the learned recipes of its profession are joined into the record.
---Nothing is written for a window with foreign data, for a profession that the character does not have,
---and when a value is secret. Many recipes are asked across several frames.
function Scanner:ScanWindow()
  self.lastScan = self.now()
  self.scanning = true
  if not self.active then
    return finishScan(self, "not in the guild")
  end
  local reader = self.reader
  local own = reader.isOwnWindow()
  if own == nil then
    return finishScan(self, "ended: a value of the window was secret")
  elseif not own then
    return finishScan(self, "no window with the own recipes was open")
  end
  local professionId, ids = reader.readRecipes()
  if not professionId or type(ids) ~= "table" then
    return finishScan(self, "ended: " .. tostring(ids or "the window names no profession"))
  end
  local present = self:ReadProfessions()
  local entry = present and present[professionId]
  if not entry then
    return finishScan(self, "ended: the window shows the profession " .. professionId
      .. ", which the character does not have")
  end
  local title = (entry.name or ("#" .. professionId))
  local learned, position = {}, 1
  local function step()
    local last = math.min(#ids, position + scan.CHUNK - 1)
    for index = position, last do
      local known = reader.isLearned(ids[index])
      if known == nil then
        return finishScan(self, "ended: a value of a recipe was secret")
      elseif known then
        learned[#learned + 1] = ids[index]
      end
    end
    position = last + 1
    if position <= #ids then
      self.after(0, step)
      return
    end
    if #ids > scan.CHUNK then
      -- Between the frames the window can have closed or changed to another profession
      if reader.isOwnWindow() ~= true or reader.readRecipes() ~= professionId then
        return finishScan(self, "ended: the window changed during the scan")
      end
    end
    local name = self.active and self.playerName()
    if not name then
      return finishScan(self, "ended: the character name is not readable")
    end
    local before = self.sync:Get(TABLE, data.key(name, professionId))
    local written, reason = self:WriteRecord(name, entry, learned)
    local after = self.sync:Get(TABLE, data.key(name, professionId))
    local added = data.recipeCount(after and after.r) - data.recipeCount(before and before.r)
    finishScan(self, title .. ": " .. #learned .. " of " .. #ids .. " recipes are learned, " .. added .. " new"
      .. (written == nil and (" (not written: " .. tostring(reason) .. ")") or ""))
  end
  step()
end

---Asks for a scan of the profession window, at most one in `SCAN_INTERVAL` seconds.
function Scanner:ScheduleScan()
  if not self.active then
    return
  end
  if self.scanning then
    self.scanAgain = true
    return
  end
  if self.scanPending then
    return
  end
  local wait = self.lastScan and (self.lastScan + scan.SCAN_INTERVAL - self.now()) or 0
  self.scanPending = true
  self.after(math.max(scan.SCAN_SETTLE, wait), function()
    self:ScanWindow()
  end)
end

--------------------------------------------------------------------------------
-- A learned recipe
--------------------------------------------------------------------------------

---Adds a recipe that the character has just learned, without a window. When the client cannot tell the
---profession of the recipe, the next scan of the window finds it.
---@param recipeId integer Craft spell id; not a secret value
---@param isRetry boolean? true for the second try, which is the last one
---@return boolean added
function Scanner:OnNewRecipe(recipeId, isRetry)
  if not self.active or type(recipeId) ~= "number" then
    return false
  end
  local reader = self.reader
  local known = reader.isLearned(recipeId)
  if known ~= true then
    if known == false and not isRetry then
      -- The event can come before the client shows the recipe as learned
      self.after(scan.NEW_RECIPE_RETRY, function()
        self:OnNewRecipe(recipeId, true)
      end)
    end
    self.recipeStatus = "recipe " .. recipeId .. ": the client does not show it as learned"
    return false
  end
  local professionId, parentId = reader.recipeProfession(recipeId)
  local present = self:ReadProfessions()
  local entry = present and ((professionId and present[professionId]) or (parentId and present[parentId]))
  local name = self.playerName()
  if not entry or not name then
    self.recipeStatus = "recipe " .. recipeId .. ": its profession is not known; the next scan of the window adds it"
    self:ScheduleScan()
    return false
  end
  local written, reason = self:WriteRecord(name, entry, { recipeId })
  self.recipeStatus = "recipe " .. recipeId .. " of " .. (entry.name or ("#" .. entry.id)) .. ": "
    .. (written and "added" or (written == false and "already stored" or ("not written: " .. tostring(reason))))
  return written == true
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

---Builds the lines of `/oooo sync prof`: the stored professions of the logged-in character with their
---recipe counts, and what the last read and the last scan did.
---@return string[] lines
function Scanner:StatusLines()
  local name = self.playerName()
  local lines = {}
  local own = {}
  for key, payload in self.sync:Iterate(TABLE) do
    local owner, professionId = data.parseKey(key)
    if owner == name and professionId then
      own[#own + 1] = { id = professionId, payload = payload }
    end
  end
  table.sort(own, function(left, right)
    return left.id < right.id
  end)
  lines[1] = "professions of " .. tostring(name) .. ": " .. #own .. " stored"
  for _, item in ipairs(own) do
    lines[#lines + 1] = "  " .. (self.names[item.id] or "?") .. " (" .. item.id .. "): level " .. item.payload.l
      .. "/" .. item.payload.m .. ", " .. data.recipeCount(item.payload.r) .. " recipes"
  end
  local now = self.now()
  lines[#lines + 1] = "list of professions: " .. self.listStatus
    .. (self.lastRead and string.format(" (%.0f s ago)", now - self.lastRead) or "")
  lines[#lines + 1] = "window: " .. self.scanStatus
    .. (self.lastScan and string.format(" (%.0f s ago)", now - self.lastScan) or "")
  if self.recipeStatus then
    lines[#lines + 1] = "learned: " .. self.recipeStatus
  end
  return lines
end

--------------------------------------------------------------------------------
-- The reader of the game (section 5.4: the Retail profession API; the facts are in AGENTS.md)
--------------------------------------------------------------------------------

---A plain number, or nil for a secret or another value.
---@param value any
---@return number|nil
local function plainNumber(value)
  if not issecretvalue(value) and type(value) == "number" then
    return value
  end
  return nil
end

---@type OOOOProfessionReader
scan.clientReader = {
  readProfessions = function()
    -- Five indexes, each nil without that profession
    local indexes = { GetProfessions() }
    local list = {}
    for position = 1, 5 do
      local index = indexes[position]
      if issecretvalue(index) then
        return nil, "a secret value"
      end
      if index ~= nil then
        local name, _icon, level, maximum, _abilities, _offset, skillLine = GetProfessionInfo(index)
        if issecretvalue(name) or issecretvalue(level) or issecretvalue(maximum) or issecretvalue(skillLine) then
          return nil, "a secret value"
        end
        if type(skillLine) == "number" and type(level) == "number" and type(maximum) == "number" then
          list[#list + 1] = { id = skillLine, level = level, max = maximum,
            name = type(name) == "string" and name or nil }
        end
      end
    end
    return list
  end,

  isOwnWindow = function()
    local ready = C_TradeSkillUI.IsTradeSkillReady()
    local linked = C_TradeSkillUI.IsTradeSkillLinked()
    local guild = C_TradeSkillUI.IsTradeSkillGuild()
    local npc = C_TradeSkillUI.IsNPCCrafting()
    if issecretvalue(ready) or issecretvalue(linked) or issecretvalue(guild) or issecretvalue(npc) then
      return nil
    end
    return ready == true and not linked and not guild and not npc
  end,

  readRecipes = function()
    local info = C_TradeSkillUI.GetBaseProfessionInfo()
    if issecretvalue(info) or type(info) ~= "table" then
      return nil, "the window names no profession"
    end
    local professionId = plainNumber(info.professionID)
    if not professionId or professionId < 1 then
      return nil, "the window names no profession"
    end
    local ids = C_TradeSkillUI.GetAllRecipeIDs()
    if issecretvalue(ids) or type(ids) ~= "table" then
      return nil, "the window lists no recipes"
    end
    return professionId, ids
  end,

  isLearned = function(recipeId)
    if issecretvalue(recipeId) then
      return nil
    end
    local info = C_TradeSkillUI.GetRecipeInfo(recipeId)
    if issecretvalue(info) then
      return nil
    end
    if type(info) ~= "table" then
      return false
    end
    if issecretvalue(info.learned) or issecretvalue(info.recipeID) then
      return nil
    end
    -- For an id that is no recipe the client gives a table with the recipe id 0
    return info.learned == true and info.recipeID == recipeId
  end,

  recipeProfession = function(recipeId)
    -- A Retail function that was not probed on Forever, so it is used only when it is there
    local lineOf = C_TradeSkillUI.GetTradeSkillLineForRecipe
    if type(lineOf) ~= "function" then
      return nil
    end
    local skillLine, _name, parent = lineOf(recipeId)
    return plainNumber(skillLine), plainNumber(parent)
  end,
}

--------------------------------------------------------------------------------
-- The event frame
--------------------------------------------------------------------------------

---Asks the scanner of the game for a read of the list of professions.
local function onListEvent()
  scan.current:ScheduleRead()
end

---Asks the scanner of the game for a scan of the window.
local function onWindowEvent()
  scan.current:ScheduleScan()
end

---Event name -> handler. The arguments are those of the event.
---@type table<string, fun(...: any)>
local handlers = {
  SPELLS_CHANGED = onListEvent,
  SKILL_LINES_CHANGED = onListEvent,
  TRADE_SKILL_SHOW = onWindowEvent,
  TRADE_SKILL_LIST_UPDATE = onWindowEvent,
  TRADE_SKILL_DATA_SOURCE_CHANGED = onWindowEvent,
  NEW_RECIPE_LEARNED = function(recipeId)
    if not issecretvalue(recipeId) then
      scan.current:OnNewRecipe(recipeId)
    end
  end,
}
scan.handlers = handlers

---Starts or stops the scan of the game. It runs only while the character is in the guild.
---@param listening boolean
function scan.SetListening(listening)
  if not scan.current then
    -- Without a usable database nothing can be written
    if not listening or ns.dbIsNewer then
      return
    end
    scan.current = scan.new({
      reader = scan.clientReader,
      sync = ns.sync,
      playerName = ns.syncCharacter.playerName,
      now = GetTime,
      after = C_Timer.After,
      print = ns.print,
    })
    scan.frame = CreateFrame("Frame")
    scan.frame:SetScript("OnEvent", function(_frame, event, ...)
      handlers[event](...)
    end)
  end
  for event in pairs(handlers) do
    -- Registering an event that the client does not know throws
    if C_EventUtils.IsEventValid(event) then
      if listening then
        scan.frame:RegisterEvent(event)
      else
        scan.frame:UnregisterEvent(event)
      end
    end
  end
  scan.current:SetActive(listening)
end

ns.guildState.RegisterCallback(scan, "OnGuildStateChanged", function(_event, inGuild)
  scan.SetListening(inGuild)
end)

ns.syncSlash:Register("prof", "prof [names] - the stored professions of this character and the last scan; "
  .. "names: the state of the item names", function(rest)
  if rest:lower() == "names" then
    -- ProfessionNames.lua loads after this file, so its loader is looked up at the call
    local loader = ns.professionNames and ns.professionNames.current
    ns.print(loader and loader:StatusLine() or "The item names are not started.")
    return
  end
  if not scan.current then
    ns.print("The profession scan runs only for a character in the guild.")
    return
  end
  for _, line in ipairs(scan.current:StatusLines()) do
    ns.print(line)
  end
end)
