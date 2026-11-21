local addonName, ns = ...

-- The tab "Gambling" of the addon window (.agents/00-plan.md, sections 15.4 and 15.7, step 15.1): AceGUI-3.0
-- widgets over the model of Gamble/Gamble.lua (`ns.gamble.current`). At the left the events in four groups, at
-- the right the detail of the selected event: for an open event a stake box per outcome, "Place bet", "Take
-- back", and the state of the own bet; for a locked event the same rows read-only with the booked sums; for a
-- resolved event (step 15.3) the results, the own net, the own dues with "Received", and all dues.
--
-- Refresh: changes of the two gamble tables are collected for `REFRESH_DELAY` seconds, and a slow timer
-- (`TICK`) moves the "in 2 h" text and the events whose close has passed. The list is built again on every
-- refresh. The detail is built again only when what it shows changed (`detailSignature`): the time line and
-- the state of the own bet are updated in place, so a box keeps its focus and its text while the user types,
-- also when the bet is accepted meanwhile. When the detail is built again, the typed texts of the boxes are
-- kept (`typed`) until the bet is placed or taken back, or the tab is closed.
--
-- The controls of the officers (step 15.2), shown only while `ns.sync:IsOfficer()` is true, which is asked at
-- every refresh because the roster arrives after the login: "New event" below the list opens a form in the
-- detail part, whose values live in `draft` (they survive a refresh, and also the closing of the tab, until
-- the event is opened or discarded); the form is built again only when its number of outcomes changes. Below
-- the detail of an event: "Lock now", "Resolve" with its choices in `resolveChoices`, and "Cancel event".
-- "Resolve" and "Cancel event" need a second click (`armed`), which falls back after `ARM_SECONDS`, when a
-- choice changes, and when the detail is built again.
--
-- It calls no protected function and names no frame. Only the AceGUI widgets that the other tabs use.

---@class OOOOGambleTabRow One event of the list
---@field label table AceGUI InteractiveLabel
---@field entry OOOOGambleListEntry
---@field group string Key of its group in `OOOOGambleGroups`

---@class OOOOGambleTabMessage The answer to the last click on "Place bet" or "Take back"
---@field eventId string The event that it belongs to
---@field text string
---@field error boolean|nil true for a refusal

---@class OOOOGambleDraftOutcome One outcome row of the form "New event", as typed
---@field name string
---@field chance string Chance in percent
---@field capped boolean The check box "Cap the payout"
---@field cap string The multiplier `x`

---@class OOOOGambleDraft The values of the form "New event", as typed
---@field title string
---@field outcomes OOOOGambleDraftOutcome[] 2 to `MAX_OUTCOMES` rows
---@field days string Days from now to the close
---@field hours string Hours from now to the close, added to the days
---@field minutes string Minutes from now to the close, added to the days and hours
---@field maxStake string Highest stake on one outcome
---@field problem string|nil The last refusal of "Open event", shown in the form

---@class OOOOGambleResolveChoice What an officer has chosen in the form "Resolve" of a locked event
---@field results table<integer, boolean> Outcome index -> true for "came true"
---@field banker string|nil Name of the banker; nil while the own name is not known

---@class OOOOGambleTabArmed A button that waits for its second click
---@field action "resolve"|"cancel"
---@field eventId string
---@field button table The AceGUI Button, whose text shows that it waits

---@class OOOOGambleTab
---@field model OOOOGamble|nil The gambling model; nil while the tab is not shown
---@field list table|nil AceGUI ScrollFrame with the events; nil while the tab is not shown
---@field detail table|nil AceGUI ScrollFrame with the detail of the selected event
---@field selectedId string|nil The event that the detail shows
---@field rows table<string, OOOOGambleTabRow> Event id -> its row in the list
---@field signature string|nil What the built detail shows (`detailSignature`); nil forces a rebuild
---@field boxes table[] Outcome index -> the AceGUI EditBox of the own stake (open event only)
---@field winLabels table[] Outcome index -> the label with the highest possible win under the box
---@field timeLabel table|nil The label with the close of the event, updated in place
---@field stateLabel table|nil The label with the state of the own bet, updated in place
---@field messageLabel table|nil The label with the answer to the last click, updated in place
---@field typed table<string, table<integer, string>> Event id -> outcome index -> text that the user typed
---@field message OOOOGambleTabMessage|nil
---@field token integer Counts the builds and closes, so that a timer of an earlier build does nothing
---@field refreshPending boolean|nil true while a refresh waits for its timer
---@field leftGroup table|nil AceGUI InlineGroup with the list and the officer bar
---@field detailGroup table|nil AceGUI InlineGroup around the detail part, whose title names what it shows
---@field officerBar table|nil AceGUI SimpleGroup below the list with "New event" for an officer
---@field barShown boolean|nil Whether the officer bar shows "New event"; nil until the first refresh
---@field creating boolean|nil true while the detail part shows the form "New event"
---@field draft OOOOGambleDraft|nil The values of the form "New event"; nil when none was typed
---@field formLabel table|nil The label with the last problem of the form, updated in place
---@field closeLabel table|nil The label with the typed close as day and time, updated in place
---@field previewLabel table|nil The label with the numbers of `ResolvePreview`, updated in place
---@field resolveChoices table<string, OOOOGambleResolveChoice> Event id -> the choices of its form "Resolve"
---@field armed OOOOGambleTabArmed|nil The button that waits for its second click
local tab = { rows = {}, boxes = {}, winLabels = {}, typed = {}, token = 0, resolveChoices = {} }
ns.gambleTab = tab

local AceGUI = LibStub("AceGUI-3.0")
---The constants of the gambling tables; GambleData.lua is loaded before this file
local gambleData = ns.gambleData

---Id of the tab in the addon window
local TAB_ID = "gamble"
---Width of the list at the left side
local LIST_WIDTH = 260
---Seconds for which changes of the tables are collected before the tab is refreshed
local REFRESH_DELAY = 0.5
---Seconds between two refreshes of the time texts and of the groups while the tab is shown
local TICK = 20
---Width of the text before a stake box, of the box, and of a button
local STAKE_LABEL_WIDTH, BOX_WIDTH, BUTTON_WIDTH = 80, 90, 130
---Most digits that a stake box takes: more than the highest stake (`ns.gambleData.MAX_GOLD`) has
local MAX_DIGITS = 6
---Events closer than this to now show the weekday and the time only
local NEAR_SECONDS = 6 * 86400
---Tolerance that keeps a claim of an exact whole number from falling below it before it is rounded down, as
---in GambleSettle.lua
local EPSILON = 1e-9
---Texture under the mouse on a row
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
---Background of the selected row: silver, with its alpha
local SELECTION_COLOR = { 0.75, 0.75, 0.75, 0.25 }
---Colour codes of the texts
local TITLE_COLOR, GREY, SELECTED_COLOR = "|cffffd100", "|cff808080", "|cff40ff40"
---Colour codes of a good state, of a waiting state, and of a refusal
local GOOD_COLOR, WAIT_COLOR, BAD_COLOR = "|cff40ff40", "|cffffd100", "|cffff6060"
---Width of the text before a box of the form, and of a small box (chance, cap, days, hours, minutes)
local FORM_LABEL_WIDTH, SMALL_BOX_WIDTH = 100, 50
---Width of the unit after a small box ("%", "days", "h", "min")
local UNIT_WIDTH = 40
---Width of a button of the officers, wide enough for "Click again to resolve"
local ACTION_WIDTH = 170
---Width of the check box "Cap the payout" and of the dropdown of the banker
local CAP_CHECK_WIDTH, DROPDOWN_WIDTH = 130, 220
---Most digits of a chance, a cap, days, hours, or minutes
local SMALL_DIGITS = 2
---Seconds after which a button that waits for its second click falls back
local ARM_SECONDS = 5
---Highest stake that a new form proposes
local DEFAULT_MAX_STAKE = 100
---Seconds of a day, an hour, and a minute
local DAY, HOUR, MINUTE = 86400, 3600, 60

---The groups of the list in their order, with their headings
---@type { key: string, title: string }[]
local GROUPS = {
  { key = "open", title = "Open" },
  { key = "waiting", title = "Waiting for the result" },
  { key = "toPay", title = "To pay" },
  { key = "done", title = "Done" },
}

---Why bets count only when an officer is online (15.4)
local OFFICER_NOTE = "A bet counts only when an officer with the addon is online and receives it before the "
  .. "close. Place your bet early."
---Shown in the list when no event is held
local LIST_HINT = "No event yet. An officer opens one."
---Shown in the detail part when no event is selected
local DETAIL_HINT = "Click an event to see it."
---Shown in place of the tab when `ns.gamble.current` does not exist yet
local NOT_READY = "The gambling data is not loaded yet. Open the tab again in a few seconds."

---Refusal reasons of the model and of the engine -> the line that the tab shows. `%d` is the highest stake.
---@type table<string, string>
local REFUSALS = {
  ["not ready"] = "Your character is not known yet. Try again in a few seconds.",
  ["unknown event"] = "This event is not known any more.",
  closed = "The event is closed. Bets are no longer taken.",
  resolved = "The event is resolved. Bets are no longer taken.",
  cancelled = "The event is cancelled. Bets are no longer taken.",
  ["bad stakes"] = "The stakes could not be read.",
  ["bad outcome"] = "A stake names an outcome that the event does not have.",
  ["bad stake"] = "Every stake must be a whole number of gold.",
  ["stake too high"] = "A stake is over the highest stake of %d gold.",
  ["no bet"] = "You have no bet on this event.",
  ["unknown table"] = "The gambling data is not loaded yet. Try again in a few seconds.",
  ["bad key"] = "Your character name does not fit the shared database.",
  ["not the owner"] = "The bet could not be saved under your character.",
  ["bad payload"] = "The bet does not fit the rules of the shared database.",
  ["too large"] = "The bet is too large for the shared database.",
}

