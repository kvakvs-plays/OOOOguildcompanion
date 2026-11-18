-- Host test of Addon/Src/Sync/SyncPolicy.lua: the conditions, the effective policy of a table, the reading
-- of the game with stubbed functions, and what the session does with them.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)
-- The push has its own test (sync_push.lua)
Replica.withoutPush = true

local random = T.newRandom()
local codec = Replica.codec

-- The truth table of conditionMet: three values of `when`, 16 states
do
  local policy = T.loadAll({ "Addon/Src/Sync/SyncPolicy.lua" }).syncPolicy
  T.eq(policy.WHEN, { "nocombat", "noraid", "resting" }, "the values of when, weakest first")
  local count = 0
  for _, inCombat in ipairs({ false, true }) do
    for _, inRaid in ipairs({ false, true }) do
      for _, inInstance in ipairs({ false, true }) do
        for _, resting in ipairs({ false, true }) do
          local state = { inCombat = inCombat, inRaid = inRaid, inInstance = inInstance, resting = resting }
          local name = "combat " .. tostring(inCombat) .. ", raid " .. tostring(inRaid) .. ", instance "
            .. tostring(inInstance) .. ", resting " .. tostring(resting)
          T.eq(policy.conditionMet("nocombat", state), not inCombat, "nocombat with " .. name)
          T.eq(policy.conditionMet("noraid", state), not inCombat and not inRaid and not inInstance,
            "noraid with " .. name)
          T.eq(policy.conditionMet("resting", state), not inCombat and not inRaid and not inInstance and resting,
            "resting with " .. name)
          T.eq(policy.conditionMet("sometimes", state), false, "an unknown when with " .. name)
          count = count + 1
        end
      end
    end
  end
  T.eq(count, 16, "all 16 states were checked")
end

-- The effective policy: an override replaces only the fields that it sets, and a bad value is ignored
do
  local policy = T.loadAll({ "Addon/Src/Sync/SyncPolicy.lua" }).syncPolicy
  local defaults = { when = "nocombat", pushDelay = 300, minInterval = 600 }
  local plain = { when = "nocombat", pushDelay = 300, minInterval = 600, enabled = true }
  T.eq(policy.effective(defaults, nil), plain, "without an override the definition holds, and the table is on")
  T.eq(policy.effective(defaults, {}), plain, "an empty override changes nothing")
  T.eq(policy.effective(defaults, "resting"), plain, "an override that is not a table is ignored")
  T.eq(policy.effective(defaults, { when = "resting" }),
    { when = "resting", pushDelay = 300, minInterval = 600, enabled = true }, "an override of when alone")
  T.eq(policy.effective(defaults, { pushDelay = 10, enabled = false }),
    { when = "nocombat", pushDelay = 10, minInterval = 600, enabled = false }, "an override of two fields")
  T.eq(policy.effective(defaults, { when = "noraid", pushDelay = 0, minInterval = 86400, enabled = true }),
    { when = "noraid", pushDelay = 0, minInterval = 86400, enabled = true }, "the limits of the ranges are accepted")
  for name, bad in pairs({
    ["an unknown when"] = { when = "always" },
    ["a when that is a number"] = { when = 1 },
    ["a negative delay"] = { pushDelay = -1 },
    ["a delay over one day"] = { pushDelay = 86401 },
    ["a delay that is a string"] = { pushDelay = "10" },
    ["a negative interval"] = { minInterval = -0.5 },
    ["an interval that is not a number"] = { minInterval = 0 / 0 },
    ["enabled that is a string"] = { enabled = "no" },
    ["enabled that is a number"] = { enabled = 0 },
  }) do
    T.eq(policy.effective(defaults, bad), plain, name .. " falls back to the default")
  end
  T.eq(defaults, { when = "nocombat", pushDelay = 300, minInterval = 600 }, "the definition is not changed")
end

