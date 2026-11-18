-- Host test of the mentions (.agents/00-plan.md, stage 11; Addon/Src/Chat/Mentions.lua): the watch list,
-- the search for `@` words, the text that the window shows, the list of mentions with its read and unread
-- entries, the notice, and the warning for a mention that nobody can copy.
local T = dofile("Tests/harness.lua")
T.loadLibraries()

local ITEM_LINK = "|cff0070dd|Hitem:4306::::::::60:::::|h[Silk Cloth]|h|r"

--------------------------------------------------------------------------------
-- Step 11.1: the functions that only compute
--------------------------------------------------------------------------------

local mentions = T.load("Addon/Src/Chat/Mentions.lua").mentions

-- parseWatchList
T.eq(mentions.parseWatchList("tall, kvakvs ,scam"), { "tall", "kvakvs", "scam" }, "spaces around commas are cut off")
T.eq(mentions.parseWatchList(""), {}, "an empty setting is an empty list")
T.eq(mentions.parseWatchList(" , ,, "), {}, "and so is one with commas alone")
T.eq(mentions.parseWatchList(nil), {}, "and a setting that is no string")
T.eq(mentions.parseWatchList("tall,Tall, TALL,scam"), { "tall", "scam" }, "a repeated entry is taken once")
T.eq(mentions.parseWatchList("KvaKvs"), { "kvakvs" }, "upper case becomes lower case")
T.eq(mentions.parseWatchList("nota tall, x"), { "nota tall", "x" }, "an entry keeps its inner spaces")
T.eq(mentions.parseWatchList("@tall"), { "tall" }, "an @ before an entry is dropped")

-- hasMention
T.eq(mentions.hasMention("@tall hello"), true, "@word at the start")
T.eq(mentions.hasMention("hello @tall, you there"), true, "@word in the middle")
T.eq(mentions.hasMention("hello @tall"), true, "@word at the end")
T.eq(mentions.hasMention("no mention here"), false, "a line without @")
T.eq(mentions.hasMention("meet @ 8"), false, "a lone @")
T.eq(mentions.hasMention("ends with @"), false, "an @ at the end")
T.eq(mentions.hasMention("mail a@b.c"), true, "an e-mail form counts")
T.eq(mentions.hasMention("look |cff0070dd|Hitem:1::|h[Sword @home]|h|r"), false, "an @ inside an item link does not")
T.eq(mentions.hasMention("look " .. ITEM_LINK .. " @tall"), true, "an @ after a link does")
T.eq(mentions.hasMention("@|cff00ff00tall|r"), false, "an @ before an escape sequence is alone")

-- fragments
do
  local watch = mentions.parseWatchList("kvakvs, tall")
  T.eq(mentions.fragments("@Kvakvs hello", watch), { "@Kvakvs" }, "at the start, returned as written")
  T.eq(mentions.fragments("hello @tall there", watch), { "@tall" }, "in the middle")
  T.eq(mentions.fragments("hello @tall", watch), { "@tall" }, "at the end")
  T.eq(mentions.fragments("hey @tall, come", watch), { "@tall" }, "before a comma")
  T.eq(mentions.fragments("is it @TALL?", watch), { "@TALL" }, "before a question mark, in upper case")
  T.eq(mentions.fragments("@kvakvsy hello", watch), {}, "an entry that is the start of a longer word")
  T.eq(mentions.fragments("@taller", watch), {}, "also at the end of the line")
  T.eq(mentions.fragments("@tall_one", watch), {}, "an underscore is a part of the word")
  T.eq(mentions.fragments("@tall\195\164", watch), {}, "and so is a UTF-8 letter")
  T.eq(mentions.fragments("@Tall and @kvakvs: hi @tall", watch), { "@Tall", "@kvakvs", "@tall" },
    "all watched fragments of a line, in their order")
  T.eq(mentions.fragments("@other hello", watch), {}, "an @ word that is not watched")
  T.eq(mentions.fragments("tall kvakvs", watch), {}, "a watched word without @")
  T.eq(mentions.fragments("@ tall", watch), {}, "the entry must follow the @ directly")
  T.eq(mentions.fragments("@tall", {}), {}, "an empty watch list finds nothing")
  T.eq(mentions.fragments("|cff0070dd|Hitem:1::|h[@tall]|h|r", watch), {}, "an @ inside a link does not count")
  T.eq(mentions.fragments("look @Tall " .. ITEM_LINK, watch), { "@Tall" }, "a mention before a link does")
  T.eq(mentions.fragments("@tall|cff00ff00x|r", watch), { "@tall" }, "an escape sequence ends the word")
  -- "\195\166" is the letter ae; string.lower leaves it alone
  T.eq(mentions.fragments("hi @\195\166z!", mentions.parseWatchList("\195\166z")), { "@\195\166z" },
    "an entry with a UTF-8 letter")
  T.eq(mentions.fragments("@nota tall is here, @Nota", mentions.parseWatchList("nota, nota tall")),
    { "@nota tall", "@Nota" }, "of two entries that match, the longer one is taken")
