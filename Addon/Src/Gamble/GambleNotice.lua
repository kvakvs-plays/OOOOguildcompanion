local addonName, ns = ...

-- The chat notices of the gambling feature (.agents/00-plan.md, section 15.7): a new open event, and the own dues
-- after a resolution. Each is printed once per event and character, with a link that opens the tab, and waits for
-- the end of combat. The pattern is the one of the mention notice (Chat/Mentions.lua).
--
-- Nothing at file scope uses the WoW API, so the host tests load this file (Tests/sync_gamblenotice.lua).

---@class OOOOGambleNoticeMark The notices of one event that one character has been told about
---@field open boolean|nil The notice of the open event was printed
---@field dues string|nil The settlement token of the resolution whose dues notice was printed

---@class OOOOGambleNoticeStore The gambling state of this account, `db.global.gamble`
---@field noticed table<string, table<string, OOOOGambleNoticeMark>> Character name -> event id -> marks

---@class OOOOGambleNoticeTimer
---@field Cancel fun(self: OOOOGambleNoticeTimer)

---@class OOOOGambleNoticeParts What the notifier needs from the game; a host test passes its own
---@field sync OOOOSync
---@field model OOOOGamble
---@field store OOOOGambleNoticeStore
---@field playerName fun(): string|nil Name of the logged-in character, as the roster shows it
---@field print fun(text: string) Prints a line in the chat frame
---@field inCombat fun(): boolean
---@field after fun(seconds: number, fn: fun()): OOOOGambleNoticeTimer Calls `fn` once, later
---@field formatTime (fun(serverTime: integer): string)|nil Day and time of a server time; default `date("%a %H:%M")`

---@class OOOOGambleNoticeModule
---@field current OOOOGambleNotifier|nil The notifier of the game, made by `Start`
local gambleNotice = {}
ns.gambleNotice = gambleNotice

---The data part of the hyperlink in the notices; the link is `addon:<addon name>:gamble`
gambleNotice.LINK = "gamble"
---Seconds for which record changes are collected before the check, so that a pull of many records gives one
gambleNotice.COLLECT_DELAY = 2
---Seconds after the start at which the check looks for what arrived while the character was offline
gambleNotice.START_DELAY = 10
---Most notices of one kind in one check; the rest become one summary line
gambleNotice.MAX_LINES = 3
---The words of the link
local LINK_WORDS = "Open the bets"

---Builds the hyperlink that opens the tab, in the colour of the mention notice.
---@return string
function gambleNotice.linkText()
  return "|cff71d5ff|Haddon:" .. addonName .. ":" .. gambleNotice.LINK .. "|h[" .. LINK_WORDS .. "]|h|r"
end

---Makes a text of another player harmless in a printed line. The model's text is sanitized already, but that
---keeps hyperlinks and colour codes; here they are dropped, so that a title cannot show a link or a colour. A
---`||` stays, and any other `|` is doubled, so no escape sequence of the text can act.
---@param text string
---@return string
local function plain(text)
  -- Control characters (a line break) are dropped; \1 then stands for `||` while the sequences are removed
  text = text:gsub("%c", "")
  if not text:find("|", 1, true) then
    return text
  end
  text = text:gsub("||", "\1")
  text = text:gsub("|H[^|]*|h", ""):gsub("|h", "")
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^|:]*:", ""):gsub("|r", "")
  text = text:gsub("|", "||")
  return (text:gsub("\1", "||"))
end

---Exported for the tests: see `plain`.
gambleNotice.plain = plain

---Returns the marks of an event of a character, nil when there are none.
---@param store OOOOGambleNoticeStore
---@param name string
---@param eventId string
---@return OOOOGambleNoticeMark|nil
local function getMark(store, name, eventId)
  local byName = store.noticed[name]
  local mark = type(byName) == "table" and byName[eventId]
  return type(mark) == "table" and mark or nil
end

---Writes a mark of an event of a character.
---@param store OOOOGambleNoticeStore
---@param name string
---@param eventId string
---@param field "open"|"dues"
---@param value boolean|string
local function setMark(store, name, eventId, field, value)
  local byName = store.noticed[name]
  if type(byName) ~= "table" then
    byName = {}
    store.noticed[name] = byName
  end
  local mark = byName[eventId]
  if type(mark) ~= "table" then
    mark = {}
    byName[eventId] = mark
  end
  mark[field] = value
end