-- Reading the game, with stubbed functions
do
  local SECRET = {}
  local game = { combat = false, raid = false, instance = false, resting = true }
  _G.issecretvalue = function(value)
    return value == SECRET
  end
  _G.InCombatLockdown = function()
    return game.combat
  end
  _G.IsInRaid = function()
    return game.raid
  end
  _G.IsInInstance = function()
    return game.instance, "party"
  end
  _G.IsResting = function()
    return game.resting
  end
  local frame
  _G.CreateFrame = function()
    frame = { events = {} }
    function frame:SetScript(_, handler)
      self.handler = handler
    end
    function frame:RegisterEvent(event)
      self.events[event] = true
    end
    return frame
  end
  local policy = T.loadAll({ "Addon/Src/Sync/SyncPolicy.lua" }).syncPolicy
  local fired = 0
  policy.RegisterCallback(game, "OnConditionsChanged", function()
    fired = fired + 1
  end)
  local function fire(event)
    T.ok(frame.events[event], event .. " is registered")
    frame.handler(frame, event)
  end

  T.eq(policy.state.inCombat, true, "before the start nothing may send")
  policy.Start()
  T.eq(policy.state, { inCombat = false, inRaid = false, inInstance = false, resting = true },
    "the start reads the game")
  T.eq(fired, 1, "and fires the change")
  fire("PLAYER_ENTERING_WORLD")
  T.eq(fired, 1, "an event without a change fires nothing")
  fire("PLAYER_REGEN_DISABLED")
  T.eq({ policy.state.inCombat, fired }, { true, 2 }, "the start of a fight sets combat, whatever the game says")
  fire("PLAYER_REGEN_ENABLED")
  T.eq({ policy.state.inCombat, fired }, { false, 3 }, "the end of a fight clears it")
  game.resting = false
  fire("PLAYER_UPDATE_RESTING")
  T.eq({ policy.state.resting, fired }, { false, 4 }, "leaving a city clears resting")
  game.raid = true
  fire("GROUP_ROSTER_UPDATE")
  T.eq({ policy.state.inRaid, fired }, { true, 5 }, "joining a raid group sets raid")
  game.raid, game.instance = false, true
  fire("PLAYER_ENTERING_WORLD")
  T.eq({ policy.state.inRaid, policy.state.inInstance, fired }, { false, true, 6 }, "entering a dungeon sets instance")
  game.combat, game.raid, game.instance, game.resting = SECRET, SECRET, SECRET, SECRET
  fire("PLAYER_ENTERING_WORLD")
  T.eq(policy.state, { inCombat = true, inRaid = true, inInstance = true, resting = false },
    "a secret value counts as the one that forbids sending")
  -- The replicas below need the function, without secret values
  _G.issecretvalue = function()
    return false
  end
end

---Makes a network with replicas that are not logged in.
local function setup(names)
  local net = Fakenet.new({ random = random })
  local replicas = {}
  for index, name in ipairs(names) do
    replicas[index] = Replica.new(net, name, { random = random })
  end
  return net, table.unpack(replicas)
end

-- The hello waits for the end of a fight
do
  local net, a = setup({ "Nota Scam" })
  a.state.inCombat = true
  a:Login()
  net:Advance(100)
  T.eq(net:Count(), 0, "no hello in combat")
  T.eq(a.session:StatusLines()[1], "discovery: the hello waits until the fight is over", "the status says so")
  a:SetState({ inCombat = false })
  net:Advance(1)
  T.eq(Replica.count(net, "H"), 1, "the hello goes out when the fight is over")
  a:SetState({ inCombat = true })
  a:SetState({ inCombat = false })
  net:Advance(100)
  T.eq(Replica.count(net, "H"), 1, "and is not sent a second time")
end