end

-- sanitize
T.eq(mentions.sanitize("plain text"), "plain text", "a plain text is unchanged")
T.eq(mentions.sanitize("look " .. ITEM_LINK), "look " .. ITEM_LINK, "an item link and a colour code stay")
T.eq(mentions.sanitize("|cnIQ1:|Hitem:4603::|h[Raw Spotted Yellowtail]|h|r"),
  "|cnIQ1:|Hitem:4603::|h[Raw Spotted Yellowtail]|h|r", "a named colour stays")
T.eq(mentions.sanitize("a | b"), "a || b", "a lone | is doubled")
T.eq(mentions.sanitize("ends with |"), "ends with ||", "also at the end")
T.eq(mentions.sanitize("a || b"), "a || b", "a doubled | stays as it is")
T.eq(mentions.sanitize("|TInterface\\Icons\\x:64|t big"), "||TInterface\\Icons\\x:64||t big",
  "a texture escape is doubled")
T.eq(mentions.sanitize("line|nbreak"), "line||nbreak", "and so is a line break")
T.eq(mentions.sanitize("|Hitem:1|h[|TInterface\\x:64|t Sword]|h"), "|Hitem:1|h[||TInterface\\x:64||t Sword]|h",
  "a texture inside the text of a link is doubled")
T.eq(mentions.sanitize("|Hitem:1|h[cut off"), "||Hitem:1||h[cut off", "a link that does not end is no link")
T.eq(mentions.sanitize("|cffff0000red"), "|cffff0000red|r", "a colour that is left open is closed")
T.eq(mentions.sanitize("|cffff0000red|r|r"), "|cffff0000red|r|r", "a spare |r stays")

--------------------------------------------------------------------------------
-- Step 11.2: the mention list
--------------------------------------------------------------------------------

local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local DAY = 86400
local TABLE = "guildchat"

---Puts a chat record of another origin into a replica, as a pull or a push does.
---@param replica TestReplica
---@param time integer Server time of the line
---@param origin string
---@param sender string
---@param text string
---@return string id
local function receive(replica, time, origin, sender, text)
  local id = replica.ns.versionId.make(time, origin, 0)
  local changed = replica.sync:ApplyRemote(TABLE, { { key = id, id = id, payload = { s = sender, t = text } } })
  T.eq(changed, { id }, "the record of the test is applied")
  return id
end

---Returns the mentions of a replica's user as `{ fragments joined, isRead }`, newest first.
---@param replica TestReplica
---@return table[]
local function listed(replica)
  local result = {}
  for index, entry in ipairs(replica.ns.mentions:List()) do
    result[index] = { table.concat(entry.fragments, " "), entry.isRead }
  end
  return result
end