---Builds the text of the notice of a new open event.
---@param title string Sanitized
---@param closeText string Day and time of the close
---@return string
function gambleNotice.openText(title, closeText)
  return "New bet: " .. plain(title) .. ", open until " .. closeText .. ". " .. gambleNotice.linkText()
end

---Builds the text of the notice of the own dues after a resolution: what the character gives, then what it gets.
---@param title string Sanitized
---@param ownDues OOOOGambleResultDue[] Not empty
---@return string
function gambleNotice.duesText(title, ownDues)
  local pays, receives = {}, {}
  for _, due in ipairs(ownDues) do
    local bank = due.bank and " for the guild bank" or ""
    if due.mine == "pay" then
      -- The banker owes the share of the guild bank to the bank itself
      local to = due.from ~= due.to and (" to " .. plain(due.to)) or ""
      pays[#pays + 1] = due.gold .. " gold" .. to .. bank
    else
      receives[#receives + 1] = plain(due.from) .. " gives you " .. due.gold .. " gold" .. bank
    end
  end
  local text = "Bet resolved: " .. plain(title) .. "."
  if #pays > 0 then
    text = text .. " You give " .. table.concat(pays, ", ") .. "."
  end
  if #receives > 0 then
    text = text .. " " .. table.concat(receives, ", ") .. "."
  end
  return text .. " " .. gambleNotice.linkText()
end

---Builds the summary line for notices beyond `MAX_LINES`.
---@param count integer
---@param kind "open"|"dues"
---@return string
function gambleNotice.moreText(count, kind)
  local text
  if kind == "open" then
    text = count == 1 and "1 more bet is open." or (count .. " more bets are open.")
  else
    text = count == 1 and "1 more bet was resolved with dues for you."
      or (count .. " more bets were resolved with dues for you.")
  end
  return text .. " " .. gambleNotice.linkText()
end

---@class OOOOGambleNotifier
---@field parts OOOOGambleNoticeParts
---@field timer OOOOGambleNoticeTimer|nil The timer that waits to run the check
---@field waiting boolean true when a check found the character in combat
---@field stopped boolean
local Notifier = {}
Notifier.__index = Notifier

---Makes a notifier that listens to the two gambling tables.
---@param parts OOOOGambleNoticeParts
---@return OOOOGambleNotifier
function gambleNotice.new(parts)
  if type(parts.store.noticed) ~= "table" then
    parts.store.noticed = {}
  end
  local notifier = setmetatable({ parts = parts, waiting = false, stopped = false }, Notifier)
  local tables = { [ns.gambleData.TABLE] = true, [ns.gambleData.PLAYER_TABLE] = true }
  parts.sync.RegisterCallback(notifier, "OnRecordChanged", function(_event, tableName)
    if tables[tableName] then
      notifier:CheckLater(gambleNotice.COLLECT_DELAY)
    end
  end)
  return notifier
end

---Asks for the check after `seconds`, unless a check is already waiting: one timer collects the changes.
---@param seconds number
function Notifier:CheckLater(seconds)
  if self.timer or self.stopped then
    return
  end
  self.timer = self.parts.after(seconds, function()
    self.timer = nil
    self:Check()
  end)
end

---Stops listening and cancels the timer.
function Notifier:Stop()
  self.stopped = true
  self.parts.sync.UnregisterCallback(self, "OnRecordChanged")
  if self.timer then
    self.timer:Cancel()
    self.timer = nil
  end
end

---Removes the marks of events that this replica no longer holds, so that the store does not grow for ever.
---@param held table<string, boolean> Event id -> true for every held event
function Notifier:Prune(held)
  local noticed = self.parts.store.noticed
  for name, byName in pairs(noticed) do
    if type(byName) ~= "table" then
      noticed[name] = nil
    else
      for eventId in pairs(byName) do
        if not held[eventId] then
          byName[eventId] = nil
        end
      end
      if next(byName) == nil then
        noticed[name] = nil
      end
    end
  end
end

---Prints the notices that the character has not heard yet, unless it is in combat: then the check is repeated by
---`OnCombatEnded`. A mark is set when its line is printed.
function Notifier:Check()
  local parts = self.parts
  local name = parts.playerName()
  if not name or self.stopped then
    return
  end
  if parts.inCombat() then
    self.waiting = true
    return
  end
  self.waiting = false
  local model, store = parts.model, parts.store
  local groups = model:Events()
  local held = {} ---@type table<string, boolean>
  for _, group in pairs(groups) do
    for _, entry in ipairs(group) do
      held[entry.id] = true
    end
  end
  self:Prune(held)

  local formatTime = parts.formatTime or function(time)
    return _G.date("%a %H:%M", time)
  end
  local opens, resolved = {}, {} ---@type string[], string[]
  for _, entry in ipairs(groups.open) do
    local mark = getMark(store, name, entry.id)
    if entry.event.by ~= name and not (mark and mark.open) then
      opens[#opens + 1] = entry.id
    end
  end
  local tokens = {} ---@type table<string, string>
  for _, entry in ipairs(groups.toPay) do
    local result = model:Result(entry.id)
    local token = entry.event.q
    if result and result.state == "ready" and type(token) == "string" and #result.ownDues > 0 then
      local mark = getMark(store, name, entry.id)
      local unconfirmed = false
      for _, due in ipairs(result.ownDues) do
        unconfirmed = unconfirmed or not due.confirmed
      end
      if unconfirmed and not (mark and mark.dues == token) then
        resolved[#resolved + 1] = entry.id
        tokens[entry.id] = token
      end
    end
  end

  for index, eventId in ipairs(opens) do
    if index <= gambleNotice.MAX_LINES then
      local detail = model:Detail(eventId)
      if detail and detail.state == "open" then
        parts.print(gambleNotice.openText(detail.title, formatTime(detail.close)))
      end
    end
    setMark(store, name, eventId, "open", true)
  end
  if #opens > gambleNotice.MAX_LINES then
    parts.print(gambleNotice.moreText(#opens - gambleNotice.MAX_LINES, "open"))
  end
  for index, eventId in ipairs(resolved) do
    if index <= gambleNotice.MAX_LINES then
      local detail, result = model:Detail(eventId), model:Result(eventId)
      if detail and result then
        parts.print(gambleNotice.duesText(detail.title, result.ownDues))
      end
    end
    setMark(store, name, eventId, "dues", tokens[eventId])
  end
  if #resolved > gambleNotice.MAX_LINES then
    parts.print(gambleNotice.moreText(#resolved - gambleNotice.MAX_LINES, "dues"))
  end
end

---Prints what waited for the end of combat. Called on PLAYER_REGEN_ENABLED.
function Notifier:OnCombatEnded()
  if self.waiting then
    self:Check()
  end
end

--------------------------------------------------------------------------------
-- In the game
--------------------------------------------------------------------------------

---Listens for a click on the hyperlink of the notices, which opens the gambling tab. The Mainline interface
---tells addons about a click on an `addon:` link through `EventRegistry`, event "SetItemRef".
---@return boolean usable false when the client has no such registry
function gambleNotice.RegisterLink()
  local registry = _G.EventRegistry
  if type(registry) ~= "table" or type(registry.RegisterCallback) ~= "function" then
    return false
  end
  local link = "addon:" .. addonName .. ":" .. gambleNotice.LINK
  registry:RegisterCallback("SetItemRef", function(...)
    -- The link is the first argument after the owner; its place is not relied upon
    for index = 1, select("#", ...) do
      local value = select(index, ...)
      if not issecretvalue(value) and value == link then
        ns.gambleTab:Open()
        return
      end
    end
  end, gambleNotice)
  return true
end

---Event name -> handler
---@type table<string, fun()>
local handlers = {
  PLAYER_REGEN_ENABLED = function()
    if gambleNotice.current then
      gambleNotice.current:OnCombatEnded()
    end
  end,
}

---Builds the notifier of the game as `gambleNotice.current`, registers the link, and listens for the end of
---combat. Called after login, never at file scope.
function gambleNotice.Start()
  if gambleNotice.current then
    return
  end
  local notifier = gambleNotice.new({
    sync = ns.sync,
    model = ns.gamble.current,
    store = ns.db.global.gamble,
    playerName = ns.syncCharacter.playerName,
    print = ns.print,
    inCombat = InCombatLockdown,
    after = C_Timer.NewTimer,
  })
  gambleNotice.current = notifier
  gambleNotice.RegisterLink()
  local frame = CreateFrame("Frame")
  frame:SetScript("OnEvent", function(_frame, event)
    handlers[event]()
  end)
  for event in pairs(handlers) do
    -- Registering an event that the client does not know throws
    if C_EventUtils.IsEventValid(event) then
      frame:RegisterEvent(event)
    end
  end
  -- What arrived while the character was offline
  notifier:CheckLater(gambleNotice.START_DELAY)
end
