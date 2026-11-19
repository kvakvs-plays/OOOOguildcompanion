local addonName, ns = ...

-- Probes of the profession API (.agents/00-plan.md, step 12.1). They only read and report; the scan itself
-- is in ProfessionScan.lua.
--
--   /oooo sync probe professions [label] [recipe id ...]   one report per label, see `professions` below
--   /oooo sync probe professions login                      measure at the next login when the list is filled
--   /oooo sync probe nameload <count> [spells]              how the client answers many name requests
--
-- None of the profession functions is confirmed on Forever, so each is reached through `lookup` and called
-- under pcall. Nothing at file scope uses the WoW API, so the host can load this file.

local probe = ns.syncProbe
local lookup, isSecret = probe.lookup, probe.isSecret

---@class OOOOProfessionProbe
local scan = {}
ns.professionProbe = scan

--------------------------------------------------------------------------------
-- What is probed. The names come from Retail and Classic.
--------------------------------------------------------------------------------

local FUNCTIONS = {
  "GetProfessions", "GetProfessionInfo",
  "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetFilteredRecipeIDs", "C_TradeSkillUI.GetRecipeInfo",
  "C_TradeSkillUI.GetRecipeSchematic", "C_TradeSkillUI.GetRecipeItemLink",
  "C_TradeSkillUI.GetRecipeOutputItemData", "C_TradeSkillUI.GetBaseProfessionInfo",
  "C_TradeSkillUI.GetChildProfessionInfo", "C_TradeSkillUI.GetProfessionInfoBySkillLineID",
  "C_TradeSkillUI.GetAllProfessionTradeSkillLines", "C_TradeSkillUI.GetTradeSkillDisplayName",
  "C_TradeSkillUI.IsTradeSkillReady", "C_TradeSkillUI.IsTradeSkillLinked", "C_TradeSkillUI.IsTradeSkillGuild",
  "C_TradeSkillUI.IsNPCCrafting", "C_TradeSkillUI.OpenTradeSkill",
  "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillRecipeLink",
  "GetTradeSkillNumReagents", "GetTradeSkillReagentItemLink", "GetNumCrafts", "GetCraftInfo",
  "IsPlayerSpell", "IsSpellKnown", "C_SpellBook.IsSpellKnown", "C_SpellBook.IsSpellInSpellBook",
  "C_Spell.GetSpellName", "C_Spell.DoesSpellExist", "C_Spell.RequestLoadSpellData",
  "C_Item.GetItemNameByID", "C_Item.DoesItemExistByID", "C_Item.RequestLoadItemDataByID",
  "strcmputf8i", "strlenutf8", "debugprofilestop",
}

local EVENTS = {
  "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
  "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED", "SPELLS_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE",
  "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "SPELL_DATA_LOAD_RESULT",
}

---Skill line ids of the professions (Classic data, plan 5.4)
local SKILL_LINES = { 164, 165, 171, 197, 202, 333, 185, 129, 186, 182, 393, 356 }

---Spell ids of the specializations (Classic data, plan 5.4)
local SPECIALIZATIONS = { 9788, 9787, 17039, 17040, 17041, 20219, 20222, 10656, 10658, 10660 }

---Functions that may tell whether the character knows a spell
local KNOWN_SPELL_FUNCTIONS = {
  "IsPlayerSpell", "IsSpellKnown", "C_SpellBook.IsSpellKnown", "C_SpellBook.IsSpellInSpellBook",
}

---Craft spells of three professions (Classic data: Minor Healing Potion, Rough Sharpening Stone, Mooncloth).
---A character has two primary professions, so it lacks at least one of them.
local FOREIGN_RECIPES = { 2330, 2660, 18560 }

---Windows of the professions, by the names of Retail and of Classic
local WINDOWS = { "ProfessionsFrame", "TradeSkillFrame", "CraftFrame" }

