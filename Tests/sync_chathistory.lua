-- Host test of the chat history (.agents/00-plan.md, step 11.3): `ns.guildChat:Page` in
-- Addon/Src/Sync/SyncGuildChat.lua and the model of the window in Addon/Src/Chat/ChatHistory.lua.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
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

---Makes a replica that holds `count` chat lines, 10 seconds apart, with the texts "line 1" to "line <count>".
---@param count integer
---@return TestReplica replica
---@return string[] ids The ids of the lines, in order
---@return integer start Server time of the first line
local function replicaWith(count)
  local net = Fakenet.new({ random = random })
  local replica = Replica.new(net, "Nota Scam", { random = random })
  local start = math.floor(net:Now()) - 10 * count - 1000
  local ids = {}
  for index = 1, count do
    ids[index] = receive(replica, start + 10 * index, "XXXX", "Other One", "line " .. index)
  end
  return replica, ids, start
end

---Returns the texts of lines.
---@param lines table[]
---@return string[]
local function texts(lines)
  local result = {}
  for index, line in ipairs(lines) do
    result[index] = line.text
  end
  return result
end

---Returns the texts "line <first>" to "line <last>".
---@param first integer
---@param last integer
---@return string[]
local function range(first, last)
  local result = {}
  for index = first, last do
    result[#result + 1] = "line " .. index
  end
  return result
end

-- Page
do
  local a, ids = replicaWith(250)
  local chat = a.ns.guildChat
  local page, hasOlder = chat:Page(nil, 100)
  T.eq(texts(page), range(151, 250), "the first page is the newest 100 of 250 lines, in order")
  T.eq(hasOlder, true, "and older lines exist")
  T.eq({ page[1].id, page[1].time, page[1].sender }, { ids[151], (a.ns.versionId.parse(ids[151])), "Other One" },
    "a line of a page has its id, its time, and its sender")
  page, hasOlder = chat:Page(page[1].id, 100)
  T.eq({ texts(page), hasOlder }, { range(51, 150), true }, "the next page is the 100 before")
  page, hasOlder = chat:Page(page[1].id, 100)
  T.eq({ texts(page), hasOlder }, { range(1, 50), false }, "the last page has 50 lines and no older ones")
  page, hasOlder = chat:Page(page[1].id, 100)
  T.eq({ page, hasOlder }, { {}, false }, "before the first line there is nothing")
  page, hasOlder = chat:Page(nil, 250)
  T.eq({ #page, hasOlder }, { 250, false }, "a page of all lines has no older ones")
  T.eq(texts(chat:Page(nil, 400)), texts(chat:Lines()), "and equals Lines")
end

-- Page: an empty table
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local page, hasOlder = a.ns.guildChat:Page(nil, 100)
  T.eq({ page, hasOlder }, { {}, false }, "an empty table gives an empty page")
end

-- Page joins double records like Lines, at every place of a page border
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local now = math.floor(net:Now())
  local start = now - 5000
  local senders = { "Other One", "Third One" }
  local saidTexts = { "gz", "hello", "anyone for BRD?" }
  -- Few senders and texts in a short time: many records repeat an earlier one within the window
  for index = 1, 120 do
    receive(a, start + index * 20 + random(0, 15), a.ns.base94.encode(index, 4), senders[random(1, 2)],
      saidTexts[random(1, 3)])
  end
  local all = a.ns.guildChat:Lines()
  T.ok(#all < 120 and #all > 10, "the table holds joined records (" .. #all .. " lines of 120 records)")
  for _, size in ipairs({ 1, 3, 7, 50 }) do
    local paged = {}
    local beforeId, hasOlder = nil, true
    while hasOlder do
      local page
      page, hasOlder = a.ns.guildChat:Page(beforeId, size)
      for index = #page, 1, -1 do
        table.insert(paged, 1, page[index].id)
      end
      beforeId = page[1] and page[1].id
      T.ok(#page == size or not hasOlder, "a page is full while older lines exist")
    end
    local expected = {}
    for index, line in ipairs(all) do
      expected[index] = line.id
    end
    T.eq(paged, expected, "pages of " .. size .. " lines give the lines of Lines")
  end
end

-- The model: LoadOlder
do
  local a, ids = replicaWith(250)
  local history = a.ns.chatHistory
  T.eq({ history.isOpen, history.lines }, { false, {} }, "a closed history holds no lines")
  T.eq(history:LoadOlder(), 0, "and loads none")
  history:Open()
  T.eq({ texts(history.lines), history.hasOlder }, { range(151, 250), true }, "it opens with the last 100 lines")
  T.eq(history:LoadOlder(), 100, "LoadOlder adds 100 lines")
  T.eq(history:LoadOlder(), 50, "then the 50 that are left")
  T.eq(history:LoadOlder(), 0, "then nothing")
  T.eq({ texts(history.lines), history.hasOlder }, { range(1, 250), false },
    "three times LoadOlder gives all 250 lines once, in order")
  T.eq(history:IndexOf(ids[200]), 200, "IndexOf finds a loaded line")
  history:Close()
  T.eq({ history.isOpen, history.lines, history.hasOlder }, { false, {}, false }, "Close forgets the lines")
end

-- The model: LoadBackTo and the highlight
do
  local a, ids = replicaWith(450)
  local history = a.ns.chatHistory
  history:Open()
  T.eq(history:IndexOf(ids[120]), nil, "a line that is older than the loaded ones is not found")
  T.eq(history:LoadBackTo(ids[420]), 70, "LoadBackTo of a loaded line loads nothing and gives its place")
  T.eq(#history.lines, 100, "the first page is still all")
  local index = history:LoadBackTo(ids[120])
  T.eq(texts(history.lines), range(51, 450), "LoadBackTo loads whole pages up to and with the given line")
  T.eq({ index, history.lines[index].id }, { 70, ids[120] }, "and gives its place")
  T.eq(history:Highlight(ids[60]), 10, "Highlight of a loaded line gives its place")
  T.eq(history.highlightId, ids[60], "and sets the highlight")
  local missing = a.ns.versionId.make(a.ns.versionId.parse(ids[1]) - 500, "XXXX", 0)
  T.eq(history:Highlight(missing), nil, "a line that the table does not hold is not found")
  T.eq({ history.highlightId, #history.lines, history.hasOlder }, { nil, 450, false },
    "the highlight is off, and everything was loaded in the search")
end

-- The model: lines that arrive
do
  local a, ids, start = replicaWith(150)
  local history = a.ns.chatHistory
  local changes = 0
  history.onChanged = function()
    changes = changes + 1
  end
  local now = math.floor(a.net:Now())
  receive(a, now - 300, "YYYY", "Third One", "before the window opens")
  T.eq(changes, 0, "a closed history ignores the table")
  history:Open()
  T.eq(#history.lines, 100, "it opens with 100 lines")
  local own = a:Hear("an own line", "Nota Scam")
  T.eq({ changes, #history.lines, history.lines[101].id, history.lines[101].text, history.isDirty },
    { 1, 101, own, "an own line", false }, "a line that arrives is added at the end")
  T.eq(history:Refresh(), false, "and nothing has to be read again")

  -- Two records of one line: the second one of a pair within the window is no new line
  a.net:Advance(3000)
  now = math.floor(a.net:Now())
  receive(a, now - 2000, "XXXX", "No Addon", "written twice")
  receive(a, now - 1940, "YYYY", "No Addon", "written twice")
  T.eq({ changes, #history.lines }, { 2, 102 }, "two records of one line are one line")
  receive(a, now - 1600, "ZZZZ", "No Addon", "written twice")
  T.eq(#history.lines, 103, "the same text after the window is a line of its own")
  T.eq(texts(history.lines), texts(a.ns.guildChat:Page(nil, 103)), "the loaded lines equal a page of the table")

  -- A pull brings an older line of another origin: it belongs between the loaded lines
  history:Highlight(ids[100])
  receive(a, start + 10 * 120 + 5, "YYYY", "Third One", "between 120 and 121")
  T.eq({ changes, history.isDirty, #history.lines }, { 4, true, 103 }, "an older line marks the history for a reload")
  a:Hear("after the old one", "Nota Scam")
  T.eq(#history.lines, 103, "while it waits for the reload nothing is added at the end")
  T.eq(history:Refresh(), true, "Refresh reads the lines again")
  T.eq(texts(history.lines), texts(a.ns.guildChat:Page(nil, 103)), "the newest lines, as many as were loaded")
  local place = history:IndexOf(ids[120])
  T.eq(history.lines[place + 1].text, "between 120 and 121", "with the older line at its place")
  T.eq(history.lines[#history.lines].text, "after the old one", "and the newest one at the end")
  T.eq(history.highlightId, ids[100], "the highlight stays on its line")

  -- The record of a line that was written twice is found at the line that is shown
  a.net:Advance(1000)
  now = math.floor(a.net:Now())
  local shown = receive(a, now - 200, "XXXX", "No Addon", "@tall twice")
  local second = receive(a, now - 100, "YYYY", "No Addon", "@tall twice")
  T.eq(history:IndexOf(second), history:IndexOf(shown), "the second record of a line leads to the shown line")

  -- The expiry removes the old lines
  a.net:Advance(15 * 86400)
  a.sync:Expire(TABLE)
  T.eq(history.isDirty, true, "a removed line marks the history for a reload")
  history:Refresh()
  T.eq({ history.lines, history.hasOlder, history.highlightId }, { {}, false, nil },
    "after the expiry of all lines the history is empty and the highlight is off")
end

-- The text of a line
do
  local a = replicaWith(1)
  local history = a.ns.chatHistory
  local formatTime = history.formatTime
  history.formatTime = function(time, now)
    return "t" .. (now - time)
  end
  local link = "|cff0070dd|Hitem:4306::::::::60:::::|h[Silk Cloth]|h|r"
  T.eq(history:LineText({ id = "x", time = 940, sender = "Nota Scam", text = "hello", bySender = true }, 1000),
    "|cff9d9d9d[t60]|r Nota Scam: hello", "the time of the id, the sender, and the text")
  T.eq(history:LineText({ id = "x", time = 1000, sender = "Bad|TName", text = "look " .. link .. " |Tx:64|t",
    bySender = false }, 1000),
    "|cff9d9d9d[t0]|r Bad||TName: look " .. link .. " ||Tx:64||t", "the sender and the text are sanitized")
  history.formatTime = formatTime
  local now = os.time({ year = 2026, month = 11, day = 18, hour = 15, min = 30 })
  T.eq(formatTime(now - 3600, now), "14:30", "a line of today shows hour and minute")
  T.eq(formatTime(now - 86400, now), "17.11 15:30", "a line of another day shows the day too")
end

T.finish()
