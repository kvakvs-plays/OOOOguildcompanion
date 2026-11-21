-- Host test of the gambling notices (.agents/00-plan.md, section 15.7; Addon/Src/Gamble/GambleNotice.lua): the
-- notice of a new open event and the notice of the own dues, each once per event and character, the wait for the
-- end of combat, the summary of many events, the clean-up of the marks, and the safety of the printed text.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Gamble/GambleData.lua", "Addon/Src/Gamble/GambleSettle.lua", "Addon/Src/Gamble/Gamble.lua",
  "Addon/Src/Gamble/GambleNotice.lua" }
local TABLE, PLAYER_TABLE = "gamble", "gamble_player"
local HOUR = 3600
local TITLE = "Who wins the duel on Friday?"

---Makes a replica that has the gambling tables and a gambling model, and logs it in.
---@param net Fakenet
---@param name string
---@param rankIndex integer?
---@return table
local function withGamble(net, name, rankIndex)
  local replica = Replica.new(net, name, { random = random, rankIndex = rankIndex })
  T.loadAll(FILES, replica.ns)
  replica.model = replica.ns.gamble.new({
    sync = replica.sync,
    now = function()
      return math.floor(net:Now())
    end,
    playerName = function()
      return name
    end,
    sanitize = replica.ns.mentions.sanitize,
    random = random,
    isOfficer = function(other)
      return net.guild:IsOfficer(other)
    end,
  })
  replica:Login()
  return replica
end

---Returns the server time of a network as the model sees it.
---@param net Fakenet
---@return integer
local function now(net)
  return math.floor(net:Now())
end

---Returns a valid spec of an event that closes `ahead` seconds from now.
---@param net Fakenet
---@param title string?
---@param ahead integer?
---@return table
local function spec(net, title, ahead)
  return { title = title or TITLE, outcomes = { { n = "Nota", p = 60 }, { n = "Other", p = 40 } },
    close = now(net) + (ahead or HOUR), maxStake = 100 }
end

---Lets the replicas exchange their changes.
---@param net Fakenet
local function exchange(net)
  net:Advance(60)
end

---@class NoticeEnv A notifier with fake parts
---@field notifier table
---@field lines string[] What was printed
---@field store table
---@field combat boolean
---@field name string
---@field timers table[]
---@field fire fun() Runs the pending timers
---@field pending fun(): integer Counts the timers that wait

