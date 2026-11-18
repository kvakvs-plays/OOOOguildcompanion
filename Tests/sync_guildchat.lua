-- Host test of the table `guildchat` (.agents/00-plan.md, section 5.3 and stage 10;
-- Addon/Src/Sync/SyncGuildChat.lua): which lines a replica writes, what `validate` refuses, the ordered
-- reading with joined double records, the retention, and the path of the member who was offline.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local codec = Replica.codec
local DAY = 86400
local TABLE = "guildchat"

---Returns the texts of the stored lines of a replica, in their order.
---@param replica TestReplica
---@param sinceTime integer?
---@return string[]
local function texts(replica, sinceTime)
  local result = {}
  for index, line in ipairs(replica.ns.guildChat:Lines(sinceTime)) do
    result[index] = line.text
  end
  return result
end

---Counts the stored records of the table, live ones and tombstones.
---@param replica TestReplica
---@return integer
local function stored(replica)
  local live, deleted = replica.sync:Count(TABLE)
  return live + deleted
end

---Puts a chat record of another origin into a replica, as a pull or a push does.
---@param replica TestReplica
---@param time integer Server time of the line
---@param origin string
---@param sender string
---@param text string
---@param counter integer?
---@return string id
local function receive(replica, time, origin, sender, text, counter)
  local id = replica.ns.versionId.make(time, origin, counter or 0)
  local changed = replica.sync:ApplyRemote(TABLE, { { key = id, id = id, payload = { s = sender, t = text } } })
  T.eq(changed, { id }, "the record of the test is applied")
  return id
end

---Writes the record of a replica's character into the table `character`, as the addon does at login. The
---origin of the replica then belongs to that character.
---@param replica TestReplica
local function writeCharacter(replica)
  T.eq(replica.sync:Put("character", replica.name,
    replica.ns.syncCharacter.buildPayload("MAGE", 10, replica.sync:GetOrigin())), true, "the character is written")
end

-- A line of the own character is stored; a line of another sender is not
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local id = a:Hear("hello guild", "Nota Scam")
  T.ok(id, "an own line gives the id of its record")
  T.eq(a.sync:Get(TABLE, id), { s = "Nota Scam", t = "hello guild" }, "the record holds the sender and the text")
  T.eq(a.sync:GetTable(TABLE).records[id].v, id, "the key of the record is its own id")
  T.eq(a.ns.versionId.parse(id), math.floor(net:Now()), "the time of the line is the timestamp of the id")
  T.eq(a:Hear("hello back", "Other One"), nil, "a line of another sender is not written")
  T.eq(stored(a), 1, "one record is stored")
  -- Forever gives no realm suffix; one is cut off in case that changes
  local suffixed = a:Hear("with a realm", "Nota Scam-Realm")
  T.eq(a.sync:Get(TABLE, suffixed).s, "Nota Scam", "a realm suffix of the sender is cut off")
  T.eq(a:Hear("", "Nota Scam"), nil, "an empty text is not written")
  T.eq(a:Hear(string.rep("x", 256), "Nota Scam"), nil, "nor a text that is longer than a chat message")
  T.eq(a:Hear(nil, "Nota Scam"), nil, "nor an event without a text")
  T.eq(a:Hear("text", nil), nil, "nor one without a sender")
  T.eq(stored(a), 2, "nothing else was stored")
  T.ok(a.sync.dirtySince[TABLE], "the table has unsent changes")
  T.eq(a.sync.definitions[TABLE].maxAge, 14 * DAY, "the table keeps 14 days")
  T.eq(a.ns.guildChat.KEEP_DAYS, 14, "by the constant KEEP_DAYS")
end

-- A secret sender or text stores nothing
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local SECRET = setmetatable({}, { __eq = function()
    error("a secret value was compared")
  end, __concat = function()
    error("a secret value was concatenated")
  end })
  local plain = _G.issecretvalue
  _G.issecretvalue = function(value)
    return rawequal(value, SECRET)
  end
  T.eq(a:Hear(SECRET, "Nota Scam"), nil, "a secret text is not recorded")
  T.eq(a:Hear("text", SECRET), nil, "a secret sender is not recorded")
  T.ok(a:Hear("text", "Nota Scam"), "a plain line still is")
  _G.issecretvalue = plain
  T.eq(stored(a), 1, "only the plain line is stored")
end