-- A summary is not sent in combat; a pull waits for the condition of its table
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  a.sync:Put("debug", "key", "text")
  a:Login()
  net:Advance(100)
  a:SetState({ inCombat = true })
  b:Login()
  net:Advance(100)
  T.eq(Replica.count(net, "S"), 0, "a replica in combat does not answer a hello")
  T.eq(b:PeerNames(), {}, "so the new replica knows no peer")
  a:Logout()
  b:Logout()

  -- The requester's side: its table needs resting
  net:Advance(10)
  a.state.inCombat = false
  b.overrides.debug = { when = "resting" }
  a:Login()
  net:Advance(100)
  b:Login()
  net:Advance(100)
  T.eq(b:PeerNames(), { "Nota Scam" }, "the hello and the summary do not depend on the table's condition")
  T.eq(Replica.count(net, "Q"), 0, "no pull request while the table's condition is not met")
  T.eq(b.session:SendState("debug"), "no, needs resting", "the status names the condition")
  T.eq(b.session:SendState("character"), "yes", "another table may send")
  b:SetState({ resting = true })
  net:Advance(10)
  T.eq(Replica.count(net, "Q"), 1, "the pull starts when the condition is met")
  T.eq(b:Version("debug"), a:Version("debug"), "and completes")
  T.eq(b.session:SendState("debug"), "yes", "the status follows")

  -- The status command shows it per table
  b.ns.syncSession.current = b.session
  local found = false
  for _, line in ipairs(b.ns.syncCommands.statusLines()) do
    found = found or line:find("^debug: 1 records, 0 deleted, %d+ bytes, version .+, may send: yes$") ~= nil
  end
  T.ok(found, "/oooo sync status shows for each table whether it may send")
end