---Makes a notifier for a replica with a fake chat, combat state, and timer.
---@param replica table
---@param options { store: table?, name: string? }?
---@return NoticeEnv
local function notifierOf(replica, options)
  options = options or {}
  local env = { lines = {}, combat = false, timers = {}, name = options.name or replica.name,
    store = options.store or { noticed = {} } }
  env.notifier = replica.ns.gambleNotice.new({
    sync = replica.sync,
    model = replica.model,
    store = env.store,
    playerName = function()
      return env.name
    end,
    print = function(text)
      env.lines[#env.lines + 1] = text
    end,
    inCombat = function()
      return env.combat
    end,
    after = function(_seconds, fn)
      local timer = { fn = fn, cancelled = false }
      function timer:Cancel()
        self.cancelled = true
      end
      env.timers[#env.timers + 1] = timer
      return timer
    end,
    formatTime = function()
      return "Fri 20:00"
    end,
  })
  function env.pending()
    local count = 0
    for _, timer in ipairs(env.timers) do
      if not timer.cancelled then
        count = count + 1
      end
    end
    return count
  end
  function env.fire()
    local list = env.timers
    env.timers = {}
    for _, timer in ipairs(list) do
      if not timer.cancelled then
        timer.fn()
      end
    end
  end
  return env
end

---Takes the printed lines and empties the list.
---@param env NoticeEnv
---@return string[]
local function take(env)
  local lines = env.lines
  env.lines = {}
  return lines
end

local notice = withGamble(Fakenet.new({ random = random }), "Probe", nil).ns.gambleNotice
local LINK = "|cff71d5ff|Haddon:OOOOguildcompanion:gamble|h[Open the bets]|h|r"
T.eq(notice.linkText(), LINK, "the link has the data of the tab and the colour of the mention notice")
T.eq(notice.LINK, "gamble", "the data part of the link")

---Returns the text of the notice of an open event.
---@param title string
---@return string
local function openLine(title)
  return "New bet: " .. title .. ", open until Fri 20:00. " .. LINK
end

--------------------------------------------------------------------------------
-- The notice of a new open event
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  local other = withGamble(net, "Other One")
  exchange(net)
  local store = { noticed = {} }
  local mine = notifierOf(member, { store = store })
  local theirs = notifierOf(officer)
  local second = notifierOf(other, { store = store })

  local id = officer.model:Open(spec(net))
  local id2 = officer.model:Open(spec(net, "Second event"))
  exchange(net)
  T.eq(mine.pending(), 1, "many record changes wait for one timer")
  T.eq(#mine.lines, 0, "nothing is printed before the timer")
  mine.fire()
  T.eq(take(mine), { openLine("Second event"), openLine(TITLE) }, "the member hears of both open events, newest first")
  T.eq(store.noticed["Nota Scam"][id], { open = true }, "the mark is in the store under the name and the event")
  T.eq(store.noticed["Nota Scam"][id2], { open = true }, "of each event")

  T.eq(member.model:PlaceBet(id, { [1] = 30 }), true, "the member bets")
  exchange(net)
  mine.fire()
  mine.notifier:Check()
  T.eq(take(mine), {}, "more record changes and another check print nothing again")

  theirs.fire()
  theirs.notifier:Check()
  T.eq(take(theirs), {}, "the officer who opened the events gets no notice")

  second.fire()
  T.eq(take(second), { openLine("Second event"), openLine(TITLE) },
    "a second character on the same store has its own marks and gets its notices")
  T.eq(store.noticed["Other One"][id], { open = true }, "with its own marks")

  -- An event that is locked at once gives nothing
  local locked = officer.model:Open(spec(net, "Locked early"))
  T.eq(officer.model:Lock(locked), true, "the officer locks an event")
  exchange(net)
  mine.fire()
  mine.notifier:Check()
  T.eq(take(mine), {}, "an event that is locked already gives no notice")
  T.eq(store.noticed["Nota Scam"][locked], nil, "and no mark")

  -- Stop
  mine.notifier:Stop()
  officer.model:Open(spec(net, "After the stop"))
  exchange(net)
  T.eq(mine.pending(), 0, "a stopped notifier waits for nothing")
  T.eq(take(mine), {}, "and prints nothing")
end

-- Combat: nothing is printed, the marks wait too
do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  exchange(net)
  local mine = notifierOf(member)
  local id = officer.model:Open(spec(net))
  exchange(net)
  mine.combat = true
  mine.fire()
  T.eq(take(mine), {}, "in combat nothing is printed")
  T.eq(mine.store.noticed["Nota Scam"], nil, "and nothing is marked")
  mine.notifier:OnCombatEnded()
  T.eq(take(mine), {}, "the end of combat while the character is still in combat state prints nothing")
  mine.combat = false
  mine.notifier:OnCombatEnded()
  T.eq(take(mine), { openLine(TITLE) }, "the end of combat prints what waited")
  T.eq(mine.store.noticed["Nota Scam"][id], { open = true }, "and marks it")
  mine.notifier:OnCombatEnded()
  T.eq(take(mine), {}, "nothing waits any more")
end

-- What arrived while the character was offline: a notifier that starts late finds the held events
do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  officer.model:Open(spec(net))
  exchange(net)
  local mine = notifierOf(member)
  T.eq(#mine.lines, 0, "a new notifier prints nothing by itself")
  mine.notifier:Check()
  T.eq(take(mine), { openLine(TITLE) }, "the check at the start finds an event that is held already")
  T.eq(mine.notifier.parts.playerName(), "Nota Scam", "with the name of the character")
  mine.name = nil
  mine.notifier:Check()
  T.eq(take(mine), {}, "a character without a name gets nothing")
end

-- More than 3 new events: 3 lines and one summary
do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  exchange(net)
  local mine = notifierOf(member)
  for index = 1, 5 do
    officer.model:Open(spec(net, "Event " .. index))
  end
  exchange(net)
  mine.fire()
  T.eq(take(mine), { openLine("Event 5"), openLine("Event 4"), openLine("Event 3"), "2 more bets are open. " .. LINK },
    "three notices and one summary line")
  mine.notifier:Check()
  T.eq(take(mine), {}, "all five are marked")
  officer.model:Open(spec(net, "Event 6"))
  exchange(net)
  mine.fire()
  T.eq(take(mine), { openLine("Event 6") }, "a later event gets its own notice")

  -- The summary of one
  local lone = notifierOf(member)
  lone.store.noticed["Nota Scam"] = {}
  lone.notifier:Check()
  T.eq(take(lone), { openLine("Event 6"), openLine("Event 5"), openLine("Event 4"), "3 more bets are open. " .. LINK },
    "a fresh store gets the same cap")
end

-- The clean-up of the marks
do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  local id = officer.model:Open(spec(net))
  exchange(net)
  local mine = notifierOf(member)
  mine.store.noticed["Nota Scam"] = { ["gone event"] = { open = true, dues = "ABCD" } }
  mine.store.noticed["Old Alt"] = { ["gone event"] = { open = true } }
  mine.notifier:Check()
  T.eq(mine.store.noticed, { ["Nota Scam"] = { [id] = { open = true } } },
    "marks of events that are gone are removed, an empty character with them, and the held event is marked")
  T.eq(#take(mine), 1, "the held event was announced")
end

-- A title with a pipe cannot break the line
do
  local net = Fakenet.new({ random = random })
  local officer = withGamble(net, "Officer One", 0)
  local member = withGamble(net, "Nota Scam")
  exchange(net)
  local mine = notifierOf(member)
  officer.model:Open(spec(net, "Hi |cff00ff00|Hitem:1::|h[Sword]|h|r |T1|t ||x |"))
  exchange(net)
  mine.fire()
  local lines = take(mine)
  T.eq(lines, { openLine("Hi [Sword] ||T1||t ||x ||") },
    "the links and colours of the title are dropped, every | doubled")
  local bare = lines[1]:gsub("||", ""):gsub(LINK:gsub("%p", "%%%0"), "")
  T.ok(not bare:find("|", 1, true), "no single pipe is left outside the link")
  T.eq(notice.plain("a\nb"), "ab", "a control character is dropped")
  T.eq(notice.plain("|"), "||", "a lone pipe is doubled")
  T.eq(notice.plain("|cff00ff00x|r"), "x", "a colour is dropped")
end

--------------------------------------------------------------------------------
-- The notice of the own dues
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local boss = withGamble(net, "Officer One", 0)
  local data = boss.ns.gambleData
  local names = { "Xavi Ash", "Yara Bell", "Zed Cole", "Quin Dax" }
  local replicas, envs = {}, {}
  for _, name in ipairs(names) do
    replicas[name] = withGamble(net, name)
    envs[name] = notifierOf(replicas[name])
  end
  envs.boss = notifierOf(boss)
  exchange(net)
  local id = boss.model:Open(spec(net, TITLE, 30 * HOUR))
  exchange(net)
  local stakes = { ["Xavi Ash"] = { [1] = 30 }, ["Yara Bell"] = { [1] = 20 }, ["Zed Cole"] = { [2] = 40 } }
  for _, name in ipairs({ "Xavi Ash", "Yara Bell", "Zed Cole" }) do
    T.eq(replicas[name].model:PlaceBet(id, stakes[name]), true, name .. " bets")
    local key = data.betKey(name, id)
    T.eq(boss.sync:Put(TABLE, data.bookKey(id, name), { g = replicas[name].sync:Get(PLAYER_TABLE, key).g,
      b = replicas[name].sync:GetId(PLAYER_TABLE, key), t = now(net) }), true, "the officer books " .. name)
  end
  exchange(net)
  for _, env in pairs(envs) do
    env.fire()
    take(env)
  end

  T.eq(boss.model:Lock(id), true, "the officer locks")
  T.eq(boss.model:Resolve(id, { true, false }), true, "and resolves: Nota wins")
  exchange(net)
  for _, env in pairs(envs) do
    env.fire()
  end
  local head = "Bet resolved: " .. TITLE .. "."
  T.eq(take(envs["Zed Cole"]), { head .. " You give 3 gold to Officer One for the guild bank, 20 gold to Xavi Ash,"
    .. " 13 gold to Yara Bell. " .. LINK }, "the payer gets one line with all his dues")
  T.eq(take(envs["Xavi Ash"]), { head .. " Zed Cole gives you 20 gold. " .. LINK }, "a receiver gets his line")
  T.eq(take(envs["Yara Bell"]), { head .. " Zed Cole gives you 13 gold. " .. LINK }, "the other receiver too")
  T.eq(take(envs["Quin Dax"]), {}, "a member without dues gets none")
  T.eq(take(envs.boss), { head .. " Zed Cole gives you 3 gold for the guild bank. " .. LINK },
    "the banker is told about the share of the guild bank")
  T.eq(envs["Zed Cole"].store.noticed["Zed Cole"][id],
    { open = true, dues = envs["Zed Cole"].notifier.parts.model:Event(id).q },
    "the mark carries the token")
  for _, env in pairs(envs) do
    env.notifier:Check()
    T.eq(take(env), {}, "a second check prints nothing")
  end

  -- A second resolution with another token: the dues are written again, with the same event
  local event = boss.sync:Get(TABLE, data.eventKey(id))
  local resolved = {}
  for field, value in pairs(event) do
    resolved[field] = value
  end
  resolved.q, resolved.d = "ABCD", 1
  T.eq(boss.sync:Put(TABLE, data.dueKey(id, 1), { q = "ABCD", f = "Zed Cole", t = "Xavi Ash", g = 25 }), true,
    "the new due is written")
  T.eq(boss.sync:Put(TABLE, data.eventKey(id), resolved), true, "and the event names the new token")
  exchange(net)
  for _, env in pairs(envs) do
    env.fire()
  end
  T.eq(take(envs["Zed Cole"]), { head .. " You give 25 gold to Xavi Ash. " .. LINK }, "a new token is a new notice")
  T.eq(take(envs["Xavi Ash"]), { head .. " Zed Cole gives you 25 gold. " .. LINK }, "for the receiver too")
  T.eq(take(envs["Yara Bell"]), {}, "a member who owes nothing under the new token gets none")
  T.eq(take(envs["Quin Dax"]), {}, "nor the uninvolved")
  T.eq(envs["Zed Cole"].store.noticed["Zed Cole"][id].dues, "ABCD", "the mark follows the token")
end

T.finish()