---Counts the entries of the stored list of a replica.
---@param replica TestReplica
---@return integer
local function entries(replica)
  local count = 0
  for _ in pairs(replica.mentionStore.lines) do
    count = count + 1
  end
  return count
end

-- A replica that joins after three lines were written, two with a watched @ word, lists the two as unread
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Nota Tall", { random = random })
  b.watch = "tall"
  net:SetOnline("Nota Tall", false)
  a:Login()
  net:Advance(100)
  a:Hear("@tall hello", "Nota Scam")
  net:Advance(3)
  a:Hear("nothing here", "Nota Scam")
  net:Advance(3)
  local last = a:Hear("look @Tall " .. ITEM_LINK, "Nota Scam")
  net:Advance(2 * 3600)
  local changes = 0
  b.ns.mentions.RegisterCallback(b, "OnMentionsChanged", function(_event, newId)
    changes = changes + (newId and 1 or 0)
  end)
  b:Login()
  T.eq(listed(b), {}, "before the pull the list is empty")
  net:Advance(600)
  T.eq(listed(b), { { "@Tall", false }, { "@tall", false } }, "after the pull it lists the two mentions, newest first")
  T.eq(b.ns.mentions:UnreadCount(), 2, "both are unread")
  T.eq(changes, 2, "the callback has named each new entry once")
  local entry = b.ns.mentions:List()[1]
  T.eq({ entry.id, entry.sender, entry.text, entry.time }, { last, "Nota Scam", "look @Tall " .. ITEM_LINK,
    (b.ns.versionId.parse(last)) }, "an entry has the id, the sender, the text, and the time of its line")
  T.eq(entries(b), 2, "the stored list holds the two lines with an @ word")
  T.eq(listed(a), {}, "the writer watches nothing and lists nothing")
  T.eq(a.mentionStore.lines[last], true, "and its own lines are stored as read")

  -- MarkRead, and the flag over a new login
  T.eq(b.ns.mentions:MarkRead(last), true, "MarkRead changes an unread entry")
  T.eq(b.ns.mentions:MarkRead(last), false, "and not a read one")
  T.eq(b.ns.mentions:MarkRead("no such id"), false, "nor an id without an entry")
  T.eq(listed(b), { { "@Tall", true }, { "@tall", false } }, "the entry is read, the other is not")
  T.eq(b.ns.mentions:UnreadCount(), 1, "one is still unread")
  b:Logout()
  net:Advance(3600)
  b:Login()
  T.eq(listed(b), { { "@Tall", true }, { "@tall", false } }, "both flags stay over a new login")
end

-- An unwatched @ word is stored and not listed, until the word is watched
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a.watch = "tall"
  a:Login()
  local now = math.floor(net:Now())
  receive(a, now - 500, "XXXX", "Other One", "@kvakvs are you there")
  receive(a, now - 400, "XXXX", "Other One", "no mention")
  T.eq(entries(a), 1, "the line with an unwatched @ word is in the stored list")
  T.eq(listed(a), {}, "and not in List")
  a.watch = "tall, KVAKVS"
  T.eq(listed(a), { { "@kvakvs", false } }, "after the word is added to the watch list it is")
  a.watch = ""
  T.eq({ listed(a), a.ns.mentions:UnreadCount() }, { {}, 0 }, "an empty watch list gives an empty list")
end