---Refusal reasons of `Open`, `Lock`, `Resolve`, `Cancel`, and of the engine -> the line that the tab shows
---@type table<string, string>
local OFFICER_REFUSALS = {
  ["not an officer"] = "Only an officer can do this, and the roster does not show your character as one (yet).",
  ["not ready"] = "Your character is not known yet. Try again in a few seconds.",
  ["unknown event"] = "This event is not known any more.",
  open = "The event is still open. Lock it first.",
  closed = "The event is already closed.",
  resolved = "The event is already resolved.",
  cancelled = "The event is already cancelled.",
  ["bad results"] = "The results do not fit the outcomes of the event.",
  ["bad banker"] = "The banker must be an officer in the roster. Choose another one.",
  ["too many dues"] = "The settlement has too many payments for the shared database.",
  ["bad spec"] = "The event could not be read.",
  ["bad title"] = "The title must have 1 to 80 bytes.",
  ["bad outcomes"] = "An event needs 2 to 8 outcomes.",
  ["bad outcome"] = "Every outcome needs a name of 1 to 40 bytes and a chance from 1 to 99 percent.",
  ["bad cap"] = "A cap is allowed only for a chance under 20 percent, as a whole number from 1 to 99.",
  ["bad close"] = "The close must be after now and at most 30 days ahead.",
  ["bad stake"] = "The highest stake must be a whole number from 1 to 100000 gold.",
  ["unknown table"] = "The gambling data is not loaded yet. Try again in a few seconds.",
  ["bad key"] = "The record does not fit the keys of the shared database.",
  ["not the owner"] = "The shared database did not accept the change from your character.",
  ["bad payload"] = "The change does not fit the rules of the shared database.",
  ["too large"] = "The event is too large for the shared database. Use shorter texts.",
  booking = "Bets that arrived before the close are still being booked. Wait a moment and resolve again.",
}

---Shown at the top of the form "New event"
local FORM_NOTE = "The outcomes are independent statements: each comes true or not by itself, and the chances need "
  .. "not add up to 100. Nothing can be changed after the opening; a wrong event is cancelled and opened again."
---Shown at the top of the form "Resolve"
local RESOLVE_NOTE = "Tick every outcome that came true. The payments are computed from the bets that your addon "
  .. "holds and are not computed again; a wrong result can only be cancelled."
---Shown under the dropdown of the banker
local BANKER_NOTE = "The banker receives the share of the guild bank and puts it into the guild bank."
---Shown when `ResolvePreview` says `behind` (15.5)
local BEHIND_WARNING = "An officer who is offline may have booked bets that you lack; the result is computed from "
  .. "the bets that you hold."
---Shown under the buttons of the officers
local CANCEL_NOTE = "Cancel event: the bets stop counting, and nobody owes anything afterwards, also after a "
  .. "resolution."
---The texts of the buttons that need a second click, before the first click
local ACTION_TEXTS = { resolve = "Resolve", cancel = "Cancel event" }
---The texts of the buttons that need a second click, after the first click
local ARMED_TEXTS = { resolve = "Click again to resolve", cancel = "Click again to cancel" }

---Refusal reasons of `Confirm`, `Unconfirm`, and of the engine -> the line that the tab shows
---@type table<string, string>
local RECEIPT_REFUSALS = {
  ["not ready"] = "Your character is not known yet. Try again in a few seconds.",
  ["unknown event"] = "This event is not known any more.",
  cancelled = "The event is cancelled: nobody owes anything.",
  ["not resolved"] = "The event is not resolved yet.",
  ["unknown due"] = "This due has not arrived yet. Try again when every due of the event has arrived.",
  ["not the receiver"] = "Only the receiver of a due can confirm it.",
  ["unknown table"] = "The gambling data is not loaded yet. Try again in a few seconds.",
  ["bad key"] = "Your character name does not fit the shared database.",
  ["not the owner"] = "The confirmation could not be saved under your character.",
  ["bad payload"] = "The confirmation does not fit the rules of the shared database.",
  ["too large"] = "The confirmation is too large for the shared database.",
}

---Shown in place of the own net when the settlement did not count the own booked bet (15.5, `inSettlement`)
local NOT_IN_SETTLEMENT = "Your bet is not in the settlement: the resolving officer did not have it when the "
  .. "event was resolved. You owe nothing and win nothing."
---Shown to an officer when the book that this replica holds gives other dues than the written ones (15.5)
local MISMATCH_NOTE = "The bets that your addon holds now would give other dues than the written ones. The "
  .. "written dues are the settlement and are not computed again; a bet that reached the resolving officer "
  .. "late is not part of it."
---Shown under the dues: the addon makes no trade and no mail (15.7)
local PAYMENT_NOTE = "The addon moves no gold: trade or mail it yourself. The receiver clicks \"Received\" once "
  .. "the gold has arrived."
---Width of the button "Received" or "Done" of a due, and of the button "Undo"
local RECEIVE_WIDTH, UNDO_WIDTH = 100, 70

--------------------------------------------------------------------------------
-- Texts
--------------------------------------------------------------------------------

---Formats a server time as a day and a time: "Fri 20:00", with the date when it is not near.
---@param time integer Server time
---@param now integer Server time
---@return string
local function dayTime(time, now)
  -- The game has the global `date` (AGENTS.md); it is looked up, as in ChatHistory.lua
  local format = _G.date
  if type(format) ~= "function" then
    return "?"
  end
  if math.abs(time - now) < NEAR_SECONDS then
    return format("%a %H:%M", time)
  end
  return format("%a %d.%m %H:%M", time)
end

---Formats a span of time: "45 min", "2 h 10 min", "3 days 4 h".
---@param seconds number
---@return string
local function duration(seconds)
  if seconds < 60 then
    return "less than a minute"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. " min"
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    local rest = minutes % 60
    return hours .. " h" .. (rest > 0 and (" " .. rest .. " min") or "")
  end
  local days = math.floor(hours / 24)
  local rest = hours % 24
  return days .. (days == 1 and " day" or " days") .. (rest > 0 and (" " .. rest .. " h") or "")
end

---Builds the line with the close of an event and who opened it.
---@param detail OOOOGambleDetail
---@param now integer Server time
---@return string
local function timeText(detail, now)
  local by = "Opened by " .. detail.by .. "."
  if detail.state == "open" then
    return "Open until " .. dayTime(detail.close, now) .. " (in " .. duration(detail.close - now) .. "). " .. by
  end
  return "Closed " .. dayTime(detail.close, now) .. ". " .. by
end

---Builds the line of the second row of an event in the list.
---@param entry OOOOGambleListEntry
---@param group string Key of its group
---@param now integer Server time
---@return string
local function subline(entry, group, now)
  if group == "open" then
    return "until " .. dayTime(entry.event.c, now)
  elseif group == "waiting" then
    return "closed " .. dayTime(entry.event.c, now)
  elseif group == "toPay" then
    return "resolved, not all paid"
  elseif entry.event.s == ns.gambleData.STATE_CANCELLED then
    return "cancelled"
  end
  return "resolved, all paid"
end

---Builds the text of a row of the list: the title of the event and below it its state.
---@param model OOOOGamble
---@param row OOOOGambleTabRow
---@param selected boolean true for the event that the detail shows
---@param now integer Server time
---@return string
local function rowText(model, row, selected, now)
  return (selected and SELECTED_COLOR or TITLE_COLOR) .. model.sanitize(row.entry.event.n) .. "|r\n" .. GREY
    .. subline(row.entry, row.group, now) .. "|r"
end

---Builds the first line of an outcome: its name, its chance, the booked sum after the close, and the cap.
---@param outcome OOOOGambleDetailOutcome
---@return string
local function outcomeText(outcome)
  local text = TITLE_COLOR .. outcome.n .. "|r   " .. outcome.p .. "%"
  if outcome.booked then
    text = text .. "   booked " .. outcome.booked
  end
  if outcome.x then
    text = text .. "   " .. GREY .. "payout capped at " .. outcome.x .. " times the stake|r"
  end
  return text
end

