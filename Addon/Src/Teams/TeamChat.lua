local addonName, ns = ...

-- The alias of a team in chat (.agents/user-wishes.md, "Display in chat"): in guild, officer, say, party, and
-- whisper chat, a line of a character with a team starts with the alias of the team:
-- `[Nota Tall]: nota: hello`. The client writes the name in brackets; a chat filter can change only the text,
-- so the alias goes in front of the text.
--
-- The alias is wrapped in a hyperlink of the addon. The emoji filter leaves the text of a hyperlink alone
-- (Emoji/EmojiChat.lua), so an alias like `fire` stays a word whichever filter runs first. A click on it does
-- nothing.
--
-- Not checked in the client when this was written: that the sender of `CHAT_MSG_SAY`, `CHAT_MSG_PARTY`, and
-- `CHAT_MSG_WHISPER` is the name as the guild roster gives it (first and last name, no realm), as it is for
-- `CHAT_MSG_GUILD`; and whether officer chat reaches a filter at all (the emoji filter saw none on
-- 2026-11-21, probe `emoji`). A line whose sender or text is secret is shown as it came.
--
-- `decorate` and `Filter` use no WoW API, so the host tests load this file (Tests/sync_teams.lua).

---@class OOOOTeamChat
---@field filtersInstalled boolean true while the chat filters are registered
---@field aliasOf (fun(name: string): string|nil)|nil Gives the alias of a character; set by a test, the game
---asks `ns.teams.current`
local teamChat = { filtersInstalled = false }
ns.teamChat = teamChat

---The chat events whose lines show the alias
teamChat.EVENTS = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_SAY", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_WHISPER" }

---Colour of the alias: silver
local ALIAS_COLOR = "|cffc0c0c0"
---Data of the hyperlink around the alias
local LINK = "addon:" .. addonName .. ":team"

---Puts the alias of a team in front of a chat text.
---@param text string
---@param alias string An alias of the table `team`: it has no `|`
---@return string
function teamChat.decorate(text, alias)
  return "|H" .. LINK .. "|h" .. ALIAS_COLOR .. alias .. "|r|h: " .. text
end

---Tells whether the aliases are shown: the setting `db.profile.general.teamAliases`.
---@return boolean
function teamChat:IsEnabled()
  return ns.db ~= nil and ns.db.profile.general.teamAliases ~= false
end

---Turns the aliases in chat on or off. Lines that the chat frames already show stay as they are.
---@param enabled boolean
function teamChat:SetEnabled(enabled)
  ns.db.profile.general.teamAliases = enabled and true or false
end

---Returns the alias of a character.
---@param name string
---@return string|nil
function teamChat:AliasOf(name)
  if self.aliasOf then
    return self.aliasOf(name)
  end
  local model = ns.teams.current
  return model and model:AliasOf(name) or nil
end

---Returns the text of a chat line with the alias of its sender in front.
---@param message any Text of the line
---@param sender any Name of the sender, as the chat event gives it
---@return string|nil text nil when the line stays as it is: it is unreadable, its sender has no team, or the
---alias is the name of the character
function teamChat:Filter(message, sender)
  if issecretvalue(message) or type(message) ~= "string" then
    return nil
  end
  local name = ns.guildState.normalizeName(sender)
  local alias = name and self:AliasOf(name)
  -- Checked again, because the alias comes from a record that another member sent
  if not alias or not ns.teamData.isAlias(alias) or alias:lower() == name:lower() then
    return nil
  end
  return teamChat.decorate(message, alias)
end

---Chat message filter, see ChatFrameUtil.AddMessageEventFilter.
---@param _chatFrame table
---@param _event string
---@param message any
---@param sender any
---@param ... any Remaining arguments of the chat event
---@return boolean discard Always false: the message is shown
---@return string|nil message New text; nothing when the text is unchanged
---@return any ... Remaining arguments of the chat event, after a new text
local function chatFilter(_chatFrame, _event, message, sender, ...)
  if not teamChat:IsEnabled() then
    return false
  end
  local text = teamChat:Filter(message, sender)
  if not text then
    return false
  end
  return false, text, sender, ...
end

---The filter functions moved into ChatFrameUtil in the Mainline UI; the old globals are the fallback.
---@param name string "AddMessageEventFilter" or "RemoveMessageEventFilter"
---@return function|nil
local function getFilterFunction(name)
  local util = _G.ChatFrameUtil
  return (util and util[name]) or _G["ChatFrame_" .. name]
end

---Adds or removes the chat filters. The filter itself asks the setting, so a changed setting needs no change
---here.
---@param wanted boolean
function teamChat:SetFiltersInstalled(wanted)
  if wanted == self.filtersInstalled then
    return
  end
  local change = getFilterFunction(wanted and "AddMessageEventFilter" or "RemoveMessageEventFilter")
  if not change then
    return
  end
  for _, event in ipairs(self.EVENTS) do
    change(event, chatFilter)
  end
  self.filtersInstalled = wanted
end

-- The aliases are on while the character is in the guild
ns.guildState.RegisterCallback(teamChat, "OnGuildStateChanged", function(_event, inGuild)
  teamChat:SetFiltersInstalled(inGuild)
end)

ns.slash:Register("alias", "alias [text] - show or change the alias of your team", function(rest)
  local model = ns.teams.current
  local name = ns.syncCharacter.playerName()
  if not model or not name then
    ns.print("The shared database is not ready.")
    return
  end
  local id, detected = model:TeamOf(name)
  -- The dispatcher has cut the spaces at both ends off
  local text = type(rest) == "string" and rest or ""
  if text == "" then
    if not id then
      ns.print("This character is in no team. An officer makes the teams.")
    else
      local request = model:OwnRequest()
      ns.print("Your team is shown as \"" .. model:Alias(id) .. "\"."
        .. (request and (" You asked for \"" .. request .. "\".") or "")
        .. (detected and " An officer has not assigned this character yet, so it cannot change the alias." or
          " Change it with /oooo alias <text>."))
    end
    return
  end
  local ok, reason = model:SubmitAlias(text)
  if ok then
    ns.print("Asked for the alias \"" .. text .. "\". It shows once an online officer's addon has"
      .. " taken it.")
  else
    ns.print("The alias was not changed: " .. (teamChat.REFUSALS[reason] or tostring(reason)) .. ".")
  end
end)

---Refusal of `SubmitAlias` -> what the user reads
---@type table<string, string>
teamChat.REFUSALS = {
  ["not ready"] = "the addon is not ready yet",
  ["no team"] = "an officer has not assigned this character to a team",
  ["empty"] = "the alias is empty",
  ["too long"] = "the alias is longer than " .. ns.teamData.MAX_ALIAS .. " bytes",
  ["bad character"] = "the alias has a character that is not allowed (|)",
}
