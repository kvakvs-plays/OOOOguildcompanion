-- Host test of Addon/Src/Guild/GuildState.lua with stubbed guild and roster functions of the client.
local T = dofile("Tests/harness.lua")

T.loadLibraries()

---What the stubbed client tells: the guild of the character and the roster
local client = { inGuild = true, guildName = nil, roster = {}, requests = 0, time = 100 }
---A value that stands for a secret one
local SECRET = {}

_G.issecretvalue = function(value)
  return value == SECRET
end
_G.IsInGuild = function()
  return client.inGuild
end
_G.GetGuildInfo = function()
  return client.guildName
end
_G.GetNumGuildMembers = function()
  return #client.roster
end
_G.GetGuildRosterInfo = function(index)
  local member = client.roster[index]
  return member[1], "rank", member[2], 60, "Mage", "zone", "", "", member[3]
end
_G.C_GuildInfo = {
  GuildRoster = function()
    client.requests = client.requests + 1
  end,
}
_G.GetTime = function()
  return client.time
end
---Event frames made by the module
local frames = {}
_G.CreateFrame = function()
  local frame = { events = {} }
  function frame:SetScript(_, handler)
    self.handler = handler
  end
  function frame:RegisterEvent(event)
    self.events[event] = true
  end
  frames[#frames + 1] = frame
  return frame
end

local ns = T.load("Addon/Src/Guild/GuildState.lua")
local guildState = ns.guildState

---Callbacks fired since the last call of `fired`
local events = {}
guildState.RegisterCallback(events, "OnGuildStateChanged", function(_, inGuild, state)
  events[#events + 1] = "state " .. tostring(inGuild) .. " " .. state
end)
guildState.RegisterCallback(events, "OnRosterChanged", function()
  events[#events + 1] = "roster"
end)
local function fired()
  local text = table.concat(events, ", ")
  for index = #events, 1, -1 do
    events[index] = nil
  end
  return text
end

---Sends a client event through the frame, as the game does.
local function fire(event, ...)
  T.ok(frames[1].events[event], event .. " is registered")
  frames[1].handler(frames[1], event, ...)
end

-- normalizeName
do
  T.eq(guildState.normalizeName("Name-Realm"), "Name", "a realm suffix is cut off")
  T.eq(guildState.normalizeName("Nota Scam"), "Nota Scam", "a name with a space stays whole")
  T.eq(guildState.normalizeName("Nota Scam-CAMWOW EU4"), "Nota Scam", "a suffix after a name with a space is cut off")
  T.eq(guildState.normalizeName(SECRET), nil, "a secret name gives nil")
  T.eq(guildState.normalizeName(5), nil, "a number gives nil")
  T.eq(guildState.normalizeName(""), nil, "an empty name gives nil")
  T.eq(guildState.GUILD_NAME, "OO OO", "the guild name is OO OO")
end

-- The state: unknown while the name is nil, then in or outside
do
  T.eq(guildState.state, "unknown", "the state is unknown before the start")
  guildState:Start()
  T.eq(#frames, 1, "the start makes one event frame")
  guildState:Start()
  T.eq(#frames, 1, "a second start makes no second frame")
  T.eq(guildState.state, "unknown", "the state is unknown, not outside, while the guild name is nil")
  T.eq(guildState:IsInGuild(), false, "an unknown state is not in the guild")
  T.eq(fired(), "", "no callback fires while the state stays unknown")
  T.eq(client.requests, 0, "no roster is requested while the state is unknown")

  client.guildName = SECRET
  fire("PLAYER_GUILD_UPDATE", "player")
  T.eq(guildState.state, "unknown", "a secret guild name keeps the state unknown")

  client.guildName = "OO OO"
  fire("PLAYER_GUILD_UPDATE", "party1")
  T.eq(guildState.state, "unknown", "a guild update of another unit is ignored")
  fire("PLAYER_GUILD_UPDATE", "player")
  T.eq(guildState.state, "in", "the guild name OO OO gives the state in")
  T.eq(fired(), "state true in", "the change fires OnGuildStateChanged once")
  T.eq(client.requests, 1, "the roster is requested once")
  fire("PLAYER_GUILD_UPDATE")
  T.eq(fired(), "", "an unchanged state fires nothing")
  T.eq(client.requests, 1, "the roster is not requested again")
end

-- The roster cache
do
  client.roster = {
    { "Nota Scam", 0, true },
    { "Other One", 2, true },
    { "Third One-Realm", 5, false },
    { SECRET, 5, true },
    { "No Rank", SECRET, true },
  }
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "the first roster fires OnRosterChanged")
  T.eq(guildState.rosterCount, 3, "secret entries are left out")
  T.eq(guildState:IsRosterComplete(), false, "a roster with entries left out is not complete")
  T.eq(guildState:GetMember("Nota Scam"), { online = true, rankIndex = 0 }, "a member has its rank and online state")
  T.eq(guildState:GetMember("Third One"), { online = false, rankIndex = 5 }, "a realm suffix is cut off the key")
  T.eq(guildState:GetMember("Stranger"), nil, "an unknown name has no entry")
  T.eq(guildState:IsOnline("Other One"), true, "an online member is online")
  T.eq(guildState:IsOnline("Third One"), false, "an offline member is not online")
  T.eq(guildState:IsOnline("Stranger"), false, "an unknown name is not online")

  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "", "the same roster fires nothing")

  client.roster[2][3] = false
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a member who goes offline fires OnRosterChanged")
  T.eq(guildState:IsOnline("Other One"), false, "the cache shows the member offline")

  table.remove(client.roster, 2)
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a member who leaves fires OnRosterChanged")
  T.eq(guildState:GetMember("Other One"), nil, "the member who left is gone from the cache")
  T.eq(guildState.rosterCount, 2, "the count follows")
  -- Without the two entries that cannot be read, the cache lists every member
  local unreadable = { table.remove(client.roster), table.remove(client.roster) }
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a roster that becomes complete fires OnRosterChanged")
  T.eq(guildState:IsRosterComplete(), true, "a roster with an entry for every member is complete")
  client.roster[#client.roster + 1] = unreadable[2]
  client.roster[#client.roster + 1] = unreadable[1]
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a roster that loses an entry fires OnRosterChanged")
  T.eq(guildState:IsRosterComplete(), false, "and is no longer complete")

  client.roster[#client.roster + 1] = { "New One", 9, true }
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a member who joins fires OnRosterChanged")
  T.eq(guildState:GetMember("New One"), { online = true, rankIndex = 9 }, "the new member is in the cache")

  client.roster[1][2] = 1
  fire("GUILD_ROSTER_UPDATE")
  T.eq(fired(), "roster", "a rank change fires OnRosterChanged")
  T.eq(guildState:GetMember("Nota Scam").rankIndex, 1, "the cache has the new rank")
end

-- NoteOnline: a message is evidence that the sender is online
do
  T.eq(client.requests, 1, "no roster request so far beyond the first")
  guildState:NoteOnline("Third One")
  T.eq(guildState:IsOnline("Third One"), true, "the member counts as online")
  T.eq(fired(), "roster", "the change fires OnRosterChanged")
  T.eq(client.requests, 2, "a fresh roster is requested")
  guildState:NoteOnline("Third One")
  guildState:NoteOnline("New One")
  guildState:NoteOnline("Stranger")
  T.eq(fired(), "", "an online or unknown name changes nothing")
  T.eq(client.requests, 2, "and requests nothing")

  -- A second stale entry within the interval: marked, but no second request
  client.roster[#client.roster + 1] = { "Late One", 5, false }
  fire("GUILD_ROSTER_UPDATE")
  fired()
  client.time = client.time + 5
  guildState:NoteOnline("Late One")
  T.eq(guildState:IsOnline("Late One"), true, "a second member is marked online")
  T.eq(client.requests, 2, "no second request within 15 seconds")
  fire("GUILD_ROSTER_UPDATE")
  T.eq(guildState:IsOnline("Late One"), false, "a roster update replaces the mark")
  client.time = client.time + 15
  guildState:NoteOnline("Late One")
  T.eq(client.requests, 3, "a request is made again after 15 seconds")
  fired()
end

-- Leaving the guild
do
  client.guildName = "Other Guild"
  fire("GUILD_ROSTER_UPDATE")
  T.eq(guildState.state, "outside", "another guild name gives the state outside")
  T.eq(fired(), "roster, state false outside", "the roster empties and the state change fires")
  T.eq(guildState.rosterCount, 0, "the cache is empty outside the guild")
  T.eq(guildState:GetMember("Nota Scam"), nil, "no member is known outside the guild")

  client.inGuild = false
  client.guildName = "OO OO"
  fire("PLAYER_GUILD_UPDATE", "player")
  T.eq(guildState.state, "outside", "a character in no guild is outside")
  T.eq(fired(), "", "outside to outside fires nothing")

  client.inGuild = true
  local requests = client.requests
  fire("PLAYER_GUILD_UPDATE", "player")
  T.eq(fired(), "state true in", "joining the guild again fires the state change")
  T.eq(client.requests, requests + 1, "and requests the roster again")
end

T.finish()