---Lists stakes by the names of their outcomes: "30 on Nota, 10 on Other".
---@param stakes table<integer, integer>
---@param outcomes OOOOGambleDetailOutcome[]
---@return string
local function stakesText(stakes, outcomes)
  local parts = {}
  for index, outcome in ipairs(outcomes) do
    if stakes[index] then
      parts[#parts + 1] = stakes[index] .. " on " .. outcome.n
    end
  end
  return table.concat(parts, ", ")
end

---Builds the line with the state of the own bet (15.4).
---@param detail OOOOGambleDetail
---@return string
local function betStateText(detail)
  local state = detail.betState
  if state == "accepted" then
    return GOOD_COLOR .. "Accepted: an officer has booked your bet.|r"
  elseif state == "waiting" then
    return WAIT_COLOR .. "Waiting for an officer: your bet counts once an officer's addon has received it.|r"
  elseif state == "late" then
    return BAD_COLOR .. "Too late: no officer received your bet before the close, so it does not count.|r"
  elseif state == "outdated" then
    local stakes = detail.betInfo and detail.betInfo.stakes or {}
    return WAIT_COLOR .. "Your last change came too late and does not count. Your earlier accepted bet stays in "
      .. "force: " .. stakesText(stakes, detail.outcomes) .. ".|r"
  elseif state == "none" then
    return detail.state == "open" and "You have no bet on this event." or "You placed no bet on this event."
  end
  return ""
end

---Reads the text of a stake box.
---@param text string
---@param maxStake integer Highest stake of the event
---@return integer|nil stake Whole gold, 0 for an empty box; nil when the text is refused
---@return "number"|"limit"|nil problem Why the text is refused
local function parseStake(text, maxStake)
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return 0
  end
  if not trimmed:match("^%d+$") then
    return nil, "number"
  end
  local stake = tonumber(trimmed)
  if stake > maxStake then
    return nil, "limit"
  end
  return stake
end

---Builds the line under a stake box: the highest possible win of the typed stake, or why it is refused.
---@param text string Text of the box
---@param outcome OOOOGambleDetailOutcome
---@param maxStake integer
---@return string
local function winText(text, outcome, maxStake)
  local stake, problem = parseStake(text, maxStake)
  if problem == "number" then
    return BAD_COLOR .. "not a whole number of gold|r"
  elseif problem == "limit" then
    return BAD_COLOR .. "over the highest stake of " .. maxStake .. " gold|r"
  elseif not stake or stake == 0 then
    return ""
  end
  local win = math.floor(ns.gambleSettle.claim(stake, outcome) + EPSILON)
  return GREY .. "you can win up to " .. win .. " gold|r"
end

---Turns a refusal reason of the model or of the engine into a line.
---@param reason string|nil
---@param maxStake integer
---@return string
local function refusalText(reason, maxStake)
  local text = reason and REFUSALS[reason]
  if text then
    return (text:gsub("%%d", tostring(maxStake)))
  end
  return "The bet was refused (" .. tostring(reason or "unknown reason"):gsub("|", "||") .. ")."
end

---Reads the result per outcome of a resolved event, when the stored event has a valid one.
---@param model OOOOGamble
---@param eventId string
---@return boolean[]|nil
local function resultsOf(model, eventId)
  local event = model:Event(eventId)
  local results = event and event.r
  if type(results) ~= "table" then
    return nil
  end
  for index = 1, #event.o do
    if type(results[index]) ~= "boolean" then
      return nil
    end
  end
  return results
end

---Joins everything that the built detail shows, except the time line and the state of the own bet, which are
---updated in place, and the result of a resolved event (`resultSignature`). The detail is built again only when
---this changes.
---@param detail OOOOGambleDetail
---@param results boolean[]|nil Result per outcome of a resolved event
---@return string
local function detailSignature(detail, results)
  local parts = { detail.id, detail.state, detail.title, detail.by, detail.maxStake }
  for index, outcome in ipairs(detail.outcomes) do
    parts[#parts + 1] = table.concat({ outcome.n, outcome.p, outcome.x or "", outcome.booked or "",
      outcome.own or "", results and tostring(results[index]) or "" }, ",")
  end
  return table.concat(parts, "\031")
end

---Joins everything that the detail of a resolved or cancelled event shows of its result: the state, the dues
---held, the own sums, and each due with its confirmation. A receipt that arrives from another player changes it.
---@param result OOOOGambleResult|nil
---@param token string|nil Settlement token of the event
---@return string
local function resultSignature(result, token)
  if not result then
    return ""
  end
  local parts = { result.state, token or "", result.held, result.count, result.banker or "", result.net or "",
    result.bankHeld or "", tostring(result.settled), tostring(result.booked), tostring(result.inSettlement),
    tostring(result.mismatch) }
  for _, due in ipairs(result.dues) do
    parts[#parts + 1] = table.concat({ due.n, due.from, due.to, due.gold, tostring(due.bank), tostring(due.confirmed),
      due.mine or "", tostring(due.confirmable) }, ",")
  end
  return table.concat(parts, "\031")
end

---Builds the line with the own result of a resolved event: won, lost, broke even, or not in the settlement;
---empty for a character that had no part in it.
---@param result OOOOGambleResult With state "ready"
---@return string
local function ownResultText(result)
  local net = result.net or 0
  if result.inSettlement then
    if net > 0 then
      return GOOD_COLOR .. "You won " .. net .. " gold.|r"
    elseif net < 0 then
      return BAD_COLOR .. "You lost " .. -net .. " gold.|r"
    end
    return "You broke even."
  elseif result.booked then
    return WAIT_COLOR .. NOT_IN_SETTLEMENT .. "|r"
  end
  return ""
end

---Tells whether a due is the banker's own share of the guild bank: the banker pays it from the own pocket.
---@param due OOOOGambleResultDue
---@return boolean
local function isOwnPocket(due)
  return due.bank and due.from == due.to
end

---Builds the text of an own due: what the own character gives or gets, and the state of a due that it pays.
---@param due OOOOGambleResultDue With `mine` set
---@return string
local function ownDueText(due)
  local bank = due.bank and " for the guild bank" or ""
  if isOwnPocket(due) then
    return "Put " .. due.gold .. " gold into the guild bank from your own pocket"
      .. (due.confirmed and (": " .. GOOD_COLOR .. "done|r") or "")
  elseif due.confirmable then
    return due.from .. " gives you " .. due.gold .. " gold" .. bank
      .. (due.confirmed and (": " .. GOOD_COLOR .. "received|r") or "")
  end
  return "Give " .. due.gold .. " gold to " .. due.to .. bank .. ": "
    .. (due.confirmed and (GOOD_COLOR .. "confirmed by the receiver|r") or (WAIT_COLOR .. "not confirmed yet|r"))
end

---Builds the line of a due in the list of all dues: payer, receiver, gold, and its confirmation.
---@param due OOOOGambleResultDue
---@return string
local function allDueText(due)
  local text
  if isOwnPocket(due) then
    text = due.from .. " -> guild bank: " .. due.gold .. " gold (from own pocket)"
  else
    text = due.from .. " -> " .. due.to .. ": " .. due.gold .. " gold" .. (due.bank and " (guild bank)" or "")
  end
  return text .. "   " .. (due.confirmed and (GOOD_COLOR .. "confirmed|r") or (WAIT_COLOR .. "open|r"))
end

---Turns a refusal reason of `Confirm` or `Unconfirm` into a line.
---@param reason string|nil
---@return string
local function receiptRefusalText(reason)
  local text = reason and RECEIPT_REFUSALS[reason]
  if text then
    return text
  end
  return "The confirmation was refused (" .. tostring(reason or "unknown reason"):gsub("|", "||") .. ")."
end

--------------------------------------------------------------------------------
-- Texts of the officers
--------------------------------------------------------------------------------

---Turns a refusal reason of an officer's change into a line.
---@param reason string|nil
---@return string
local function officerRefusalText(reason)
  local text = reason and OFFICER_REFUSALS[reason]
  if text then
    return text
  end
  return "The change was refused (" .. tostring(reason or "unknown reason"):gsub("|", "||") .. ")."
end

---Removes the spaces at both ends of a text.
---@param text string
---@return string
local function trim(text)
  return (text:match("^%s*(.-)%s*$"))
end

---Reads a whole number from a box.
---@param text string
---@param low integer
---@param high integer
---@param empty integer|nil What an empty box means; nil refuses an empty box
---@return integer|nil value nil when the text is refused
local function parseWhole(text, low, high, empty)
  local trimmed = trim(text)
  if trimmed == "" then
    return empty
  end
  -- More digits than any limit has would only make a huge number
  if not trimmed:match("^%d+$") or #trimmed > 9 then
    return nil
  end
  local value = tonumber(trimmed)
  if value < low or value > high then
    return nil
  end
  return value
end

---Makes an empty outcome row of the form "New event".
---@return OOOOGambleDraftOutcome
local function newDraftOutcome()
  return { name = "", chance = "", capped = false, cap = "" }
end

---Makes the values of an empty form "New event", with two outcome rows.
---@return OOOOGambleDraft
local function newDraft()
  return { title = "", outcomes = { newDraftOutcome(), newDraftOutcome() }, days = "", hours = "", minutes = "",
    maxStake = tostring(DEFAULT_MAX_STAKE) }
end

---Reads the typed chance of an outcome row when it allows a cap: 1 to `CAP_BELOW - 1`.
---@param outcome OOOOGambleDraftOutcome
---@return integer|nil chance nil when the row shows no cap
local function capChance(outcome)
  local chance = parseWhole(outcome.chance, 1, 99)
  if chance and chance < gambleData.CAP_BELOW then
    return chance
  end
  return nil
end

---Builds the hint under the cap of an outcome row: what the cap means, with the uncapped multiple.
---@param outcome OOOOGambleDraftOutcome
---@return string
local function capHint(outcome)
  local chance = capChance(outcome)
  if not chance then
    return ""
  end
  local uncapped = math.floor((100 - chance) / chance)
  if not outcome.capped then
    return GREY .. "Uncapped, a winning stake wins about " .. uncapped .. " times the stake.|r"
  end
  local cap = parseWhole(outcome.cap, 1, gambleData.MAX_CAP)
  if not cap then
    return BAD_COLOR .. "Type the multiplier: a whole number from 1 to " .. gambleData.MAX_CAP .. ".|r"
  end
  local text = "A winning stake wins at most " .. cap .. " times the stake; uncapped it would be about " .. uncapped
    .. " times."
  -- The claim is stake * (100 - p) / p; a cap at or above that changes nothing (15.3)
  if cap * chance >= 100 - chance then
    text = text .. " This cap changes nothing."
  end
  return GREY .. text .. "|r"