---Longest stored line; a recipe schematic of Retail is a deep table
local MAX_LINE = 3000
---Most recipes that one run asks for their info
local MAX_RECIPES = 20000

--------------------------------------------------------------------------------
-- Showing values of an unknown shape
--------------------------------------------------------------------------------

---Secret values that the current run met
local secretsSeen = 0

---Orders table keys: numbers first and by value, the rest by their text.
---@param left any
---@param right any
---@return boolean
local function keyBefore(left, right)
  local leftIsNumber, rightIsNumber = type(left) == "number", type(right) == "number"
  if leftIsNumber and rightIsNumber then
    return left < right
  end
  if leftIsNumber ~= rightIsNumber then
    return leftIsNumber
  end
  return tostring(left) < tostring(right)
end

---Text of any value, tables with their fields. A secret value is named and counted, not read.
---@param value any
---@param depth integer Levels of tables that are still opened
---@return string
local function dump(value, depth)
  if isSecret(value) then
    secretsSeen = secretsSeen + 1
    return "<secret " .. type(value) .. ">"
  end
  local kind = type(value)
  if kind == "string" then
    return "'" .. value .. "'"
  end
  if kind ~= "table" then
    return tostring(value)
  end
  if depth <= 0 then
    return "{...}"
  end
  local keys = {}
  for key in pairs(value) do
    -- A secret key cannot be sorted or shown
    if isSecret(key) then
      secretsSeen = secretsSeen + 1
    else
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, keyBefore)
  local parts = {}
  for index, key in ipairs(keys) do
    if index > 40 then
      parts[#parts + 1] = "... " .. (#keys - 40) .. " more"
      break
    end
    parts[#parts + 1] = tostring(key) .. "=" .. dump(value[key], depth - 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
scan.dump = dump

---Text of all values of a call: "'Alchemy', 75, nil".
---@param ... any
---@return string
local function values(...)
  local count = select("#", ...)
  if count == 0 then
    return "no value"
  end
  local parts = {}
  for index = 1, count do
    parts[index] = dump((select(index, ...)), 5)
  end
  return table.concat(parts, ", ")
end

---Second half of `call`: turns the results of pcall into a text, followed by the results.
---@param succeeded boolean
---@param ... any
---@return string text
---@return any ...
local function describeCall(succeeded, ...)
  if not succeeded then
    return "ERROR " .. probe.text((...))
  end
  return values(...), ...
end

---Calls a function that may not exist, under pcall.
---@param path string Dotted path of the function
---@param ... any Its arguments
---@return string text "missing", "ERROR <message>", or the values
---@return any ... The values of the call, when it succeeded
local function call(path, ...)
  local target = lookup(path)
  if type(target) ~= "function" then
    return "missing"
  end
  return describeCall(pcall(target, ...))
end

---Cuts a line to the stored length.
---@param line string
---@return string
local function clip(line)
  if #line > MAX_LINE then
    return line:sub(1, MAX_LINE) .. " ... (" .. #line .. " bytes)"
  end
  return line
end

---A plain, readable number, or nil.
---@param value any
---@return number|nil
local function plainNumber(value)
  if not isSecret(value) and type(value) == "number" then
    return value
  end
  return nil
end

--------------------------------------------------------------------------------
-- The list of professions
--------------------------------------------------------------------------------

---Reads the professions of the character in a short form, by both known ways.
---@return string summary "GetProfessions: 2 values; skill lines: 171=75/150, 182=80/150"
---@return boolean filled true when either way shows a profession
local function professionSummary()
  local filled = false
  local parts = {}
  local getProfessions = lookup("GetProfessions")
  if type(getProfessions) == "function" then
    local results = { pcall(getProfessions) }
    local present = 0
    -- Retail returns five indexes, each nil without that profession; the first value here is that of pcall
    for index = 2, 6 do
      if results[index] ~= nil then
        present = present + 1
      end
    end
    filled = present > 0
    parts[#parts + 1] = "GetProfessions: " .. (results[1] and (present .. " values") or "ERROR")
  else
    parts[#parts + 1] = "GetProfessions: missing"
  end
  local bySkillLine = lookup("C_TradeSkillUI.GetProfessionInfoBySkillLineID")
  if type(bySkillLine) == "function" then
    local levels = {}
    for _, skillLine in ipairs(SKILL_LINES) do
      local succeeded, info = pcall(bySkillLine, skillLine)
      if succeeded and not isSecret(info) and type(info) == "table" then
        local level, maximum = plainNumber(info.skillLevel), plainNumber(info.maxSkillLevel)
        if level and level > 0 then
          levels[#levels + 1] = skillLine .. "=" .. level .. "/" .. tostring(maximum)
        end
      end
    end
    filled = filled or #levels > 0
    parts[#parts + 1] = "skill lines with a level: " .. (#levels > 0 and table.concat(levels, ", ") or "none")
  else
    parts[#parts + 1] = "GetProfessionInfoBySkillLineID: missing"
  end
  return table.concat(parts, "; "), filled
end

---Reports everything that the client says about the professions of the character.
---@param out OOOOProbeReport
local function reportProfessions(out)
  local summary, filled = professionSummary()
  out:Add("professions: " .. summary .. "; filled: " .. tostring(filled))
  local getProfessions = lookup("GetProfessions")
  if type(getProfessions) == "function" then
    local results = { pcall(getProfessions) }
    out:Store("GetProfessions(): " .. call("GetProfessions"))
    for index = 2, 6 do
      if results[1] and results[index] ~= nil and not isSecret(results[index]) then
        out:Store(clip("GetProfessionInfo(" .. tostring(results[index]) .. "): "
          .. call("GetProfessionInfo", results[index])))
      end
    end
  end
  out:Store(clip("GetAllProfessionTradeSkillLines(): " .. call("C_TradeSkillUI.GetAllProfessionTradeSkillLines")))
  for _, skillLine in ipairs(SKILL_LINES) do
    out:Store(clip("skill line " .. skillLine .. ": info " .. call("C_TradeSkillUI.GetProfessionInfoBySkillLineID",
      skillLine) .. "; display name " .. call("C_TradeSkillUI.GetTradeSkillDisplayName", skillLine)))
  end
end

--------------------------------------------------------------------------------
-- The profession window and the recipes
--------------------------------------------------------------------------------

---Reports which profession window is open and what the client says about its content.
---@param out OOOOProbeReport
local function reportWindow(out)
  local shown = {}
  for _, name in ipairs(WINDOWS) do
    local frame = lookup(name)
    if type(frame) == "table" and type(frame.IsShown) == "function" then
      local succeeded, isShown = pcall(frame.IsShown, frame)
      shown[#shown + 1] = name .. " " .. (succeeded and dump(isShown, 0) or "ERROR")
    else
      shown[#shown + 1] = name .. " absent"
    end
  end
  out:Add("windows shown: " .. table.concat(shown, ", "))
  out:Add("ready " .. call("C_TradeSkillUI.IsTradeSkillReady") .. ", linked "
    .. call("C_TradeSkillUI.IsTradeSkillLinked") .. ", guild " .. call("C_TradeSkillUI.IsTradeSkillGuild")
    .. ", NPC " .. call("C_TradeSkillUI.IsNPCCrafting"))
  out:Store(clip("GetBaseProfessionInfo(): " .. call("C_TradeSkillUI.GetBaseProfessionInfo")))
  out:Store(clip("GetChildProfessionInfo(): " .. call("C_TradeSkillUI.GetChildProfessionInfo")))
end

---Reads the reagents out of a recipe schematic of the Retail shape.
---@param schematic any
---@return string|nil reagents "2589x2, 2880x1" (item id and count); nil when the shape is another one
local function schematicReagents(schematic)
  if isSecret(schematic) or type(schematic) ~= "table" then
    return nil
  end
  local slots = schematic.reagentSlotSchematics
  if isSecret(slots) or type(slots) ~= "table" then
    return nil
  end
  local parts = {}
  for _, slot in ipairs(slots) do
    if isSecret(slot) or type(slot) ~= "table" then
      return nil
    end
    local reagents = slot.reagents
    local first = not isSecret(reagents) and type(reagents) == "table" and reagents[1] or nil
    local itemId = not isSecret(first) and type(first) == "table" and plainNumber(first.itemID) or nil
    parts[#parts + 1] = tostring(itemId) .. "x" .. tostring(plainNumber(slot.quantityRequired))
  end
  return table.concat(parts, ", ")
end

---Reports what the client gives for one recipe: info, item, reagents, and name.
---@param out OOOOProbeReport
---@param recipeId integer Craft spell id
---@param title string What the recipe is in this run: "first learned recipe"
local function reportRecipe(out, recipeId, title)
  local infoText, info = call("C_TradeSkillUI.GetRecipeInfo", recipeId)
  local schematicText, schematic = call("C_TradeSkillUI.GetRecipeSchematic", recipeId, false)
  local linkText = call("C_TradeSkillUI.GetRecipeItemLink", recipeId)
  local nameText = call("C_Spell.GetSpellName", recipeId)
  local learned = (not isSecret(info) and type(info) == "table") and dump(info.learned, 0) or "?"
  out:Add(clip(title .. " " .. recipeId .. ": spell name " .. nameText .. "; learned " .. learned .. "; item link "
    .. linkText .. "; reagents " .. tostring(schematicReagents(schematic))))
  out:Store(clip("  GetRecipeInfo: " .. infoText))
  out:Store(clip("  GetRecipeSchematic: " .. schematicText))
  out:Store(clip("  GetRecipeOutputItemData: " .. call("C_TradeSkillUI.GetRecipeOutputItemData", recipeId)))
end

---Reports the recipe list of the client: how many, how many learned, and the first ones in detail.
---@param out OOOOProbeReport
local function reportRecipes(out)
  local allText, all = call("C_TradeSkillUI.GetAllRecipeIDs")
  if isSecret(all) or type(all) ~= "table" then
    out:Add("GetAllRecipeIDs(): " .. clip(allText))
  else
    local getInfo = lookup("C_TradeSkillUI.GetRecipeInfo")
    local learned, withoutInfo, firstLearned = 0, 0, nil
    if type(getInfo) == "function" then
      for index = 1, math.min(#all, MAX_RECIPES) do
        local succeeded, info = pcall(getInfo, all[index])
        if not succeeded or isSecret(info) or type(info) ~= "table" then
          withoutInfo = withoutInfo + 1
        elseif not isSecret(info.learned) and info.learned == true then
          learned = learned + 1
          firstLearned = firstLearned or all[index]
        end
      end
    end
    local _, filtered = call("C_TradeSkillUI.GetFilteredRecipeIDs")
    out:Add("GetAllRecipeIDs(): " .. #all .. " recipes, " .. learned .. " learned, " .. withoutInfo
      .. " without info; GetFilteredRecipeIDs(): "
      .. ((not isSecret(filtered) and type(filtered) == "table") and (#filtered .. " recipes") or "no table"))
    if plainNumber(all[1]) then
      reportRecipe(out, all[1], "first recipe")
    end
    if plainNumber(firstLearned) and firstLearned ~= all[1] then
      reportRecipe(out, firstLearned, "first learned recipe")
    end
  end
  -- The Classic functions read the open window by row
  out:Add("Classic: GetNumTradeSkills() " .. call("GetNumTradeSkills") .. "; GetNumCrafts() " .. call("GetNumCrafts"))
  out:Store(clip("GetTradeSkillInfo(1): " .. call("GetTradeSkillInfo", 1)))
  out:Store(clip("GetTradeSkillItemLink(1): " .. call("GetTradeSkillItemLink", 1)))
  out:Store(clip("GetTradeSkillRecipeLink(1): " .. call("GetTradeSkillRecipeLink", 1)))
  out:Store(clip("GetTradeSkillNumReagents(1): " .. call("GetTradeSkillNumReagents", 1)))
  out:Store(clip("GetTradeSkillReagentItemLink(1, 1): " .. call("GetTradeSkillReagentItemLink", 1, 1)))
  out:Store(clip("GetCraftInfo(1): " .. call("GetCraftInfo", 1)))
end

--------------------------------------------------------------------------------
-- Existence, specializations, letter case
--------------------------------------------------------------------------------

---Reports which of the functions and events exist.
---@param out OOOOProbeReport
local function reportExistence(out)
  local existing, missing = {}, {}
  for _, path in ipairs(FUNCTIONS) do
    local list = lookup(path) ~= nil and existing or missing
    list[#list + 1] = path
  end
  out:Add("exist: " .. (#existing > 0 and table.concat(existing, ", ") or "none"))
  out:Add("missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
  local isEventValid = lookup("C_EventUtils.IsEventValid")
  if type(isEventValid) ~= "function" then
    out:Add("C_EventUtils.IsEventValid is missing, so the events cannot be checked")
    return
  end
  local valid, invalid = {}, {}
  for _, event in ipairs(EVENTS) do
    local list = isEventValid(event) and valid or invalid
    list[#list + 1] = event
  end
  out:Add("valid events: " .. (#valid > 0 and table.concat(valid, ", ") or "none"))
  out:Add("invalid events: " .. (#invalid > 0 and table.concat(invalid, ", ") or "none"))
end

---Reports what the client says about each specialization spell.
---@param out OOOOProbeReport
local function reportSpecializations(out)
  local known = {}
  for _, spellId in ipairs(SPECIALIZATIONS) do
    local parts = {}
    local isKnown = false
    for _, path in ipairs(KNOWN_SPELL_FUNCTIONS) do
      local resultText, result = call(path, spellId)
      parts[#parts + 1] = path .. " " .. resultText
      isKnown = isKnown or (not isSecret(result) and result == true)
    end
    if isKnown then
      known[#known + 1] = spellId
    end
    out:Store("specialization " .. spellId .. ": name " .. call("C_Spell.GetSpellName", spellId) .. "; "
      .. table.concat(parts, ", "))
  end
  out:Add("specializations known: " .. (#known > 0 and table.concat(known, ", ") or "none"))
end

---Says what `string.lower` does with letters outside ASCII.
---@param lower fun(text: string): string
---@return string verdict
function scan.lowerVerdict(lower)
  local sample, expected = "ÄÖÜ ПРИВЕТ Æ ABC", "äöü привет æ abc"
  local lowered = lower(sample)
  if lowered == expected then
    return "string.lower handles UTF-8: '" .. lowered .. "'"
  end
  if lowered == "ÄÖÜ ПРИВЕТ Æ abc" then
    return "string.lower changes only ASCII: '" .. lowered .. "'"
  end
  return "string.lower gives another text (" .. #lowered .. " bytes for " .. #sample .. "): '" .. lowered .. "'"
end

--------------------------------------------------------------------------------
-- The probe `professions`
--------------------------------------------------------------------------------

probe.Register("professions", "professions [label] [recipe id ...] - the profession API; one stored report per "
  .. "label (before, open, closed, filter, linked); professions login - measure at the next login",
  function(report, args)
    local label, recipeIds = "run", {}
    for _, word in ipairs(args) do
      local number = tonumber(word)
      if number and number >= 1 and number == math.floor(number) then
        recipeIds[#recipeIds + 1] = number
      elseif not number then
        label = word:lower()
      end
    end
    if label == "login" then
      local global = ns.db and ns.db.global
      if global then
        global.professionLoginWatch = true
        report:Add("RESULT: armed. Log out to the character list and in again (not /reload); the report "
          .. "'professions:login' is ready 60 s after the login")
      end
      return
    end
    if #recipeIds == 0 then
      recipeIds = FOREIGN_RECIPES
    end
    -- Each label keeps its own report, so that the runs before, with, and after the window stay side by side
    local out = probe.NewReport("professions:" .. label)
    report:Add("the lines below are stored as 'professions:" .. label .. "'")
    secretsSeen = 0
    local sections = {
      reportExistence, reportProfessions, reportWindow, reportRecipes,
      function()
        for _, recipeId in ipairs(recipeIds) do
          reportRecipe(out, recipeId, "recipe by id")
        end
      end,
      reportSpecializations,
      function() out:Add(scan.lowerVerdict(string.lower)) end,
    }
    for _, section in ipairs(sections) do
      -- One failing section must not hide the others
      local succeeded, err = pcall(section, out)
      if not succeeded then
        out:Add("Lua error: " .. probe.text(err))
      end
    end
    out:Add("RESULT: " .. #out.lines .. " lines stored, " .. secretsSeen .. " secret values met")
  end)

--------------------------------------------------------------------------------
-- The watch at login: when is the list of professions first filled
--------------------------------------------------------------------------------

---Events that may tell that the professions are readable
local WATCH_EVENTS = {
  "PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "SPELLS_CHANGED", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED",
}
local WATCH_SECONDS = 60
local WATCH_INTERVAL = 0.5

---Runs the watch that `/oooo sync probe professions login` armed, once. Core.lua calls it on PLAYER_LOGIN.
function scan.StartLoginWatch()
  local global = ns.db and ns.db.global
  if not global or global.professionLoginWatch ~= true then
    return
  end
  global.professionLoginWatch = nil
  local out = probe.NewReport("professions:login")
  local start = GetTime()
  local eventCounts, watched = {}, {}
  for _, event in ipairs(WATCH_EVENTS) do
    local registered = probe.listen(event, function()
      if not eventCounts[event] then
        out:Store(string.format("%.2f s: first %s", GetTime() - start, event))
      end
      eventCounts[event] = (eventCounts[event] or 0) + 1
    end)
    if registered then
      watched[#watched + 1] = event
    end
  end
  local lastSummary, filledAt, recipesAt
  local function poll()
    local elapsed = GetTime() - start
    local summary, filled = professionSummary()
    local _, all = call("C_TradeSkillUI.GetAllRecipeIDs")
    local recipes = (not isSecret(all) and type(all) == "table") and #all or 0
    summary = summary .. "; recipe ids: " .. recipes
    if summary ~= lastSummary then
      lastSummary = summary
      out:Store(string.format("%.2f s: %s", elapsed, summary))
    end
    if filled and not filledAt then
      filledAt = elapsed
    end
    if recipes > 0 and not recipesAt then
      recipesAt = elapsed
    end
    if elapsed < WATCH_SECONDS then
      probe.later(out, WATCH_INTERVAL, poll)
      return
    end
    local counts = {}
    for _, event in ipairs(watched) do
      probe.unlisten(event)
      counts[#counts + 1] = event .. " x" .. (eventCounts[event] or 0)
    end
    out:Add("events in " .. WATCH_SECONDS .. " s: " .. table.concat(counts, ", "))
    out:Add("RESULT: professions first filled " .. (filledAt and string.format("%.2f s", filledAt) or "never")
      .. " after PLAYER_LOGIN; recipe ids first given "
      .. (recipesAt and string.format("%.2f s", recipesAt) or "never") .. " (read every " .. WATCH_INTERVAL .. " s)")
  end
  probe.later(out, 0, poll)
end

--------------------------------------------------------------------------------
-- The probe `nameload` (plan 5.4, name cache)
--------------------------------------------------------------------------------

---@class OOOONameLoadKind
---@field key string Name of the cursor in `db.global.probeCursor`
---@field first integer First id of the range
---@field last integer Last id of the range
---@field exists string Function that tells whether an id exists
---@field name string Function that gives the name of an id, nil when it is not loaded
---@field request string Function that requests the load of an id
---@field events string[] Events that may carry the answer; arguments: the id and the success

-- The ids are taken from a range of Classic ids in ascending order, not from a list of trade goods: the
-- wanted answer is how the client takes many requests, and a range gives fresh ids for every run. The
-- cursor is saved, so a run after a client restart does not repeat the ids of the run before.
---@type table<string, OOOONameLoadKind>
local NAME_KINDS = {
  items = {
    key = "items", first = 2300, last = 24000,
    exists = "C_Item.DoesItemExistByID", name = "C_Item.GetItemNameByID", request = "C_Item.RequestLoadItemDataByID",
    events = { "ITEM_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED" },
  },
  spells = {
    key = "spells", first = 2000, last = 30000,
    exists = "C_Spell.DoesSpellExist", name = "C_Spell.GetSpellName", request = "C_Spell.RequestLoadSpellData",
    events = { "SPELL_DATA_LOAD_RESULT" },
  },
}
local NAMELOAD_MAX = 2000
local NAMELOAD_SECONDS = 60
local NAMELOAD_INTERVAL = 0.5

---true while a run waits for its answers; the runs share the event handlers
local nameloadRunning = false

---true when `value` is a name: a readable string with text.
---@param value any
---@return boolean
local function isName(value)
  return not isSecret(value) and type(value) == "string" and value ~= ""
end

---Takes the next ids of a kind from the saved cursor.
---@param kind OOOONameLoadKind
---@param count integer
---@return integer[] ids Fewer than `count` when the range ends
---@return boolean checked true when the client was asked whether each id exists
local function takeIds(kind, count)
  local global = ns.db and ns.db.global
  local cursors = {}
  if global then
    global.probeCursor = global.probeCursor or {}
    cursors = global.probeCursor
  end
  local exists = lookup(kind.exists)
  local checked = type(exists) == "function"
  local id = math.max(plainNumber(cursors[kind.key]) or kind.first, kind.first)
  local ids = {}
  while #ids < count and id <= kind.last do
    local found = true
    if checked then
      local succeeded, result = pcall(exists, id)
      found = succeeded and not isSecret(result) and result == true
    end
    if found then
      ids[#ids + 1] = id
    end
    id = id + 1
  end
  cursors[kind.key] = id
  return ids, checked
end

probe.Register("nameload", "nameload <count> [spells] - ask the client for <count> item (or spell) names at once; "
  .. "on a test account, after a client restart: it may disconnect",
  function(report, args)
    local count = tonumber(args[1])
    local kind = NAME_KINDS[(args[2] or "items"):lower()]
    if not count or count < 1 or count > NAMELOAD_MAX or count ~= math.floor(count) or not kind then
      report:Add("usage: nameload <count 1 to " .. NAMELOAD_MAX .. "> [spells]")
      return
    end
    if nameloadRunning then
      report:Add("a nameload run is still waiting for its answers")
      return
    end
    local getName, request = lookup(kind.name), lookup(kind.request)
    if type(getName) ~= "function" then
      report:Add("RESULT: " .. kind.name .. " is missing")
      return
    end
    local out = probe.NewReport("nameload:" .. kind.key .. count)
    report:Add("the lines below are stored as 'nameload:" .. kind.key .. count .. "'")
    local ids, checked = takeIds(kind, count)
    if #ids == 0 then
      out:Add("RESULT: the id range is used up; delete probeCursor in the saved variables")
      return
    end
    out:Add(#ids .. " " .. kind.key .. ", ids " .. ids[1] .. " to " .. ids[#ids] .. "; existence checked with "
      .. kind.exists .. ": " .. tostring(checked))

    ---id -> true while its load is requested and not answered
    local waiting = {}
    local waitingCount, succeededCount, failedCount, unflagged, strayEvents = 0, 0, 0, 0, 0
    local start, firstAt, lastAt = GetTime(), nil, nil
    local eventCounts, watched = {}, {}
    for _, event in ipairs(kind.events) do
      eventCounts[event] = 0
      local registered = probe.listen(event, function(id, success)
        if isSecret(id) or not waiting[id] then
          strayEvents = strayEvents + 1
          return
        end
        eventCounts[event] = eventCounts[event] + 1
        waiting[id] = nil
        waitingCount = waitingCount - 1
        if not isSecret(success) and success == true then
          succeededCount = succeededCount + 1
        elseif not isSecret(success) and success == false then
          failedCount = failedCount + 1
        else
          unflagged = unflagged + 1
        end
        lastAt = GetTime() - start
        firstAt = firstAt or lastAt
      end)
      if registered then
        watched[#watched + 1] = event
      end
    end
    out:Add("listening to: " .. (#watched > 0 and table.concat(watched, ", ") or "no valid event"))

    -- Asking for the name can itself start a load, so the ids wait before the first question
    local unnamed = {}
    local stopwatch = lookup("debugprofilestop")
    local before = type(stopwatch) == "function" and stopwatch() or nil
    for _, id in ipairs(ids) do
      local succeeded, name = pcall(getName, id)
      if not (succeeded and isName(name)) then
        unnamed[#unnamed + 1] = id
        waiting[id] = true
        waitingCount = waitingCount + 1
      end
    end
    local requested = 0
    if type(request) == "function" then
      for _, id in ipairs(unnamed) do
        if pcall(request, id) then
          requested = requested + 1
        end
      end
    end
    local spent = before and string.format("%.1f ms", stopwatch() - before) or "?"
    -- Stored before the wait: after a disconnect this line is what the saved variables hold
    out:Add((#ids - #unnamed) .. " names at once, " .. #unnamed .. " without a name; " .. requested
      .. " loads requested with " .. kind.request .. " in one frame (" .. spent .. "); waiting up to "
      .. NAMELOAD_SECONDS .. " s")

    nameloadRunning = true
    local function poll()
      local elapsed = GetTime() - start
      if waitingCount > 0 and elapsed < NAMELOAD_SECONDS then
        probe.later(out, NAMELOAD_INTERVAL, poll)
        return
      end
      nameloadRunning = false
      local counts = {}
      for _, event in ipairs(watched) do
        probe.unlisten(event)
        counts[#counts + 1] = event .. " x" .. eventCounts[event]
      end
      local named = 0
      for _, id in ipairs(unnamed) do
        local succeeded, name = pcall(getName, id)
        if succeeded and isName(name) then
          named = named + 1
        end
      end
      out:Add("answers by event: " .. (#counts > 0 and table.concat(counts, ", ") or "none")
        .. "; events for other ids: " .. strayEvents)
      out:Add("loads: " .. succeededCount .. " succeeded, " .. failedCount .. " failed, " .. unflagged
        .. " without a success flag, " .. waitingCount .. " unanswered after " .. string.format("%.1f s", elapsed))
      out:Add("first answer after " .. (firstAt and string.format("%.2f s", firstAt) or "-") .. ", last after "
        .. (lastAt and string.format("%.2f s", lastAt) or "-") .. "; of the " .. #unnamed .. " without a name, "
        .. named .. " have one now")
      out:Add("RESULT: " .. #ids .. " " .. kind.key .. ": " .. (#ids - #unnamed) .. " at once, " .. named
        .. " after a load, " .. (#unnamed - named) .. " still without a name; the client stayed connected")
    end
    probe.later(out, NAMELOAD_INTERVAL, poll)
  end)