-- The responder's side: its condition, and a table that is turned off
do
  local net, a = setup({ "Nota Scam" })
  a.sync:Put("debug", "key", "text")
  a.overrides.debug = { when = "noraid" }
  a:Login()
  net:Advance(100)
  local got = {}
  local raw = net:Join("Other One")
  raw.receive = function(text, distribution)
    local messageType, fields = codec.decode(text)
    if distribution == "WHISPER" then
      got[#got + 1] = { messageType, fields.reason or (fields.records and #fields.records), fields.retry }
    end
  end
  local function ask(nonce)
    got = {}
    raw:Send(codec.encode("Q", "debug", 1, nonce, ""), "WHISPER", "Nota Scam")
    net:Advance(10)
    return got
  end
  T.eq(ask(1), { { "D", 1 } }, "the responder serves while its condition is met")
  a:SetState({ inInstance = true })
  T.eq(ask(2), { { "B", "busy", 30 } }, "in an instance a noraid table answers busy")
  T.eq(a.session:SendState("debug"), "no, needs noraid, has unsent changes",
    "the status names the condition and the unsent write")
  a:SetState({ inInstance = false, inRaid = true })
  T.eq(ask(3), { { "B", "busy", 30 } }, "and so in a raid group")
  a:SetState({ inRaid = false })
  T.eq(ask(4), { { "D", 1 } }, "it serves again afterwards")

  -- A transfer stops when the condition turns false
  for index = 1, 300 do
    a.sync:Put("debug", "key" .. index, "text of record " .. index)
  end
  net.sendRate = 2000
  got = {}
  raw:Send(codec.encode("Q", "debug", 1, 5, ""), "WHISPER", "Nota Scam")
  net:Advance(2)
  T.ok(a.session.serving, "a transfer is running")
  a:SetState({ inCombat = true })
  net:Advance(60)
  T.eq(a.session.serving, nil, "the transfer stops after the current batch when a fight starts")
  for _, message in ipairs(got) do
    T.eq(message[1], "D", "only batches were sent")
  end
  T.ok(#got >= 1 and #got < 8, "and not all of them")
  a:SetState({ inCombat = false })
  net.sendRate = nil

  -- enabled = false: the table is absent from H and S, and a Q for it gets B
  a.overrides.debug = { enabled = false }
  T.eq(a.session:SendState("debug"), "off", "the status shows a table that is turned off")
  T.eq(a.session:LocalVersions().debug, nil, "a table that is turned off has no version to announce")
  T.eq(ask(6), { { "B", "unknown", 3600 } }, "a pull request for it is refused like an unknown table")
  got = {}
  raw:Send(codec.encode("H", { debug = "!!!!!ZZZZ!!!!!!!", character = "!!!!!ZZZZ!!!!!!!" }), "GUILD")
  net:Advance(20)
  local _, summary = codec.decode(net.log[#net.log].text)
  T.eq(summary, { character = a:Version("character") }, "the summary leaves the table out")
  a:Logout()
  net:Advance(10)
  a:Login()
  net:Advance(60)
  local hello
  for _, entry in ipairs(net.log) do
    local messageType, fields = codec.decode(entry.text)
    if messageType == "H" and entry.from == "Nota Scam" then
      hello = fields
    end
  end
  T.eq(hello, { character = a:Version("character"), guildchat = a:Version("guildchat") },
    "the hello leaves the table out")
end

-- A requester does not ask for a table that it has turned off
do
  local net, a, b = setup({ "Nota Scam", "Other One" })
  a.sync:Put("debug", "key", "text")
  b.overrides.debug = { enabled = false }
  a:Login()
  net:Advance(100)
  b:Login()
  net:Advance(200)
  T.eq(Replica.count(net, "Q"), 0, "no pull request for a table that is turned off")
  T.eq(b.sync:Count("debug"), 0, "and no record arrives")
end

-- The options page: the status text
do
  local options = T.loadAll({ "Addon/Src/Sync/SyncPolicy.lua", "Addon/Src/Sync/SyncOptions.lua" }).syncOptions
  local now = 1795000000
  T.eq(options.statusText({ enabled = true, records = 0, now = now }), "0 records, no pull yet",
    "the status of a table that was never synced")
  T.eq(options.statusText({ enabled = true, records = 12, now = now, syncedAt = now - 125 }),
    "12 records, last pull 2 min ago", "the status of a synced table")
  T.eq(options.statusText({ enabled = true, records = 12, now = now, syncedAt = now - 125, source = "Nota Scam",
    batch = 3 }), "12 records, pulling from Nota Scam (batch 3)", "the status during a pull")
  T.eq(options.statusText({ enabled = false, records = 12, now = now, syncedAt = now - 125, source = "Nota Scam" }),
    "Turned off: 12 records, neither sent nor requested", "the status of a table that is turned off")
  T.eq(options.statusText({ enabled = true, records = 5, now = now, syncedAt = now, servingTo = "Other One",
    servingBatch = 2, servingTotal = 7 }), "5 records, last pull 0 s ago, sending to Other One (batch 2 of 7)",
    "the status while the table is sent to a peer")
  for seconds, text in pairs({ [0] = "0 s ago", [59] = "59 s ago", [60] = "1 min ago", [3599] = "59 min ago",
    [3600] = "1 h ago", [86399] = "23 h ago", [86400] = "1 d ago", [200000] = "2 d ago", [-5] = "0 s ago" }) do
    T.eq(options.ago(seconds), text, "ago of " .. seconds .. " seconds")
  end

  -- The setters write only into the overrides, and only what differs from the definition
  local defaults = { when = "nocombat", pushDelay = 300, minInterval = 600 }
  local overrides = {}
  options.setOverride(overrides, defaults, "debug", "when", "resting")
  T.eq(overrides, { debug = { when = "resting" } }, "a changed value is stored as an override")
  T.eq(options.getValue(overrides, defaults, "debug", "when"), "resting", "the control shows the override")
  T.eq(options.getValue(overrides, defaults, "debug", "pushDelay"), 300, "and the definition for the other fields")
  T.eq(options.getValue(overrides, defaults, "debug", "enabled"), true, "a table is on by default")
  options.setOverride(overrides, defaults, "debug", "enabled", false)
  options.setOverride(overrides, defaults, "debug", "pushDelay", 10)
  options.setOverride(overrides, defaults, "other", "minInterval", 60)
  T.eq(overrides, { debug = { when = "resting", enabled = false, pushDelay = 10 }, other = { minInterval = 60 } },
    "each field and each table has its own override")
  options.setOverride(overrides, defaults, "debug", "when", "nocombat")
  options.setOverride(overrides, defaults, "debug", "enabled", true)
  T.eq(overrides.debug, { pushDelay = 10 }, "a value equal to the definition removes the override")
  options.setOverride(overrides, defaults, "debug", "pushDelay", 300)
  T.eq(overrides, { other = { minInterval = 60 } }, "a table without overrides is removed")
  options.setOverride(overrides, defaults, "debug", "schema", 5)
  T.eq(overrides.debug, nil, "a field that is not a policy field is not stored")
  T.eq(defaults, { when = "nocombat", pushDelay = 300, minInterval = 600 }, "the definition is never written")
  T.eq(options.getValue(nil, defaults, "debug", "when"), "nocombat", "missing overrides give the definition")
end

T.finish()