end

---Reads the typed time from now to the close.
---@param draft OOOOGambleDraft
---@return integer|nil span Seconds; nil when refused
---@return string|nil problem Why it is refused
local function closeSpan(draft)
  local maxDays = math.floor(gambleData.MAX_CLOSE_AHEAD / DAY)
  local days = parseWhole(draft.days, 0, maxDays, 0)
  if not days then
    return nil, "The days must be a whole number from 0 to " .. maxDays .. "."
  end
  local hours = parseWhole(draft.hours, 0, 23, 0)
  if not hours then
    return nil, "The hours must be a whole number from 0 to 23."
  end
  local minutes = parseWhole(draft.minutes, 0, 59, 0)
  if not minutes then
    return nil, "The minutes must be a whole number from 0 to 59."
  end
  local span = days * DAY + hours * HOUR + minutes * MINUTE
  if span < MINUTE then
    return nil, "The close must be at least one minute from now."
  elseif span > gambleData.MAX_CLOSE_AHEAD then
    return nil, "The close can be at most " .. maxDays .. " days from now."
  end
  return span
end

---Builds the line under the boxes of the close: the resulting day and time, or why the boxes are refused.
---@param draft OOOOGambleDraft
---@param now integer Server time
---@return string
local function closeText(draft, now)
  if trim(draft.days) == "" and trim(draft.hours) == "" and trim(draft.minutes) == "" then
    return GREY .. "Type in how many days, hours, and minutes from now the bets close.|r"
  end
  local span, problem = closeSpan(draft)
  if not span then
    return BAD_COLOR .. problem .. "|r"
  end
  return GREY .. "Bets close " .. dayTime(now + span, now) .. " (in " .. duration(span) .. ").|r"
end

---Reads the form "New event" into the spec of `Open`.
---@param draft OOOOGambleDraft
---@param now integer Server time
---@return OOOOGambleSpec|nil spec nil when a box is refused
---@return string|nil problem The line that tells which box is refused
local function readDraft(draft, now)
  local title = trim(draft.title)
  if title == "" then
    return nil, "Type a title."
  elseif #title > gambleData.MAX_TITLE then
    return nil, "The title is too long: at most " .. gambleData.MAX_TITLE .. " bytes (a letter like ä takes 2)."
  end
  local outcomes = {}
  for index, row in ipairs(draft.outcomes) do
    local name = trim(row.name)
    if name == "" then
      return nil, "Type a name for outcome " .. index .. "."
    elseif #name > gambleData.MAX_OUTCOME_NAME then
      return nil, "The name of outcome " .. index .. " is too long: at most " .. gambleData.MAX_OUTCOME_NAME
        .. " bytes."
    end
    local chance = parseWhole(row.chance, 1, 99)
    if not chance then
      return nil, "The chance of outcome " .. index .. " must be a whole number from 1 to 99 percent."
    end
    local cap
    if row.capped and chance < gambleData.CAP_BELOW then
      cap = parseWhole(row.cap, 1, gambleData.MAX_CAP)
      if not cap then
        return nil, "The cap of outcome " .. index .. " must be a whole number from 1 to " .. gambleData.MAX_CAP
          .. ", or clear its check box."
      end
    end
    outcomes[index] = { n = name, p = chance, x = cap }
  end
  if #outcomes < gambleData.MIN_OUTCOMES or #outcomes > gambleData.MAX_OUTCOMES then
    return nil, OFFICER_REFUSALS["bad outcomes"]
  end
  local span, problem = closeSpan(draft)
  if not span then
    return nil, problem
  end
  local maxStake = parseWhole(draft.maxStake, 1, gambleData.MAX_GOLD)
  if not maxStake then
    return nil, "The highest stake must be a whole number from 1 to " .. gambleData.MAX_GOLD .. " gold."
  end
  return { title = title, outcomes = outcomes, close = now + span, maxStake = maxStake }
end

---Seconds until the preview allows resolving; 0 when it does, and when the model gives no `wait`.
---@param preview (OOOOGamblePreview|{ wait: number|nil })|nil
---@return number
local function previewWait(preview)
  local wait = preview and preview.wait
  return type(wait) == "number" and wait > 0 and wait or 0
end

---Builds the line with the numbers of `ResolvePreview`, the wait for the booking, and the warning of 15.5.
---@param preview OOOOGamblePreview|nil
---@return string
local function previewText(preview)
  if not preview then
    return ""
  end
  local text = preview.bets .. (preview.bets == 1 and " valid bet, " or " valid bets, ") .. preview.sum
    .. " gold in total."
  local wait = previewWait(preview)
  if wait > 0 then
    text = text .. "\n" .. WAIT_COLOR .. "You can resolve in " .. math.ceil(wait)
      .. " s: bets that arrived before the close are still being booked.|r"
  end
  if preview.behind then
    text = text .. "\n" .. BAD_COLOR .. BEHIND_WARNING .. "|r"
  end
  return text
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

---Sets the text of a label when it differs from the shown one.
---@param label table|nil AceGUI Label
---@param text string
---@return boolean changed
local function setText(label, text)
  if not label or label:GetUserData("text") == text then
    return false
  end
  label:SetUserData("text", text)
  label:SetText(text)
  return true
end

---Adds a label as wide as its container.
---@param container table AceGUI container
---@param text string
---@param grey boolean|nil true for a hint
---@return table label
local function addLabel(container, text, grey)
  local label = AceGUI:Create("Label")
  label:SetFullWidth(true)
  label:SetFontObject(grey and GameFontDisable or GameFontHighlight)
  setText(label, text)
  container:AddChild(label)
  return label
end

---Makes a label for a line of the layout "OOOOLine".
---@param text string
---@param width number|nil Fixed width; nil takes what the line leaves
---@return table label
local function lineLabel(text, width)
  local label = AceGUI:Create("Label")
  label:SetFontObject(GameFontHighlight)
  if width then
    label:SetUserData("width", width)
  end
  setText(label, text)
  return label
end

---Adds a line whose children stand side by side (layout "OOOOLine" of MainWindow.lua).
---@param container table
---@return table line AceGUI SimpleGroup
local function addLine(container)
  local line = AceGUI:Create("SimpleGroup")
  line:SetFullWidth(true)
  line:SetLayout("OOOOLine")
  container:AddChild(line)
  return line
end

---Makes a button for a line of the layout "OOOOLine".
---@param text string
---@param width number
---@param onClick fun(widget: table) Called with the AceGUI Button
---@return table button AceGUI Button
local function makeButton(text, width, onClick)
  local button = AceGUI:Create("Button")
  button:SetText(text)
  button:SetUserData("width", width)
  button:SetCallback("OnClick", function(widget)
    onClick(widget)
  end)
  return button
end

---Makes a box of the forms for a line of the layout "OOOOLine". Its text goes to `onChange` as it is typed.
---@param text string The typed text to show
---@param width number|nil Fixed width; nil takes what the line leaves
---@param maxLetters integer
---@param onChange fun(value: string)
---@return table box AceGUI EditBox
local function formBox(text, width, maxLetters, onChange)
  local box = AceGUI:Create("EditBox")
  if width then
    box:SetUserData("width", width)
  end
  -- The buttons of the form act on every box, so a box needs no button of its own
  box:DisableButton(true)
  box:SetMaxLetters(maxLetters)
  box:SetText(text)
  box:SetCallback("OnTextChanged", function(_widget, _event, value)
    onChange(value)
  end)
  box:SetCallback("OnEnterPressed", function(widget)
    widget:ClearFocus()
  end)
  return box
end

---Adds a heading as wide as its container.
---@param container table
---@param text string
local function addHeading(container, text)
  local heading = AceGUI:Create("Heading")
  heading:SetText(text)
  heading:SetFullWidth(true)
  container:AddChild(heading)
end

---Hides the background of a row when AceGUI takes the row back.
---@param label table AceGUI InteractiveLabel
local function hideSelection(label)
  label.frame.ooooSelection:Hide()
end

---Shows or hides the silver background of a row. AceGUI keeps the frame of a released label for the next
---label of any window, so the texture is made once per frame and hidden when the row is released.
---@param label table AceGUI InteractiveLabel
---@param selected boolean
local function setSelection(label, selected)
  local frame = label.frame
  local selection = frame.ooooSelection
  if not selection then
    if not selected then
      return
    end
    selection = frame:CreateTexture(nil, "BACKGROUND")
    selection:SetAllPoints(frame)
    selection:SetColorTexture(SELECTION_COLOR[1], SELECTION_COLOR[2], SELECTION_COLOR[3], SELECTION_COLOR[4])
    frame.ooooSelection = selection
  end
  selection:SetShown(selected)
  label:SetCallback("OnRelease", hideSelection)
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

---Selects the newest open event, or else the newest one waiting for the result, when no held event is
---selected.
---@param groups OOOOGambleGroups
function tab:EnsureSelection(groups)
  if self.selectedId and self.model:Event(self.selectedId) then
    return
  end
  local first = groups.open[1] or groups.waiting[1]
  self.selectedId = first and first.id or nil
  self.message = nil
end