-- Read or unread at arrival
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Tall", { random = random })
  a.watch = "tall"
  a:Login()
  net:Advance(1000)
  local wasOnline = math.floor(net:Now()) - 500
  a:Logout()
  local logoutAt = math.floor(net:Now())
  T.eq(a.mentionStore.lastOnline, logoutAt, "the logout writes lastOnline")
  net:Advance(5000)
  a:Login()
  local loginAt = math.floor(net:Now())
  net:Advance(100)
  T.eq(a.mentionStore.lastOnline, loginAt, "and so does the login")
  local own = a:Hear("note to self: @tall", "Nota Tall")
  T.eq(a.mentionStore.lines[own], true, "a line of the own character is added as read")
  local seen = receive(a, wasOnline, "XXXX", "Other One", "@tall while you were here")
  T.eq(a.mentionStore.lines[seen], true, "a line from a time at which the account was online is added as read")
  local missed = receive(a, logoutAt + 2000, "XXXX", "Other One", "@tall while you were away")
  T.eq(a.mentionStore.lines[missed], false, "a line from after lastOnline and before the login is added as unread")
  local live = receive(a, loginAt + 50, "XXXX", "Other One", "@tall right now")
  T.eq(a.mentionStore.lines[live], true, "a line from after the login was seen in chat and is added as read")
  T.eq(listed(a), { { "@tall", true }, { "@tall", true }, { "@tall", false }, { "@tall", true } },
    "the list has the four, newest first")
end

-- Two records of one line are one mention; reading it marks both
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Tall", { random = random })
  a.watch = "tall"
  net:Advance(5000)
  a:Login()
  local now = math.floor(net:Now())
  local first = receive(a, now - 1000, "XXXX", "No Addon", "@tall written twice")
  local second = receive(a, now - 900, "YYYY", "No Addon", "@tall written twice")
  T.eq(entries(a), 2, "both records have an entry")
  T.eq(listed(a), { { "@tall", false } }, "and are one mention")
  T.eq(a.ns.mentions:List()[1].id, first, "with the id of the earliest record")
  a.ns.mentions:MarkRead(first)
  T.eq({ a.mentionStore.lines[first], a.mentionStore.lines[second] }, { true, true }, "reading it marks both records")
end