-- validate
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local validate = a.ns.guildChat.validate
  local id = a.ns.versionId.make(math.floor(net:Now()), "XXXX", 0)
  T.eq(validate(id, { s = "Nota Scam", t = "text" }), true, "a sender and a text are good")
  T.eq(validate(id, { s = "Nota Scam", t = string.rep("x", 255) }), true, "a text of 255 bytes is good")
  T.eq(validate(id, { s = string.rep("n", 48), t = "text" }), true, "a sender of 48 bytes is good")
  T.eq(validate(id, { t = "text" }), false, "a missing sender is refused")
  T.eq(validate(id, { s = "", t = "text" }), false, "an empty sender is refused")
  T.eq(validate(id, { s = string.rep("n", 49), t = "text" }), false, "a sender of 49 bytes is refused")
  T.eq(validate(id, { s = "Nota Scam" }), false, "a missing text is refused")
  T.eq(validate(id, { s = "Nota Scam", t = "" }), false, "an empty text is refused")
  T.eq(validate(id, { s = "Nota Scam", t = string.rep("x", 256) }), false, "a text of 256 bytes is refused")
  T.eq(validate(id, { s = "Nota Scam", t = 5 }), false, "a text that is no string is refused")
  T.eq(validate(id, { s = "Nota Scam", t = "text", time = 5 }), false, "another field is refused")
  T.eq(validate(id, "text"), false, "a payload that is no table is refused")
  T.eq(validate("some key", { s = "Nota Scam", t = "text" }), false, "a key that is no id is refused")
end