---Builds the list of events again.
---@param groups OOOOGambleGroups
---@param now integer Server time
function tab:UpdateList(groups, now)
  local scroll = self.list
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.rows = {}
  local count = 0
  for _, group in ipairs(GROUPS) do
    local entries = groups[group.key]
    if #entries > 0 then
      local heading = AceGUI:Create("Heading")
      heading:SetText(group.title)
      heading:SetFullWidth(true)
      scroll:AddChild(heading)
      for _, entry in ipairs(entries) do
        -- While the form "New event" is shown, no row is marked
        local selected = entry.id == self.selectedId and not self.creating
        local label = AceGUI:Create("InteractiveLabel")
        label:SetFullWidth(true)
        label:SetFontObject(GameFontHighlight)
        local row = { label = label, entry = entry, group = group.key }
        label:SetText(rowText(self.model, row, selected, now))
        label:SetHighlight(ROW_HIGHLIGHT)
        setSelection(label, selected)
        local id = entry.id
        label:SetCallback("OnClick", function()
          tab:OnRowClick(id)
        end)
        self.rows[id] = row
        scroll:AddChild(label)
        count = count + 1
      end
    end
  end
  if count == 0 then
    addLabel(scroll, LIST_HINT, true)
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
  ns.mainWindow:SetStatus(#groups.open .. " open, " .. #groups.waiting .. " waiting for the result, "
    .. #groups.toPay .. " to pay.")
end

---Handles a click on a row: selects its event, and leaves the form "New event" (its values stay). Only the
---texts of the rows change, because the clicked row is not released inside its own click.
---@param id string Event id
function tab:OnRowClick(id)
  if not self.list or (id == self.selectedId and not self.creating) then
    return
  end
  local previous = self.selectedId
  self.selectedId = id
  self.creating = false
  self.message = nil
  local now = self.model.now()
  for rowId, row in pairs(self.rows) do
    if rowId == previous or rowId == id then
      row.label:SetText(rowText(self.model, row, rowId == id, now))
      setSelection(row.label, rowId == id)
    end
  end
  self:UpdateDetail(true)
end

---Shows "New event" below the list when the logged-in character is an officer, and hides it otherwise.
---@param officer boolean
function tab:UpdateOfficerBar(officer)
  local bar = self.officerBar
  if not bar or self.barShown == officer then
    return
  end
  self.barShown = officer
  bar:ReleaseChildren()
  if officer then
    bar:AddChild(makeButton("New event", BUTTON_WIDTH, function()
      tab:StartNewEvent()
    end))
  end
  self.leftGroup:DoLayout()
end

---Shows the form "New event" in the detail part, with the values typed before. The mark of the selected row
---is taken away; the selection stays for the time after the form.
function tab:StartNewEvent()
  if not self.detail or not ns.sync:IsOfficer() then
    return
  end
  self.draft = self.draft or newDraft()
  self.creating = true
  local row = self.selectedId and self.rows[self.selectedId]
  if row then
    row.label:SetText(rowText(self.model, row, false, self.model.now()))
    setSelection(row.label, false)
  end
  self:UpdateDetail(true)
end

--------------------------------------------------------------------------------
-- The detail part
--------------------------------------------------------------------------------

---Builds the line of the last answer to a click, when it belongs to an event.
---@param eventId string
---@return string
function tab:MessageText(eventId)
  local message = self.message
  if not message or message.eventId ~= eventId then
    return ""
  end
  return (message.error and BAD_COLOR or GOOD_COLOR) .. message.text .. "|r"
end

---Shows the answer to a click in the detail part.
---@param eventId string
---@param text string
---@param isError boolean
function tab:ShowMessage(eventId, text, isError)
  self.message = { eventId = eventId, text = text, error = isError }
  if setText(self.messageLabel, self:MessageText(eventId)) and self.detail then
    self.detail:DoLayout()
  end
end

---Adds the title and the time line of an event.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:AddHeader(scroll, detail)
  addLabel(scroll, TITLE_COLOR .. detail.title .. "|r")
  self.timeLabel = addLabel(scroll, timeText(detail, self.model.now()))
end

---Adds the state of the own bet and the line of the last answer.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:AddStateLines(scroll, detail)
  self.stateLabel = addLabel(scroll, betStateText(detail))
  self.messageLabel = addLabel(scroll, self:MessageText(detail.id))
end

---Adds the rows of an open event: per outcome its line, a box with the own stake, and the highest possible
---win of the typed stake; then the buttons and the state of the own bet.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildOpen(scroll, detail)
  addLabel(scroll, "Highest stake: " .. detail.maxStake .. " gold on each outcome. " .. OFFICER_NOTE, true)
  local typed = self.typed[detail.id]
  for index, outcome in ipairs(detail.outcomes) do
    addLabel(scroll, outcomeText(outcome))
    local line = addLine(scroll)
    line:AddChild(lineLabel("Your stake", STAKE_LABEL_WIDTH))
    local text = typed and typed[index] or (outcome.own and tostring(outcome.own)) or ""
    local box = AceGUI:Create("EditBox")
    box:SetUserData("width", BOX_WIDTH)
    -- The buttons below place the bet, so the box needs no button of its own
    box:DisableButton(true)
    box:SetMaxLetters(MAX_DIGITS)
    box:SetText(text)
    local win = lineLabel(winText(text, outcome, detail.maxStake))
    local eventId, maxStake = detail.id, detail.maxStake
    box:SetCallback("OnTextChanged", function(_widget, _event, value)
      tab.typed[eventId] = tab.typed[eventId] or {}
      tab.typed[eventId][index] = value
      -- A long text wraps and grows the label: lay the line and the detail out again, keeping the box
      if setText(win, winText(value, outcome, maxStake)) then
        line:DoLayout()
        if tab.detail then
          tab.detail:DoLayout()
        end
      end
    end)
    box:SetCallback("OnEnterPressed", function(widget)
      widget:ClearFocus()
    end)
    line:AddChild(box)
    line:AddChild(win)
    self.boxes[index], self.winLabels[index] = box, win
  end

  local buttons = addLine(scroll)
  local place = AceGUI:Create("Button")
  place:SetText("Place bet")
  place:SetUserData("width", BUTTON_WIDTH)
  place:SetCallback("OnClick", function()
    tab:PlaceBet()
  end)
  buttons:AddChild(place)
  local takeBack = AceGUI:Create("Button")
  takeBack:SetText("Take back")
  takeBack:SetUserData("width", BUTTON_WIDTH)
  takeBack:SetCallback("OnClick", function()
    tab:TakeBack()
  end)
  buttons:AddChild(takeBack)
  self:AddStateLines(scroll, detail)
end

---Adds the rows of a locked event, read-only: per outcome its line with the booked sum and the own stake; then
---the state of the own bet.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildLocked(scroll, detail)
  for _, outcome in ipairs(detail.outcomes) do
    addLabel(scroll, outcomeText(outcome) .. (outcome.own and ("   your stake " .. outcome.own) or ""))
  end
  addLabel(scroll, WAIT_COLOR .. "Waiting for the result.|r")
  self:AddStateLines(scroll, detail)
end

---Adds the row of an own due. A due that the own character receives gets "Received" ("Done" for the banker's
---own share of the guild bank), and once confirmed "Undo"; a due that it pays shows only its state.
---@param container table
---@param eventId string
---@param due OOOOGambleResultDue
function tab:AddOwnDue(container, eventId, due)
  if not due.confirmable then
    addLabel(container, ownDueText(due))
    return
  end
  local line = addLine(container)
  local n = due.n
  if due.confirmed then
    line:AddChild(makeButton("Undo", UNDO_WIDTH, function()
      tab:ChangeReceipt(eventId, n, false)
    end))
  else
    line:AddChild(makeButton(isOwnPocket(due) and "Done" or "Received", RECEIVE_WIDTH, function()
      tab:ChangeReceipt(eventId, n, true)
    end))
  end
  -- The text takes what the button leaves, so it stands after the button
  line:AddChild(lineLabel(" " .. ownDueText(due)))
end

---Adds the rows of a resolved or cancelled event, read-only except for the receipts: per outcome its line with
---the booked sum, the own stake, and whether it came true; then the own result, the own dues with "Received",
---and all dues with their confirmations (15.5 to 15.7). The detail part scrolls, so a long list of dues fits.
---@param container table The AceGUI ScrollFrame of the detail part
---@param detail OOOOGambleDetail
---@param result OOOOGambleResult|nil The result of `Result`
---@param officer boolean The own character is an officer
function tab:BuildResolved(container, detail, result, officer)
  local results = result and result.results
  for index, outcome in ipairs(detail.outcomes) do
    local text = outcomeText(outcome) .. (outcome.own and ("   your stake " .. outcome.own) or "")
    if results then
      text = text .. "   " .. (results[index] and (GOOD_COLOR .. "came true|r") or (BAD_COLOR .. "did not come true|r"))
    end
    addLabel(container, text)
  end
  if detail.state == "cancelled" or not result or result.state == "cancelled" then
    addLabel(container, "Cancelled: nobody owes anything.")
    self.messageLabel = addLabel(container, self:MessageText(detail.id))
    return
  elseif result.state == "loading" then
    addLabel(container, WAIT_COLOR .. "The result is loading: " .. result.held .. " of " .. result.count
      .. " dues have arrived.|r")
    return
  end

  local own = ownResultText(result)
  if own ~= "" then
    addLabel(container, own)
  end
  if (result.bankHeld or 0) > 0 then
    addLabel(container, WAIT_COLOR .. "You hold " .. result.bankHeld .. " gold for the guild bank: put it into the "
      .. "guild bank.|r")
  end
  if #result.ownDues > 0 then
    addHeading(container, "Your dues")
    for _, due in ipairs(result.ownDues) do
      self:AddOwnDue(container, detail.id, due)
    end
  end
  self.messageLabel = addLabel(container, self:MessageText(detail.id))

  addHeading(container, "All dues")
  if #result.dues == 0 then
    addLabel(container, "Nobody owes anything: the event had no winning or no losing stakes.")
  end
  for _, due in ipairs(result.dues) do
    addLabel(container, allDueText(due))
  end
  if result.settled then
    addLabel(container, GOOD_COLOR .. "Everything is settled.|r")
  end
  if officer and result.mismatch then
    addLabel(container, WAIT_COLOR .. MISMATCH_NOTE .. "|r")
  end
  if #result.dues > 0 then
    addLabel(container, PAYMENT_NOTE, true)
  end
end

---Lists the characters that can be the banker: the own one first, then the officers of the roster by name.
---@return string[] names
---@return table<string, string> texts Name -> the text of the dropdown
function tab:BankerOptions()
  local own = self.model.playerName()
  local names = {}
  local guildState = ns.guildState
  for name in pairs(guildState.roster) do
    if name ~= own and guildState:IsOfficer(name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if own then
    table.insert(names, 1, own)
  end
  local texts = {}
  for _, name in ipairs(names) do
    texts[name] = name:gsub("|", "||") .. (name == own and " (you)" or "")
  end
  return names, texts
end

---Returns the choices of the form "Resolve" of an event, made at the first use; a banker who is no longer in
---the list falls back to the own character.
---@param eventId string
---@param texts table<string, string> The options of the banker (`BankerOptions`)
---@return OOOOGambleResolveChoice
function tab:ResolveChoice(eventId, texts)
  local choice = self.resolveChoices[eventId]
  if not choice then
    choice = { results = {} }
    self.resolveChoices[eventId] = choice
  end
  if not choice.banker or not texts[choice.banker] then
    choice.banker = self.model.playerName()
  end
  return choice
end

---Adds the form "Resolve" of a locked event: a check box per outcome, the banker, and the numbers of the
---bets with the warning of 15.5. The button is added by `BuildOfficer`.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildResolveForm(scroll, detail)
  local names, texts = self:BankerOptions()
  local choice = self:ResolveChoice(detail.id, texts)
  addLabel(scroll, RESOLVE_NOTE, true)
  for index, outcome in ipairs(detail.outcomes) do
    local check = AceGUI:Create("CheckBox")
    check:SetFullWidth(true)
    check:SetLabel(outcome.n .. " came true")
    check:SetValue(choice.results[index] == true)
    check:SetCallback("OnValueChanged", function(_widget, _event, value)
      choice.results[index] = value == true
      tab:Disarm()
    end)
    scroll:AddChild(check)
  end
  local line = addLine(scroll)
  line:AddChild(lineLabel("Banker", FORM_LABEL_WIDTH))
  local dropdown = AceGUI:Create("Dropdown")
  dropdown:SetUserData("width", DROPDOWN_WIDTH)
  dropdown:SetList(texts, names)
  dropdown:SetValue(choice.banker)
  -- The dropdown closes its list after this callback, so the callback releases no widget
  dropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
    choice.banker = value
    tab:Disarm()
  end)
  line:AddChild(dropdown)
  addLabel(scroll, BANKER_NOTE, true)
  self.previewLabel = addLabel(scroll, previewText(self.model:ResolvePreview(detail.id)))
end

---Adds the controls of the officers below the detail of an open, locked, or resolved event: "Lock now" for an
---open one, the form "Resolve" for a locked one, and "Cancel event" for all three.
---@param scroll table
---@param detail OOOOGambleDetail
function tab:BuildOfficer(scroll, detail)
  addHeading(scroll, "Officers")
  if detail.state == "locked" then
    self:BuildResolveForm(scroll, detail)
  end
  local buttons = addLine(scroll)
  if detail.state == "open" then
    buttons:AddChild(makeButton("Lock now", BUTTON_WIDTH, function()
      tab:LockEvent()
    end))
  elseif detail.state == "locked" then
    buttons:AddChild(makeButton(ACTION_TEXTS.resolve, ACTION_WIDTH, function(widget)
      tab:OnResolveClick(widget)
    end))
  end
  buttons:AddChild(makeButton(ACTION_TEXTS.cancel, ACTION_WIDTH, function(widget)
    tab:OnCancelClick(widget)
  end))
  addLabel(scroll, CANCEL_NOTE, true)
  -- The detail of a resolved event whose dues are still loading has no line for the answer to a click
  if not self.messageLabel then
    self.messageLabel = addLabel(scroll, self:MessageText(detail.id))
  end
end

---Gives the group of a cap that shows nothing a height of 1 in place of 0, and lets a shown one follow its
---rows again. A frame of height 0 has no place on the screen, and the List layout hangs every later row of
---the form on the frame before it: seen in the client, the rows after an empty group lay over each other.
---@param group table AceGUI SimpleGroup of the cap
---@param hidden boolean
local function collapseCap(group, hidden)
  -- AceGUI clears the flag when the group is released
  group.noAutoHeight = hidden or nil
  if hidden then
    group:SetHeight(1)
  end
end

---Shows or hides the cap of an outcome row as its typed chance changes, and updates the hint under it. Only
---the group of the cap is built again, so the chance box keeps its focus.
---@param group table AceGUI SimpleGroup of the cap
---@param outcome OOOOGambleDraftOutcome
function tab:UpdateCap(group, outcome)
  local show = capChance(outcome) ~= nil
  if show == (group:GetUserData("shown") == true) then
    local hint = group:GetUserData("hint")
    if hint and setText(hint, capHint(outcome)) and self.detail then
      self.detail:DoLayout()
    end
    return
  end
  group:SetUserData("shown", show)
  group:SetUserData("hint", nil)
  group:ReleaseChildren()
  collapseCap(group, not show)
  if show then
    local line = addLine(group)
    local check = AceGUI:Create("CheckBox")
    check:SetUserData("width", CAP_CHECK_WIDTH)
    check:SetLabel("Cap the payout")
    check:SetValue(outcome.capped)
    check:SetCallback("OnValueChanged", function(_widget, _event, value)
      outcome.capped = value == true
      tab:UpdateCap(group, outcome)
    end)
    line:AddChild(check)
    line:AddChild(formBox(outcome.cap, SMALL_BOX_WIDTH, SMALL_DIGITS, function(value)
      outcome.cap = value
      tab:UpdateCap(group, outcome)
    end))
    line:AddChild(lineLabel(" times the stake at most"))
    group:SetUserData("hint", addLabel(group, capHint(outcome)))
  end
  group:DoLayout()
  -- While the form is built, the paused scroll frame skips this
  if self.detail then
    self.detail:DoLayout()
  end
end

---Adds the rows of one outcome to the form "New event": its name, its chance, "Remove", and the cap.
---@param scroll table
---@param draft OOOOGambleDraft
---@param index integer
function tab:AddOutcomeRow(scroll, draft, index)
  local outcome = draft.outcomes[index]
  local nameLine = addLine(scroll)
  nameLine:AddChild(lineLabel("Outcome " .. index, FORM_LABEL_WIDTH))
  nameLine:AddChild(formBox(outcome.name, nil, gambleData.MAX_OUTCOME_NAME, function(value)
    outcome.name = value
  end))
  local capGroup = AceGUI:Create("SimpleGroup")
  local chanceLine = addLine(scroll)
  chanceLine:AddChild(lineLabel("Chance", FORM_LABEL_WIDTH))
  chanceLine:AddChild(formBox(outcome.chance, SMALL_BOX_WIDTH, SMALL_DIGITS, function(value)
    outcome.chance = value
    tab:UpdateCap(capGroup, outcome)
  end))
  chanceLine:AddChild(lineLabel(" %", UNIT_WIDTH))
  local remove = makeButton("Remove", BUTTON_WIDTH, function()
    tab:RemoveOutcome(index)
  end)
  remove:SetDisabled(#draft.outcomes <= gambleData.MIN_OUTCOMES)
  chanceLine:AddChild(remove)
  capGroup:SetFullWidth(true)
  capGroup:SetLayout("List")
  -- Hidden until `UpdateCap` finds a chance under the limit
  collapseCap(capGroup, true)
  scroll:AddChild(capGroup)
  self:UpdateCap(capGroup, outcome)
end

---Adds the form "New event": the title, the outcome rows, the close, the highest stake, and the buttons.
---@param scroll table
function tab:BuildForm(scroll)
  local draft = self.draft
  ---@cast draft OOOOGambleDraft
  addLabel(scroll, FORM_NOTE, true)
  local titleLine = addLine(scroll)
  titleLine:AddChild(lineLabel("Title", FORM_LABEL_WIDTH))
  titleLine:AddChild(formBox(draft.title, nil, gambleData.MAX_TITLE, function(value)
    draft.title = value
  end))

  for index = 1, #draft.outcomes do
    self:AddOutcomeRow(scroll, draft, index)
  end
  local addButtons = addLine(scroll)
  local add = makeButton("Add outcome", BUTTON_WIDTH, function()
    tab:AddOutcome()
  end)
  add:SetDisabled(#draft.outcomes >= gambleData.MAX_OUTCOMES)
  addButtons:AddChild(add)

  local closeLine = addLine(scroll)
  closeLine:AddChild(lineLabel("Close in", FORM_LABEL_WIDTH))
  local function onCloseChanged()
    if setText(tab.closeLabel, closeText(draft, tab.model.now())) and tab.detail then
      tab.detail:DoLayout()
    end
  end
  closeLine:AddChild(formBox(draft.days, SMALL_BOX_WIDTH, SMALL_DIGITS, function(value)
    draft.days = value
    onCloseChanged()
  end))
  closeLine:AddChild(lineLabel(" days", UNIT_WIDTH))
  closeLine:AddChild(formBox(draft.hours, SMALL_BOX_WIDTH, SMALL_DIGITS, function(value)
    draft.hours = value
    onCloseChanged()
  end))
  closeLine:AddChild(lineLabel(" h", UNIT_WIDTH))
  closeLine:AddChild(formBox(draft.minutes, SMALL_BOX_WIDTH, SMALL_DIGITS, function(value)
    draft.minutes = value
    onCloseChanged()
  end))
  closeLine:AddChild(lineLabel(" min", UNIT_WIDTH))
  self.closeLabel = addLabel(scroll, closeText(draft, self.model.now()))

  local stakeLine = addLine(scroll)
  stakeLine:AddChild(lineLabel("Highest stake", FORM_LABEL_WIDTH))
  stakeLine:AddChild(formBox(draft.maxStake, BOX_WIDTH, MAX_DIGITS, function(value)
    draft.maxStake = value
  end))
  stakeLine:AddChild(lineLabel(" gold on each outcome"))

  local buttons = addLine(scroll)
  buttons:AddChild(makeButton("Open event", BUTTON_WIDTH, function()
    tab:OpenEvent()
  end))
  buttons:AddChild(makeButton("Discard", BUTTON_WIDTH, function()
    tab:DiscardDraft()
  end))
  self.formLabel = addLabel(scroll, draft.problem and (BAD_COLOR .. draft.problem .. "|r") or "")
end

---Updates the texts of the built detail that change without a rebuild: the time line, the state of the own
---bet, the answer to the last click, and the numbers of the form "Resolve". A change of those numbers lets a
---waiting "Resolve" fall back, because the officer confirmed other numbers.
---@param detail OOOOGambleDetail
function tab:UpdateDetailTexts(detail)
  local changed = setText(self.timeLabel, timeText(detail, self.model.now()))
  changed = setText(self.stateLabel, betStateText(detail)) or changed
  changed = setText(self.messageLabel, self:MessageText(detail.id)) or changed
  if self.previewLabel and setText(self.previewLabel, previewText(self.model:ResolvePreview(detail.id))) then
    changed = true
    self:Disarm()
  end
  if changed then
    self.detail:DoLayout()
  end
end

---Updates the line of the close of the form "New event", which moves with the time.
function tab:UpdateFormTexts()
  if self.draft and setText(self.closeLabel, closeText(self.draft, self.model.now())) then
    self.detail:DoLayout()
  end
end

---Empties the detail part for a build: forgets the widgets of the last build and its waiting button.
---@param scroll table
---@param signature string What the new build shows
---@param title string Title of the group around the detail part
function tab:ClearDetail(scroll, signature, title)
  self.signature = signature
  self.armed = nil
  if self.detailGroup then
    self.detailGroup:SetTitle(title)
  end
  scroll:ReleaseChildren()
  scroll:PauseLayout()
  self.boxes, self.winLabels = {}, {}
  self.timeLabel, self.stateLabel, self.messageLabel = nil, nil, nil
  self.formLabel, self.closeLabel, self.previewLabel = nil, nil, nil
end

---Shows the detail of the selected event, or the form "New event". It is built again only when `force` is
---true or what it shows has changed; otherwise only its changing texts are updated, so that a box keeps its
---focus. Whether the character is an officer is asked here every time, because the roster arrives late.
---@param force boolean|nil
function tab:UpdateDetail(force)
  local scroll = self.detail
  if not scroll then
    return
  end
  local officer = ns.sync:IsOfficer()
  if self.creating and not (officer and self.draft) then
    self.creating = false
  end
  if self.creating then
    local signature = "\030new\031" .. #self.draft.outcomes
    if not force and signature == self.signature then
      self:UpdateFormTexts()
      return
    end
    self:ClearDetail(scroll, signature, "New event")
    self:BuildForm(scroll)
    scroll:ResumeLayout()
    scroll:DoLayout()
    return
  end
  local detail = self.selectedId and self.model:Detail(self.selectedId) or nil
  local results = detail and detail.state == "resolved" and resultsOf(self.model, detail.id) or nil
  local result = detail and (detail.state == "resolved" or detail.state == "cancelled")
    and self.model:Result(detail.id) or nil
  local signature = ""
  if detail then
    -- The officer controls, and the banker list of a locked event, are part of what the detail shows
    local bankers = officer and detail.state == "locked" and table.concat((self:BankerOptions()), ",") or ""
    local event = result and self.model:Event(detail.id)
    signature = detailSignature(detail, results) .. "\030" .. tostring(officer) .. "\030" .. bankers .. "\030"
      .. resultSignature(result, event and event.q or nil)
  end
  if not force and signature == self.signature then
    if detail then
      self:UpdateDetailTexts(detail)
    end
    return
  end
  self:ClearDetail(scroll, signature, "Event")
  if not detail then
    addLabel(scroll, DETAIL_HINT, true)
  else
    self:AddHeader(scroll, detail)
    if detail.state == "open" then
      self:BuildOpen(scroll, detail)
    elseif detail.state == "locked" then
      self:BuildLocked(scroll, detail)
    else
      self:BuildResolved(scroll, detail, result, officer)
    end
    if officer and detail.state ~= "cancelled" then
      self:BuildOfficer(scroll, detail)
    end
  end
  scroll:ResumeLayout()
  scroll:DoLayout()
end

--------------------------------------------------------------------------------
-- Betting
--------------------------------------------------------------------------------

---Builds the detail again after a successful click, in the next frame: the clicked button is not released
---inside its own click.
function tab:RefreshSoon()
  local token = self.token
  C_Timer.After(0, function()
    if token == tab.token then
      tab:Refresh()
    end
  end)
end

---Reads every stake box and places the own bet: an empty box or 0 removes the outcome. A box that does not
---hold a whole number, or a stake over the highest stake, refuses the whole bet with a line and writes nothing.
function tab:PlaceBet()
  local eventId = self.selectedId
  local detail = eventId and self.model and self.model:Detail(eventId)
  if not detail then
    return
  end
  ---@cast eventId string
  local stakes, any, held = {}, false, false
  for index, outcome in ipairs(detail.outcomes) do
    local box = self.boxes[index]
    local stake, problem = parseStake(box and box:GetText() or "", detail.maxStake)
    if problem == "number" then
      self:ShowMessage(eventId, "The stake on " .. outcome.n .. " is not a whole number of gold.", true)
      return
    elseif problem == "limit" then
      self:ShowMessage(eventId, "The stake on " .. outcome.n .. " is over the highest stake of " .. detail.maxStake
        .. " gold.", true)
      return
    end
    ---@cast stake integer
    stakes[index] = stake
    any = any or stake > 0
    held = held or outcome.own ~= nil
  end
  if not any and not held then
    self:ShowMessage(eventId, "Type a stake for at least one outcome.", true)
    return
  end
  local placed, reason = self.model:PlaceBet(eventId, stakes)
  if not placed then
    self:ShowMessage(eventId, refusalText(reason, detail.maxStake), true)
    return
  end
  self.typed[eventId] = nil
  self:ShowMessage(eventId, any and "Your bet is saved. It counts when an officer has accepted it."
    or "Your bet is taken back.", false)
  self:RefreshSoon()
end

---Takes the own bet back.
function tab:TakeBack()
  local eventId = self.selectedId
  local detail = eventId and self.model and self.model:Detail(eventId)
  if not detail then
    return
  end
  ---@cast eventId string
  local taken, reason = self.model:TakeBack(eventId)
  if not taken then
    self:ShowMessage(eventId, refusalText(reason, detail.maxStake), true)
    return
  end
  self.typed[eventId] = nil
  self:ShowMessage(eventId, "Your bet is taken back.", false)
  self:RefreshSoon()
end

--------------------------------------------------------------------------------
-- Receipts
--------------------------------------------------------------------------------

---Confirms that the own character has received a due ("Received", "Done"), or takes the confirmation back
---("Undo"). The answer goes to the message line; on success the detail is built again in the next frame.
---@param eventId string
---@param n integer Due number
---@param confirmed boolean true to confirm, false to take back
function tab:ChangeReceipt(eventId, n, confirmed)
  if not self.model then
    return
  end
  local done, reason
  if confirmed then
    done, reason = self.model:Confirm(eventId, n)
  else
    done, reason = self.model:Unconfirm(eventId, n)
  end
  if not done then
    self:ShowMessage(eventId, receiptRefusalText(reason), true)
    return
  end
  self:ShowMessage(eventId, confirmed and "Confirmed: everybody sees this due as received."
    or "Your confirmation is taken back.", false)
  self:RefreshSoon()
end

--------------------------------------------------------------------------------
-- The controls of the officers
--------------------------------------------------------------------------------

---Lets a button that waits for its second click fall back to its first text.
function tab:Disarm()
  local armed = self.armed
  if not armed then
    return
  end
  self.armed = nil
  armed.button:SetText(ACTION_TEXTS[armed.action])
end

---Makes a button wait for its second click, for `ARM_SECONDS`.
---@param action "resolve"|"cancel"
---@param eventId string
---@param button table AceGUI Button
function tab:Arm(action, eventId, button)
  self:Disarm()
  local armed = { action = action, eventId = eventId, button = button }
  self.armed = armed
  button:SetText(ARMED_TEXTS[action])
  C_Timer.After(ARM_SECONDS, function()
    if tab.armed == armed then
      tab:Disarm()
    end
  end)
end

---Tells whether a click is the second one: the button of the action waits for the event.
---@param action "resolve"|"cancel"
---@param eventId string
---@return boolean
function tab:IsArmed(action, eventId)
  local armed = self.armed
  return armed ~= nil and armed.action == action and armed.eventId == eventId
end

---Builds the detail again in the next frame: the clicked button is not released inside its own click.
function tab:RebuildSoon()
  local token = self.token
  C_Timer.After(0, function()
    if token == tab.token then
      tab:UpdateDetail(true)
    end
  end)
end

---Adds an empty outcome row to the form "New event", up to `MAX_OUTCOMES`.
function tab:AddOutcome()
  local draft = self.draft
  if not draft or #draft.outcomes >= gambleData.MAX_OUTCOMES then
    return
  end
  draft.outcomes[#draft.outcomes + 1] = newDraftOutcome()
  self:RebuildSoon()
end

---Removes an outcome row from the form "New event", down to `MIN_OUTCOMES`.
---@param index integer
function tab:RemoveOutcome(index)
  local draft = self.draft
  if not draft or #draft.outcomes <= gambleData.MIN_OUTCOMES or not draft.outcomes[index] then
    return
  end
  table.remove(draft.outcomes, index)
  self:RebuildSoon()
end

---Leaves the form "New event" and forgets its values; the detail shows the selected event again.
function tab:DiscardDraft()
  self.draft, self.creating = nil, false
  -- The list too: it marks the selected row again
  self:RefreshSoon()
end

---Shows a problem of the form "New event" in its line.
---@param text string
function tab:ShowFormProblem(text)
  if self.draft then
    self.draft.problem = text
  end
  if setText(self.formLabel, BAD_COLOR .. text .. "|r") and self.detail then
    self.detail:DoLayout()
  end
end

---Reads the form "New event" and opens the event. A refused box or a refusal of the model is shown in the
---form; on success the form is left and the new event is selected.
function tab:OpenEvent()
  local draft = self.draft
  if not draft or not self.model then
    return
  end
  local spec, problem = readDraft(draft, self.model.now())
  if not spec then
    self:ShowFormProblem(problem or OFFICER_REFUSALS["bad spec"])
    return
  end
  local eventId, reason = self.model:Open(spec)
  if not eventId then
    self:ShowFormProblem(officerRefusalText(reason))
    return
  end
  self.draft, self.creating, self.selectedId = nil, false, eventId
  self.message = { eventId = eventId, text = "The event is open. Bets are taken until the close.", error = false }
  self:RefreshSoon()
end

---Locks the selected open event now; no second click is needed.
function tab:LockEvent()
  local eventId = self.selectedId
  if not eventId or not self.model then
    return
  end
  local locked, reason = self.model:Lock(eventId)
  if not locked then
    self:ShowMessage(eventId, officerRefusalText(reason), true)
    return
  end
  self:ShowMessage(eventId, "The event is locked: no more bets are taken.", false)
  self:RefreshSoon()
end

---Handles a click on "Resolve": the first click makes the button wait, the second resolves the selected event
---with the ticked outcomes and the chosen banker.
---@param button table AceGUI Button
function tab:OnResolveClick(button)
  local eventId = self.selectedId
  local event = eventId and self.model and self.model:Event(eventId)
  if not event then
    return
  end
  ---@cast eventId string
  if not self:IsArmed("resolve", eventId) then
    -- The form says why; the button does not arm while bets are still being booked
    if previewWait(self.model:ResolvePreview(eventId)) <= 0 then
      self:Arm("resolve", eventId, button)
    end
    return
  end
  self:Disarm()
  local choice = self.resolveChoices[eventId] or { results = {} }
  local results = {}
  for index = 1, #event.o do
    results[index] = choice.results[index] == true
  end
  -- nil names the own character, which `Resolve` always accepts
  local banker = choice.banker
  if banker == self.model.playerName() then
    banker = nil
  end
  local resolved, reason = self.model:Resolve(eventId, results, banker)
  if not resolved then
    self:ShowMessage(eventId, officerRefusalText(reason), true)
    return
  end
  self.resolveChoices[eventId] = nil
  self:ShowMessage(eventId, "The event is resolved.", false)
  self:RefreshSoon()
end

---Handles a click on "Cancel event": the first click makes the button wait, the second cancels the selected
---event.
---@param button table AceGUI Button
function tab:OnCancelClick(button)
  local eventId = self.selectedId
  if not eventId or not self.model then
    return
  end
  if not self:IsArmed("cancel", eventId) then
    self:Arm("cancel", eventId, button)
    return
  end
  self:Disarm()
  local cancelled, reason = self.model:Cancel(eventId)
  if not cancelled then
    self:ShowMessage(eventId, officerRefusalText(reason), true)
    return
  end
  self.resolveChoices[eventId] = nil
  self:ShowMessage(eventId, "The event is cancelled: the bets do not count, and nobody owes anything.", false)
  self:RefreshSoon()
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

---Builds the list again, shows or hides "New event", and updates the detail.
function tab:Refresh()
  if not self.list then
    return
  end
  local groups = self.model:Events()
  self:EnsureSelection(groups)
  self:UpdateList(groups, self.model.now())
  self:UpdateOfficerBar(ns.sync:IsOfficer())
  self:UpdateDetail(false)
end

---Asks for `Refresh` after `REFRESH_DELAY`; the changes until then are refreshed together.
function tab:ScheduleRefresh()
  if self.refreshPending then
    return
  end
  self.refreshPending = true
  local token = self.token
  C_Timer.After(REFRESH_DELAY, function()
    if token == tab.token then
      tab.refreshPending = false
      tab:Refresh()
    end
  end)
end

---Refreshes the tab every `TICK` seconds while it is shown: the "in 2 h" texts, and the events whose close
---has passed move from "Open" to "Waiting for the result". A timer, not an OnUpdate poll.
function tab:ScheduleTick()
  local token = self.token
  C_Timer.After(TICK, function()
    if token == tab.token then
      tab:Refresh()
      tab:ScheduleTick()
    end
  end)
end

---Builds the content of the tab: at the left the list of events, at the right the detail.
---@param container table The AceGUI tab group
function tab:Build(container)
  self.token = self.token + 1
  self.refreshPending = false
  local model = ns.gamble and ns.gamble.current
  if not model then
    addLabel(container, NOT_READY, true)
    return
  end
  self.model = model

  local root = AceGUI:Create("SimpleGroup")
  root:SetLayout("OOOOColumns")
  root:SetAutoAdjustHeight(false)

  local left = AceGUI:Create("InlineGroup")
  left:SetTitle("Events")
  left:SetLayout("OOOORows")
  left:SetAutoAdjustHeight(false)
  left:SetUserData("width", LIST_WIDTH)
  local list = AceGUI:Create("ScrollFrame")
  list:SetLayout("List")
  list:SetUserData("fill", true)
  left:AddChild(list)
  -- Empty, and so 0 high, until a refresh finds that the character is an officer
  local bar = AceGUI:Create("SimpleGroup")
  bar:SetLayout("OOOOLine")
  left:AddChild(bar)
  root:AddChild(left)

  local right = AceGUI:Create("InlineGroup")
  right:SetTitle("Event")
  right:SetLayout("Fill")
  right:SetAutoAdjustHeight(false)
  local detail = AceGUI:Create("ScrollFrame")
  detail:SetLayout("List")
  right:AddChild(detail)
  root:AddChild(right)

  container:AddChild(root)
  root:DoLayout()

  self.list, self.detail, self.signature = list, detail, nil
  self.leftGroup, self.detailGroup, self.officerBar, self.barShown = left, right, bar, nil
  local data = ns.gambleData
  ns.sync.RegisterCallback(tab, "OnRecordChanged", function(_event, tableName)
    if tableName == data.TABLE or tableName == data.PLAYER_TABLE then
      tab:ScheduleRefresh()
    end
  end)
  -- The officer controls and the banker list follow the roster
  ns.guildState.RegisterCallback(tab, "OnRosterChanged", function()
    tab:ScheduleRefresh()
  end)
  self:Refresh()
  self:ScheduleTick()
end

---Forgets the widgets, which the window releases, stops the timers, and drops the typed stakes and the choices
---of the form "Resolve". The selected event and the values of the form "New event" stay; the form is left.
function tab:Close()
  self.token = self.token + 1
  self.refreshPending = false
  if self.model then
    ns.sync.UnregisterCallback(tab, "OnRecordChanged")
    ns.guildState.UnregisterCallback(tab, "OnRosterChanged")
  end
  self.model, self.list, self.detail, self.signature = nil, nil, nil, nil
  self.leftGroup, self.detailGroup, self.officerBar, self.barShown = nil, nil, nil, nil
  self.rows, self.boxes, self.winLabels, self.typed, self.resolveChoices = {}, {}, {}, {}, {}
  self.timeLabel, self.stateLabel, self.messageLabel, self.message = nil, nil, nil, nil
  self.formLabel, self.closeLabel, self.previewLabel, self.armed, self.creating = nil, nil, nil, nil, false
end

---Shows the addon window with this tab.
---@return boolean opened false when the shared database is not ready
function tab:Open()
  return ns.mainWindow:Open(TAB_ID)
end

ns.mainWindow:RegisterTab({
  id = TAB_ID,
  title = "Gambling",
  order = 40,
  Build = function(container)
    tab:Build(container)
  end,
  Close = function()
    tab:Close()
  end,
})

ns.slash:Register("bet", "bet - open the gambling tab", function()
  tab:Open()
end)