-- An entry of 15 days ago is gone after Expire
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a.watch = "tall"
  a:Login()
  -- The session would expire the table every hour by itself; the mention list stays connected
  a:Logout()
  a:Hear("@tall of 15 days ago", "Nota Scam")
  net:Advance(2 * DAY)
  a:Hear("@tall of 13 days ago", "Nota Scam")
  net:Advance(13 * DAY)
  T.eq(#listed(a), 2, "both mentions are listed")
  a.sync:Expire(TABLE)
  T.eq(entries(a), 1, "the entry of 15 days ago is gone after Expire")
  T.eq(a.ns.mentions:List()[1].text, "@tall of 13 days ago", "the one of 13 days stays")
  a.sync:Reset(TABLE)
  T.eq(entries(a), 0, "the reset of the table empties the list")
end

-- At login, entries without a record are dropped, and a record without an entry gets one
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Tall", { random = random })
  a.watch = "tall"
  a:Login()
  net:Advance(100)
  local kept = receive(a, math.floor(net:Now()) - 50, "XXXX", "Other One", "@tall one")
  local lost = receive(a, math.floor(net:Now()) - 40, "XXXX", "Other One", "@tall two")
  receive(a, math.floor(net:Now()) - 30, "XXXX", "Other One", "three, no mention")
  a:Logout()
  local stale = a.ns.versionId.make(math.floor(net:Now()) - 20, "XXXX", 0)
  a.mentionStore.lines[stale] = false
  a.mentionStore.lines[lost] = nil
  a.mentionStore.lines[kept] = true
  a.mentionStore.lines.broken = "yes"
  net:Advance(100)
  a:Login()
  T.eq(a.mentionStore.lines[stale], nil, "an entry without a record is dropped at login")
  T.eq(a.mentionStore.lines.broken, nil, "and so is one that is no flag")
  T.eq(a.mentionStore.lines[lost], true, "a record with an @ word and no entry gets one; it is from the online time")
  T.eq(a.mentionStore.lines[kept], true, "an entry with a record keeps its flag")
  T.eq(entries(a), 2, "the line without an @ word has no entry")
end

--------------------------------------------------------------------------------
-- Step 11.4: the notice
--------------------------------------------------------------------------------

local NOTICE = mentions.noticeText(false)
T.ok(NOTICE:find("Type /oooo chat to open recent mentions.", 1, true), "without a link the notice names the command")
T.ok(mentions.noticeText(true):find("|Haddon:OOOOguildcompanion:mentions|h[Click to open recent mentions]|h", 1,
  true), "with a link its last words are the link")

---Counts the notices about mentions that a replica has printed.
---@param replica TestReplica
---@return integer
local function noticeCount(replica)
  local count = 0
  for _, line in ipairs(replica.notices) do
    if line == NOTICE then
      count = count + 1
    end
  end
  return count
end

---Makes a writer and a reader who watches `tall` and is offline.
---@return Fakenet net
---@return TestReplica writer "Nota Scam", logged in
---@return TestReplica reader "Nota Tall", offline
local function writerAndReader()
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Nota Tall", { random = random })
  b.watch = "tall"
  net:SetOnline("Nota Tall", false)
  a:Login()
  net:Advance(100)
  return net, a, b
end

-- A pull of several batches gives one notice
do
  local net, a, b = writerAndReader()
  for index = 1, 60 do
    a:Hear("@tall line " .. index .. " " .. string.rep("x", 60), "Nota Scam")
    net:Advance(2)
  end
  net:Advance(3600)
  local loginAt = net:Now()
  b:Login()
  net:Advance(1200)
  T.ok(Replica.count(net, "D", "Nota Scam", loginAt) > 1, "the pull had several batches")
  T.eq(b.ns.mentions:UnreadCount(), 60, "the reader holds 60 unread mentions")
  T.eq(noticeCount(b), 1, "and got one notice, not one per batch")
  T.eq(noticeCount(a), 0, "the writer got none")

  -- A second sync without a new unread entry gives no second notice
  a:Hear("no mention this time", "Nota Scam")
  a:Hear("@kvakvs is not watched by the reader", "Nota Scam")
  net:Advance(1200)
  T.eq(#b.ns.guildChat:Lines(), 62, "the reader has received the two new lines")
  T.eq(noticeCount(b), 1, "a sync without a new mention of the reader gives no second notice")
  a:Hear("@tall live", "Nota Scam")
  net:Advance(1200)
  T.eq({ b.ns.mentions:UnreadCount(), noticeCount(b) }, { 60, 1 },
    "a mention from the online time is read and gives no notice")

  -- After a reload: the unread entries are still unread, and no notice is printed
  b:Logout()
  b:Login()
  net:Advance(600)
  T.eq({ b.ns.mentions:UnreadCount(), noticeCount(b) }, { 60, 1 }, "a reload repeats no notice")

  -- A new unread entry gives the next notice
  b:Logout()
  net:Advance(600)
  a:Hear("@tall again", "Nota Scam")
  net:Advance(600)
  b:Login()
  net:Advance(1200)
  T.eq({ b.ns.mentions:UnreadCount(), noticeCount(b) }, { 61, 2 }, "a new unread mention gives the next notice")
end

-- No notice for an unread entry that does not concern the user, and none with an empty watch list
do
  local net, a, b = writerAndReader()
  a:Hear("@kvakvs hello", "Nota Scam")
  net:Advance(3600)
  b:Login()
  net:Advance(1200)
  T.eq(b.mentionStore.lines[b.ns.guildChat:Lines()[1].id], false, "the reader holds the line as an unread entry")
  T.eq(noticeCount(b), 0, "an unread entry that does not concern the user gives no notice")

  local c = Replica.new(net, "Third One", { random = random })
  net:SetOnline("Third One", false)
  a:Hear("@tall hello", "Nota Scam")
  net:Advance(3600)
  c:Login()
  net:Advance(1200)
  T.eq({ #c.ns.guildChat:Lines(), noticeCount(c) }, { 2, 0 }, "an empty watch list gives no notice")
end

-- The notice after login, and the setting that turns it off
for _, notifyOnLogin in ipairs({ true, false }) do
  local net, a, b = writerAndReader()
  b.notifyOnLogin = notifyOnLogin
  a:Hear("@tall hello", "Nota Scam")
  net:Advance(3600)
  b:Login()
  -- The lines arrive, and the reader leaves before the notice is due
  local waited = 0
  while #b.ns.guildChat:Lines() == 0 and waited < 600 do
    net:Advance(1)
    waited = waited + 1
  end
  T.eq({ b.ns.mentions:UnreadCount(), noticeCount(b) }, { 1, 0 }, "the mention has arrived; its notice is not due yet")
  b:Logout()
  net:Advance(600)
  T.eq(noticeCount(b), 0, "a reader who has left gets no notice")
  -- The writer leaves too: the next session of the reader brings nothing new
  a:Logout()
  b:Login()
  net:Advance(mentions.LOGIN_NOTICE_DELAY - 1)
  T.eq(noticeCount(b), 0, "nothing is printed right after the login")
  net:Advance(600)
  T.eq(noticeCount(b), notifyOnLogin and 1 or 0, notifyOnLogin
    and "the login gives the notice for the unread mention of the earlier session"
    or "with the setting off, the login gives no notice for old unread mentions")
  if not notifyOnLogin then
    b:Logout()
    a:Login()
    net:Advance(100)
    a:Hear("@tall once more", "Nota Scam")
    net:Advance(600)
    b:Login()
    net:Advance(1200)
    T.eq({ b.ns.mentions:UnreadCount(), noticeCount(b) }, { 2, 1 }, "and a sync that brings a new one still does")
  end
end

-- Outside the guild nothing is printed
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Tall", { random = random })
  local printed = {}
  local inGuild = false
  local store = { lines = {} }
  net:Advance(5000)
  a.ns.mentions:Attach({
    store = store,
    watch = function()
      return "tall"
    end,
    now = function()
      return math.floor(net:Now())
    end,
    playerName = function()
      return "Nota Tall"
    end,
    after = function(seconds, fn)
      return a.endpoint:After(seconds, fn)
    end,
    inGuild = function()
      return inGuild
    end,
    print = function(text)
      printed[#printed + 1] = text
    end,
    linkUsable = true,
  })
  receive(a, math.floor(net:Now()) - 1000, "XXXX", "Other One", "@tall hello")
  net:Advance(60)
  T.eq(printed, {}, "while the guild check has not passed, no notice is printed")
  inGuild = true
  T.eq(a.ns.mentions:CheckNotice(), true, "in the guild the check prints it")
  T.eq(printed, { mentions.noticeText(true) }, "with the link, when the client can pass its click")
  T.eq(a.ns.mentions:CheckNotice(), false, "and a second check prints nothing")
end

-- The window: a click on a mention that is older than the loaded lines
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Tall", { random = random })
  a.watch = "tall"
  net:Advance(5000)
  a:Login()
  local now = math.floor(net:Now())
  local old = receive(a, now - 4000, "XXXX", "Other One", "an old line for @Tall")
  for index = 1, 250 do
    receive(a, now - 3000 + index * 10, "XXXX", "Other One", "line " .. index)
  end
  local history = a.ns.chatHistory
  history:Open()
  T.eq({ #history.lines, history:IndexOf(old) }, { 100, nil }, "the window opens without the old line")
  local entry = a.ns.mentions:List()[1]
  T.eq({ entry.id, entry.isRead, entry.fragments }, { old, false, { "@Tall" } }, "the side list has the unread mention")
  -- What a click on the entry does
  local index = history:Highlight(entry.id)
  a.ns.mentions:MarkRead(entry.id)
  T.eq({ index, #history.lines, history.highlightId }, { 1, 251, old },
    "the history is loaded back to the line, and the line is highlighted")
  T.eq(a.ns.mentions:List()[1].isRead, true, "and the mention is read")
  history:Close()
end

T.finish()