-- Lines: the id order, also after records arrive out of order, and double records joined
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local chat = a.ns.guildChat
  local now = math.floor(net:Now())
  T.eq(chat:Lines(), {}, "an empty table has no lines")
  receive(a, now - 1000, "XXXX", "Other One", "third")
  -- The list of keys exists from here on and must follow the table
  T.eq(texts(a), { "third" }, "one line")
  receive(a, now - 3000, "YYYY", "Third One", "first")
  receive(a, now - 2000, "ZZZZ", "Fourth One", "second")
  local own = a:Hear("fourth", "Nota Scam")
  T.eq(texts(a), { "first", "second", "third", "fourth" }, "the lines are in id order, whatever the arrival")
  local lines = chat:Lines()
  T.eq({ lines[1].time, lines[1].sender, lines[4].id }, { now - 3000, "Third One", own },
    "a line has its time, its sender, and its id")
  T.eq(texts(a, now - 2000), { "second", "third", "fourth" }, "Lines(sinceTime) starts at that time")
  T.eq(texts(a, now + 100), {}, "and is empty for a time after the last line")

  -- Two replicas wrote one line: same sender and text, ids 2 minutes apart
  local early = receive(a, now - 500, "XXXX", "No Addon", "same text")
  receive(a, now - 380, "YYYY", "No Addon", "same text")
  T.eq(texts(a), { "first", "second", "third", "same text", "fourth" }, "records 2 minutes apart are one line")
  T.eq(chat:Lines()[4].id, early, "the earliest record is the one that is shown")
  T.eq(texts(a, now - 400), { "fourth" }, "a double record is not a line of its own after sinceTime either")
  -- 4 minutes apart: the member said it twice
  receive(a, now - 260, "ZZZZ", "No Addon", "same text")
  T.eq(texts(a), { "first", "second", "third", "same text", "same text", "fourth" },
    "records 4 minutes apart are two lines")
  -- Same sender, different texts, 2 seconds apart
  receive(a, now - 100, "XXXX", "No Addon", "one")
  receive(a, now - 98, "XXXX", "No Addon", "two")
  -- Same text, another sender, in the same second
  receive(a, now - 98, "YYYY", "Third One", "two")
  T.eq(texts(a, now - 150), { "one", "two", "two", "fourth" }, "other texts and other senders stay lines of their own")

  -- A record under a key that is not its id has no place in time
  local forged = a.ns.versionId.make(now - 50, "XXXX", 0)
  a.sync:ApplyRemote(TABLE, { { key = a.ns.versionId.make(now - 2500, "XXXX", 0), id = forged,
    payload = { s = "Other One", t = "forged" } } })
  T.eq(#texts(a), 9, "a record whose key is not its id is no line")
end

-- The output of /oooo sync chat
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local now = math.floor(net:Now())
  local link = "look |cff0070dd|Hitem:4306::::::::60:::::|h[Silk Cloth]|h|r"
  writeCharacter(a)
  receive(a, now - 7200, "XXXX", "Other One", "old line")
  receive(a, now - 90, "XXXX", "Other One", link)
  a:Hear("own line", "Nota Scam")
  T.eq(a.ns.guildChat:PrintLines(2, now), {
    "guild chat: 3 lines stored, the last 2:",
    "  1 min ago Other One (witness): look ||cff0070dd||Hitem:4306::::::::60:::::||h[Silk Cloth]||h||r",
    "  0 s ago Nota Scam: own line",
  }, "the last lines with their age, every | doubled, and a mark on a line that its sender did not write")
  T.eq(#a.ns.guildChat:PrintLines(10, now), 4, "a count over the number of lines prints all")
  a.ns.syncSlash:Dispatch("chat 1")
  T.eq(a.notices, { "guild chat: 3 lines stored, the last 1:", "  0 s ago Nota Scam: own line" },
    "the slash command prints them")
  a.ns.syncSlash:Dispatch("chat many")
  T.eq(a.notices[#a.notices], "Usage: /oooo sync chat [count]", "a count that is no number prints the usage")
end

-- A line of 15 days ago is gone after Expire; one of 13 days stays
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  a:Hear("of 15 days ago", "Nota Scam")
  net:Advance(2 * DAY)
  a:Hear("of 13 days ago", "Nota Scam")
  net:Advance(13 * DAY)
  T.eq(texts(a), { "of 15 days ago", "of 13 days ago" }, "both lines are stored")
  local before = a:Version(TABLE)
  a.sync:Expire(TABLE)
  T.eq(texts(a), { "of 13 days ago" }, "the line of 15 days ago is gone, the one of 13 days stays")
  T.eq(a:Version(TABLE), before, "without a change of the table version")
  -- The session does the same when the stay in the guild starts
  net:Advance(2 * DAY)
  a:Login()
  T.eq(texts(a), {}, "the session removes what has grown old")
end

-- A replica that joins 2 hours after three lines were written holds them after its pull
do
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Other One", { random = random })
  net:SetOnline("Other One", false)
  a:Login()
  net:Advance(100)
  local said = { "plain line", "with an emoji :kekw: name",
    "with a link |cff0070dd|Hitem:4306::::::::60:::::|h[Silk Cloth]|h|r" }
  for _, text in ipairs(said) do
    a:Hear(text, "Nota Scam")
    net:Advance(3)
  end
  net:Advance(2 * 3600)
  b:Login()
  net:Advance(600)
  T.eq(texts(b), said, "the replica that was offline holds the three lines, in order, with the original text")
  T.eq(b:Version(TABLE), a:Version(TABLE), "and the table version of the writer")
  T.eq(Replica.count(net, "Q", "Other One"), 1, "after one pull")
  local lines = b.ns.guildChat:Lines()
  T.eq({ lines[1].sender, lines[3].sender }, { "Nota Scam", "Nota Scam" }, "with the sender")
end

---Runs the race after a login: B was away while A wrote 50 lines. B comes back, hears a push of A with 2
---new lines, and writes an own line, all before its first pull.
---@param cut boolean true: the first pull of B loses its second batch
local function raceAfterLogin(cut)
  local net = Fakenet.new({ random = random })
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Other One", { random = random })
  a:Login()
  b:Login()
  net:Advance(100)
  a:Hear("before B left", "Nota Scam")
  net:Advance(1000)
  T.eq(texts(b), { "before B left" }, "B holds the line that A wrote while both were online")
  b:Logout()
  local expected = { "before B left" }
  for index = 1, 50 do
    -- Long enough for a pull of several batches
    expected[#expected + 1] = "line " .. index .. " " .. string.rep("x", 60)
    a:Hear(expected[#expected], "Nota Scam")
    net:Advance(2)
  end
  net:Advance(1000)
  T.eq(a.sync.dirtySince[TABLE], nil, "A has pushed its 50 lines, to nobody")

  local lost = 0
  if cut then
    -- A must not pull from B meanwhile: the push after that pull would bring B the rest, and this test is
    -- about the next pull of B
    a.session.ScheduleDelayedPull = function() end
    net.dropIf = function(entry)
      local messageType, fields = codec.decode(entry.text)
      if messageType == "D" and fields.batch == 2 and lost == 0 then
        lost = 1
        return true
      end
      return false
    end
  end
  local loginAt = net:Now()
  b:Login()
  net:Advance(5)
  for index = 1, 2 do
    expected[#expected + 1] = "new line " .. index
    a:Hear(expected[#expected], "Nota Scam")
  end
  a.session:PushLocal(TABLE)
  net:Advance(1)
  T.eq(Replica.count(net, "P", "Nota Scam", loginAt), 1, "A has pushed its 2 new lines")
  T.eq(Replica.count(net, "H", "Other One", loginAt), 0, "before B has sent its hello")
  T.eq(texts(b), { "before B left" }, "B applies none of the pushed records: it has a gap before them")
  b:Hear("line of B", "Other One")
  T.eq(texts(b), { "before B left", "line of B" }, "B writes its own line before its first pull")

  if cut then
    net:Advance(80)
    T.eq(lost, 1, "the second batch of the first pull was lost")
    local held = #texts(b)
    T.ok(held > 2 and held < 54, "B holds the first batch and not all lines (" .. held .. ")")
    T.ok(b:Version(TABLE) ~= a:Version(TABLE), "its table version still differs")
  end
  net:Advance(1500)
  -- The line of B was written 6 seconds after its login, before the new lines of A in id order or after
  -- them: the ids of A's new lines carry the earlier second
  expected[#expected + 1] = "line of B"
  T.eq(texts(b), expected, "after the pull B holds all 52 lines of A and its own, in order")
  T.eq(texts(a), expected, "and A holds the line of B")
  T.eq(b:Version(TABLE), a:Version(TABLE), "both end with the same table version")
  T.eq(Replica.count(net, "Q", "Other One", loginAt), cut and 2 or 1,
    cut and "the next pull brought the rest" or "one pull was enough")
end

raceAfterLogin(false)
raceAfterLogin(true)

--------------------------------------------------------------------------------
-- The witness (step 10.3)
--------------------------------------------------------------------------------

---Makes a guild of three replicas that have completed discovery and know each other, and a member without
---the addon.
---@return Fakenet net
---@return TestReplica[] replicas "Nota Scam", "Other One", "Third One"
local function guildOfThree()
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index, name in ipairs({ "Nota Scam", "Other One", "Third One" }) do
    replicas[index] = Replica.new(net, name, { random = random })
  end
  for _, replica in ipairs(replicas) do
    replica:Login()
  end
  net:Advance(100)
  for _, replica in ipairs(replicas) do
    T.eq(#replica:PeerNames(), 2, replica.name .. " knows the two others")
  end
  net:Join("No Addon")
  return net, replicas
end

---Lets every replica hear one line of guild chat and counts those that wrote it.
---@param replicas TestReplica[]
---@param text string
---@param sender string
---@return string[] writers Names of the replicas that wrote the line
local function say(replicas, text, sender)
  local writers = {}
  for _, replica in ipairs(replicas) do
    if replica:Hear(text, sender) then
      writers[#writers + 1] = replica.name
    end
  end
  return writers
end

-- Three replicas hear a line of a member without the addon: one record exists after the push
do
  local net, replicas = guildOfThree()
  T.eq(say(replicas, "hello from outside", "No Addon"), { "Nota Scam" },
    "the replica with the first name in byte order writes the line")
  net:Advance(1000)
  for _, replica in ipairs(replicas) do
    T.eq(stored(replica), 1, replica.name .. " holds one record")
    T.eq(texts(replica), { "hello from outside" }, "with the line")
    T.eq(replica.ns.guildChat:Lines()[1].sender, "No Addon", "under the name of its sender")
  end
  -- The witness goes offline: the next one in byte order takes over
  replicas[1]:Logout()
  net:Advance(5)
  T.eq(say({ replicas[2], replicas[3] }, "second line", "No Addon"), { "Other One" },
    "when the witness has gone offline, the next name writes")
end

-- The sender is a peer: no witness writes
do
  local net, replicas = guildOfThree()
  T.eq(say(replicas, "from a member with the addon", "Third One"), { "Third One" },
    "the line of a peer is written by its own addon alone")
  net:Advance(1000)
  for _, replica in ipairs(replicas) do
    T.eq(stored(replica), 1, replica.name .. " holds one record")
  end
end

-- A replica that has just joined and has not finished its discovery writes nothing
do
  local net, replicas = guildOfThree()
  local fresh = Replica.new(net, "Aaa First", { random = random })
  fresh:Login()
  net:Advance(5)
  T.eq(fresh.session.discovered, false, "the new replica has not finished its discovery")
  local all = { replicas[1], replicas[2], replicas[3], fresh }
  T.eq(say(all, "while one is joining", "No Addon"), { "Nota Scam" },
    "the new replica writes nothing, although its name is the first; the old witness still writes")
  net:Advance(100)
  T.eq(fresh.session.discovered, true, "now it has")
  T.eq(say(all, "after it has joined", "No Addon"), { "Aaa First" }, "and is the witness from then on")
end

-- The line of a witness and the line of the sender's own addon can be told apart
do
  local net, replicas = guildOfThree()
  writeCharacter(replicas[2])
  net:Advance(1000)
  say(replicas, "from outside", "No Addon")
  net:Advance(5)
  say(replicas, "from inside", "Other One")
  net:Advance(1000)
  for _, replica in ipairs(replicas) do
    local lines = replica.ns.guildChat:Lines()
    T.eq({ lines[1].text, lines[1].bySender }, { "from outside", false },
      replica.name .. ": the line of a witness is not by its sender")
    T.eq({ lines[2].text, lines[2].bySender }, { "from inside", true }, "the line of the sender's addon is")
  end
  -- A modified addon writes a line under the name of a member: the origin does not belong to that member
  local a = replicas[1]
  receive(a, math.floor(net:Now()), "QQQQ", "Other One", "forged in my name")
  local lines = a.ns.guildChat:Lines()
  T.eq({ lines[3].text, lines[3].bySender }, { "forged in my name", false }, "a line of a foreign origin is marked")
end

-- A replica whose tables equal those of the others still learns who has the addon: the whisper "here"
do
  local net, replicas = guildOfThree()
  local fresh = Replica.new(net, "Zzz Last", { random = random })
  fresh:Login()
  net:Advance(100)
  T.eq(#fresh:PeerNames(), 3, "the new replica knows the three others, although no table differs")
  local all = { replicas[1], replicas[2], replicas[3], fresh }
  T.eq(say(all, "from outside", "No Addon"), { "Nota Scam" }, "so it does not take itself for the witness")
  T.eq(say(all, "from inside", "Other One"), { "Other One" }, "nor a member with the addon for one without")
end

-- Two replicas that do not know each other yet both write; Lines shows one line
do
  local net = Fakenet.new({ random = random })
  -- The whisper that tells B about A is lost
  net.dropIf = function(entry)
    return codec.decode(entry.text) == "A"
  end
  local a = Replica.new(net, "Nota Scam", { random = random })
  local b = Replica.new(net, "Other One", { random = random })
  net:SetOnline("Other One", false)
  writeCharacter(a)
  a:Login()
  net:Advance(100)
  -- B has the same tables as A, so no summary answers its hello, and the whisper is lost: it knows no peer
  for name, tbl in pairs(a.data.tables) do
    local copy = b.data.tables[name]
    for key, record in pairs(tbl.records) do
      b.ns.syncStore.apply(copy, key, record.v, record.d, record.x)
    end
  end
  b:Login()
  net:Advance(100)
  T.eq(b.session.discovered, true, "B has finished its discovery")
  T.eq({ a:PeerNames(), b:PeerNames() }, { { "Other One" }, {} }, "A has heard the hello of B; B knows nobody")
  net:Join("No Addon")
  T.eq(say({ a, b }, "written twice", "No Addon"), { "Nota Scam", "Other One" }, "both take themselves for the witness")
  net:Advance(1000)
  T.eq({ stored(a), stored(b) }, { 2, 2 }, "two records exist after the pushes")
  T.eq({ texts(a), texts(b) }, { { "written twice" }, { "written twice" } }, "Lines shows one line on both")
  T.eq(a:Version(TABLE), b:Version(TABLE), "the replicas are equal")

  -- The push of A has shown B that A is a peer: a line of A is from then on written by A alone
  T.eq(b:PeerNames(), { "Nota Scam" }, "B knows A from its push")
  T.eq(say({ a, b }, "a line of A", "Nota Scam"), { "Nota Scam" }, "the line of a known peer is written once")
  T.eq(say({ a, b }, "from outside again", "No Addon"), { "Nota Scam" }, "and there is one witness")
  net:Advance(1000)
  local lines = b.ns.guildChat:Lines()
  T.eq({ #lines, lines[2].text, lines[2].bySender }, { 3, "a line of A", true }, "B holds the three lines")
end

T.finish()
