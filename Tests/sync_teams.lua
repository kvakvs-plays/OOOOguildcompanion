-- Host test of the teams feature (.agents/user-wishes.md, "Teams"; Addon/Src/Teams/): the keys and checks of the
-- tables `team` and `team_alias` (TeamData.lua), the officers' operations and a member's alias request
-- (Teams.lua), the account ids that detect a character and move with it, the clerk of an officer's addon that
-- applies the requests and adds new account ids (TeamClerk.lua), the alias in chat (TeamChat.lua), and the rows
-- of the roster tab (TeamRoster.lua). The model tests run on one replica that is not logged in, with the records
-- of other members stored as if they had arrived; the replication tests run replicas on the fake network. The
-- delay of a clerk is fixed where the order of two writes matters, so that no seed makes a test flaky.
local T = dofile("Tests/harness.lua")
local Fakenet = dofile("Tests/fakenet.lua")
local Replica = dofile("Tests/fixtures/replica.lua")(T)

local random = T.newRandom()
local FILES = { "Addon/Src/Teams/TeamData.lua", "Addon/Src/Teams/Teams.lua", "Addon/Src/Teams/TeamClerk.lua",
  "Addon/Src/Teams/TeamChat.lua", "Addon/Src/Teams/TeamRoster.lua" }
local TABLE, REQUEST_TABLE, CHARACTER_TABLE = "team", "team_alias", "character"
local OFFICER, SECOND_OFFICER = 0, 1

---A delay source that always gives the shortest delay
---@return number
local function fast()
  return 0
end

---A delay source that always gives a delay of 9.9 seconds
---@return number
local function slow()
  return 0.99
end

---@class TeamTestReplica: TestReplica
---@field model table The teams model of this replica
---@field clerk table|nil The clerk while one runs
---@field delay fun(): number The random source of the clerk; a test may change it
---@field teamWrites string[] Keys of the table `team` that this replica wrote or deleted itself

---@class TeamTestOptions
---@field rankIndex integer? Rank index; a member when omitted
---@field origin string? Origin of the install
---@field data table? The stored database of another replica: an alt of the same install
---@field delay (fun(): number)? Random source of the clerk; the seeded one when omitted
---@field login boolean? false: not logged in and no clerk; the replica is in the roster, online, and sends nothing
---@field offline boolean? true: offline and not logged in; log it in later with `login`

---Starts the clerk of a replica.
---@param replica TeamTestReplica
local function startClerk(replica)
  replica.clerk = replica.ns.teamClerk.new({
    sync = replica.sync,
    model = replica.model,
    after = function(seconds, fn)
      return replica.endpoint:After(seconds, fn)
    end,
    random = function()
      return replica.delay()
    end,
  })
end

---Logs a replica in and starts its clerk.
---@param replica TeamTestReplica
local function login(replica)
  replica:Login()
  startClerk(replica)
end

---Stops the clerk of a replica and logs it out.
---@param replica TeamTestReplica
local function logout(replica)
  replica.clerk:Stop()
  replica.clerk = nil
  replica:Logout()
end

---Makes a replica with the team tables and a model, and logs it in with a clerk unless the options say otherwise.
---The team files load before the login, so that the session knows the tables.
---@param net Fakenet
---@param name string
---@param options TeamTestOptions?
---@return TeamTestReplica
local function withTeams(net, name, options)
  options = options or {}
  local replica = Replica.new(net, name, { random = random, rankIndex = options.rankIndex, origin = options.origin,
    data = options.data }) --[[@as TeamTestReplica]]
  T.loadAll(FILES, replica.ns)
  replica.model = replica.ns.teams.new({
    sync = replica.sync,
    playerName = function()
      return name
    end,
  })
  replica.delay = options.delay or function()
    return random()
  end
  replica.teamWrites = {}
  replica.sync.RegisterCallback({}, "OnRecordChanged", function(_event, tableName, key, _payload, isRemote)
    if tableName == TABLE and not isRemote then
      replica.teamWrites[#replica.teamWrites + 1] = key
    end
  end)
  if options.offline then
    net:SetOnline(name, false)
  elseif options.login ~= false then
    login(replica)
  end
  return replica
end

---Counter of the ids that `arrive` makes, so that two records of one origin in one second differ
local arrived = 0

---Stores a record as if another member had pushed it: the id has the given origin and the current time (or
---`ago` seconds before it). "OnRecordChanged" fires as for a received push.
---@param replica TeamTestReplica
---@param tableName string
---@param key string
---@param payload table
---@param origin string The writer: 4 base-94 characters
---@param ago integer? Seconds before the current time
---@return string id
local function arrive(replica, tableName, key, payload, origin, ago)
  arrived = arrived + 1
  local id = replica.ns.versionId.make(math.floor(replica.net:Now()) - (ago or 0), origin, arrived)
  local changed = replica.sync:ApplyRemote(tableName, { { key = key, id = id, payload = payload } })
  assert(#changed == 1, "the record was not stored: " .. tableName .. " " .. key)
  return id
end

---Stores the record of a character in the table `character` as if the character had pushed it. Its first
---account id in sorted order is the writer.
---@param replica TeamTestReplica
---@param name string
---@param origins string[]
---@param class string? Class token; "MAGE" when omitted
---@return string id
local function arriveCharacter(replica, name, origins, class)
  local sorted = { table.unpack(origins) }
  table.sort(sorted)
  return arrive(replica, CHARACTER_TABLE, name, { class = class or "MAGE", level = 60, origins = sorted }, sorted[1])
end

---Writes the record of the character of a replica in the table `character`, as the game does after the login.
---@param replica TeamTestReplica
---@param others string[]? Further account ids that the record lists: other installs of the player
---@return boolean|nil written
local function writeCharacter(replica, others)
  local previous = others and { origins = others } or replica.sync:Get(CHARACTER_TABLE, replica.name)
  return replica.sync:Put(CHARACTER_TABLE, replica.name,
    replica.ns.syncCharacter.buildPayload("MAGE", 60, replica.sync:GetOrigin(), previous))
end

---Counts the records of the table `team` that are not deleted.
---@param replica TeamTestReplica
---@return integer
local function teamRecords(replica)
  local live = replica.sync:Count(TABLE)
  return live
end

---Sorts a copy of a list.
---@param list string[]
---@return string[]
local function sorted(list)
  local copy = { table.unpack(list) }
  table.sort(copy)
  return copy
end

--------------------------------------------------------------------------------
-- TeamData: aliases, keys, and the checks of the records
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local replica = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false })
  local data, versionId = replica.ns.teamData, replica.ns.versionId

  T.eq(data.isAlias("nota"), true, "a word is an alias")
  T.eq(data.isAlias("Nota Tall"), true, "with a space inside")
  T.eq(data.isAlias(string.rep("x", data.MAX_ALIAS)), true, "of the longest length")
  T.eq(data.isAlias(string.rep("x", data.MAX_ALIAS + 1)), false, "one byte longer is not")
  T.eq(data.isAlias(""), false, "the empty text is not")
  T.eq(data.isAlias("a|b"), false, "nor a text with |")
  T.eq(data.isAlias("a\tb"), false, "nor one with a control character")
  T.eq(data.isAlias("a\nb"), false, "nor one with a line break")
  T.eq(data.isAlias(" nota"), false, "nor one with a space at the start")
  T.eq(data.isAlias("nota "), false, "nor at the end")
  T.eq(data.isAlias(42), false, "nor a number")
  T.eq(data.isAlias(nil), false, "nor nil")

  T.eq({ data.cleanAlias("  nota  ") }, { "nota" }, "cleanAlias cuts the spaces at both ends")
  T.eq({ data.cleanAlias(" " .. string.rep("x", data.MAX_ALIAS) .. " ") }, { string.rep("x", data.MAX_ALIAS) },
    "the spaces do not count toward the length")
  T.eq({ data.cleanAlias("") }, { nil, "empty" }, "the empty text is refused as empty")
  T.eq({ data.cleanAlias("   ") }, { nil, "empty" }, "spaces alone too")
  T.eq({ data.cleanAlias(nil) }, { nil, "empty" }, "and a text that is no string")
  T.eq({ data.cleanAlias(string.rep("x", data.MAX_ALIAS + 1)) }, { nil, "too long" }, "a long text is too long")
  T.eq({ data.cleanAlias("a|b") }, { nil, "bad character" }, "a text with | has a bad character")
  T.eq({ data.cleanAlias("a\1b") }, { nil, "bad character" }, "a control character too")

  local id = versionId.make(1795000000, "AB:C", 7)
  local colonId = versionId.make(1795000000, "A:B:", 58)
  T.ok(colonId:find(":", 1, true), "a version id can contain :")
  T.eq(data.parseKey(data.teamKey(id)), { kind = "team", id = id }, "parseKey reads a team key")
  T.eq(data.parseKey("t:" .. colonId), { kind = "team", id = colonId }, "also one whose id contains :")
  T.eq(data.parseKey("t:short"), nil, "a team key without a version id is refused")
  T.eq(data.parseKey("t:"), nil, "also an empty one")
  T.eq(data.parseKey(data.characterKey("Nota Scam")), { kind = "character", name = "Nota Scam" },
    "a character key keeps the space of the name")
  T.eq(data.parseKey("c:"), nil, "a character key without a name is refused")
  T.eq(data.parseKey("c:Nota:Scam"), nil, "a name with : is refused")
  T.eq(data.parseKey("c:Nota|Scam"), nil, "a name with | too")
  T.eq(data.parseKey("c:" .. string.rep("x", data.MAX_NAME)), { kind = "character", name = string.rep("x", 48) },
    "a name of the longest length is taken")
  T.eq(data.parseKey("c:" .. string.rep("x", data.MAX_NAME + 1)), nil, "a longer one is refused")
  T.eq(data.parseKey(data.accountKey("AAAA")), { kind = "account", origin = "AAAA" }, "an account key")
  T.eq(data.parseKey("o:A:B:"), { kind = "account", origin = "A:B:" }, "an account id can contain :")
  T.eq(data.parseKey("o:AAA"), nil, "a short account id is refused")
  T.eq(data.parseKey("o:AAAAA"), nil, "a long one too")
  T.eq(data.parseKey("o:AA A"), nil, "and one with a space")
  T.eq(data.parseKey("x:AAAA"), nil, "an unknown kind is refused")
  T.eq(data.parseKey("tAAAA"), nil, "a key without the colon too")
  T.eq(data.parseKey(""), nil, "the empty key")
  T.eq(data.parseKey(42), nil, "and a number")

  local teamKey = data.teamKey(id)
  T.eq(data.validateTeam(teamKey, { a = "Scams" }), true, "a team with the alias of the officer is valid")
  T.eq(data.validateTeam(teamKey, { a = "Scams", p = "Scammy", pv = id }), true, "with the player's alias and its id")
  T.eq(data.validateTeam(teamKey, { a = "Scams", p = "Scammy", pv = id, f = true }), true, "and denied")
  T.eq(data.validateTeam(teamKey, { a = "Scams", f = true }), true, "denied without a player's alias")
  T.eq(data.validateTeam(teamKey, { a = "Scams", p = "Scammy" }), false, "p without pv is refused")
  T.eq(data.validateTeam(teamKey, { a = "Scams", pv = id }), false, "pv without p too")
  T.eq(data.validateTeam(teamKey, { a = "Scams", p = "Scammy", pv = "bad" }), false, "a pv that is no id too")
  T.eq(data.validateTeam(teamKey, { a = "Scams", p = "a|b", pv = id }), false, "a p that is no alias too")
  T.eq(data.validateTeam(teamKey, { a = "Scams", f = false }), false, "f can only be true")
  T.eq(data.validateTeam(teamKey, { a = "Scams", f = 1 }), false, "not a number")
  T.eq(data.validateTeam(teamKey, { a = "Scams", z = 1 }), false, "an extra field is refused")
  T.eq(data.validateTeam(teamKey, {}), false, "a team without an alias is refused")
  T.eq(data.validateTeam(teamKey, { a = " Scams" }), false, "and one with a bad alias")
  T.eq(data.validateTeam(teamKey, "Scams"), false, "a payload that is no table is refused")
  T.eq(data.validateTeam(data.characterKey("Nota Scam"), { t = id }), true, "a link of a character is valid")
  T.eq(data.validateTeam(data.accountKey("AAAA"), { t = colonId }), true, "a link of an account id too")
  T.eq(data.validateTeam(data.characterKey("Nota Scam"), { t = "bad" }), false, "a link to no id is refused")
  T.eq(data.validateTeam(data.characterKey("Nota Scam"), { t = id, a = "x" }), false, "a link with more fields too")
  T.eq(data.validateTeam(data.characterKey("Nota Scam"), { a = "Scams" }), false, "a team payload under a link key")
  T.eq(data.validateTeam(data.characterKey("Nota Scam"), "x"), false, "a link that is no table")
  T.eq(data.validateTeam("t:short", { a = "Scams" }), false, "a malformed key is refused")
  local strange = { nil, 1, true, "", {}, { a = {} }, { t = {} }, { p = 1, pv = 2 }, setmetatable({}, {}) }
  for index = 1, 9 do
    for _, key in ipairs({ teamKey, data.characterKey("Nota Scam"), data.accountKey("AAAA"), 7 }) do
      local called, valid = pcall(data.validateTeam, key, strange[index])
      T.eq({ called, valid }, { true, false }, "validateTeam refuses strange input " .. index .. " without raising")
    end
  end

  T.eq(data.validateRequest("Nota Scam", { a = "Scammy" }), true, "a request is valid")
  T.eq(data.validateRequest("Nota Scam", { a = "Scammy", b = 1 }), false, "with an extra field it is not")
  T.eq(data.validateRequest("Nota Scam", { a = "" }), false, "nor with an empty alias")
  T.eq(data.validateRequest("Nota Scam", { a = "a|b" }), false, "nor with a bad one")
  T.eq(data.validateRequest("Nota Scam", "Scammy"), false, "nor as a text")
  T.eq(data.validateRequest("Nota Scam:2", { a = "Scammy" }), false, "a joined key is refused")
  T.eq(data.validateRequest(42, { a = "Scammy" }), false, "and a key that is no name")
  T.eq(pcall(data.validateRequest, nil, nil), true, "validateRequest does not raise on nil")

  T.eq(replica.sync.definitions[TABLE].writers, "officer", "the table team is written by officers")
  T.eq(replica.sync.definitions[REQUEST_TABLE].writers, "self", "the table team_alias by each character")
end

--------------------------------------------------------------------------------
-- The model with one officer: create, read, add, remove, merge, disband, aliases
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false })
  local member = withTeams(net, "Member One", { login = false })
  local model, data = officer.model, officer.ns.teamData

  T.eq({ member.model:Create("Members", { "Member One" }) }, { nil, "not an officer" }, "a member cannot create")
  T.eq({ model:Create("", { "Nota Scam" }) }, { nil, "empty" }, "Create refuses an empty alias")
  T.eq({ model:Create("a|b", { "Nota Scam" }) }, { nil, "bad character" }, "and a bad one")
  T.eq({ model:Create(string.rep("x", 25), { "Nota Scam" }) }, { nil, "too long" }, "and a long one")
  T.eq({ model:Create("Scams", {}) }, { nil, "bad name" }, "and a team without a character")
  T.eq({ model:Create("Scams", { "Nota Scam", "Bad:Name" }) }, { nil, "bad name" }, "and a bad name")
  T.eq(teamRecords(officer), 0, "a refused Create writes nothing")

  local id = model:Create("  Scams  ", { "Nota Scam", "Nota Tall" })
  T.ok(id and data.parseKey(data.teamKey(id)), "Create gives the id of the team")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)), { a = "Scams" }, "the team holds the alias of the officer, cut")
  T.eq(officer.sync:Get(TABLE, data.characterKey("Nota Scam")), { t = id }, "each character is linked to it")
  T.eq(officer.sync:Get(TABLE, data.characterKey("Nota Tall")), { t = id }, "both")
  T.eq(teamRecords(officer), 3, "and nothing else: the characters have no account ids")
  T.eq({ model:TeamOf("Nota Scam") }, { id, false }, "TeamOf gives the team of an assigned character")
  T.eq({ model:TeamOf("Nobody Here") }, { nil, false }, "and nothing for another one")
  T.eq(model:Alias(id), "Scams", "Alias gives the alias of the officer")
  T.eq(model:Alias("no such team"), nil, "and nothing for a team that does not exist")
  T.eq(model:AliasOf("Nota Tall"), "Scams", "AliasOf gives the alias of the character's team")
  T.eq(model:AliasOf("Nobody Here"), nil, "and nothing for a character without a team")
  T.eq(model:Detail(id), { id = id, alias = "Scams", officerAlias = "Scams", denied = false,
    members = { "Nota Scam", "Nota Tall" }, detected = {}, origins = {} }, "Detail lists the team")
  T.eq(model:Detail("no such team"), nil, "Detail of a team that does not exist is nil")
  T.eq(member.model:AliasOf("Nota Scam"), nil, "the member's replica has not received it: nothing is sent here")

  T.eq({ model:Create("Again", { "Fresh One", "Nota Scam" }) }, { nil, "in a team" },
    "Create refuses a character that is in a team")
  T.eq({ model:TeamOf("Fresh One") }, { nil, false }, "and assigns none of the others")
  T.eq(teamRecords(officer), 3, "and writes nothing")

  -- Add
  T.eq({ model:Add(id, "Third One") }, { true }, "Add assigns a character without a team")
  T.eq({ model:TeamOf("Third One") }, { id, false }, "which is then in the team")
  T.eq({ model:Add(id, "Third One") }, { true }, "adding it again is no error")
  local others = model:Create("Others", { "Other One" })
  T.ok(others and others ~= id, "a second team")
  T.eq({ model:Add(others, "Third One") }, { false, "in a team" }, "Add refuses a character of another team")
  T.eq({ model:Add("no such team", "Fourth One") }, { false, "no team" }, "and a team that does not exist")
  T.eq({ model:Add(id, "bad|name") }, { false, "bad name" }, "and a bad name")
  T.eq({ member.model:Add(id, "Fourth One") }, { false, "not an officer" }, "a member cannot add")

  -- A link to a team that does not exist counts as no link
  local lost = officer.ns.versionId.make(1795000000, "LOST", 1)
  T.eq({ model:Link(data.characterKey("Lost One"), lost) }, { true }, "a link to a lost team is written")
  T.eq({ model:TeamOf("Lost One") }, { nil, false }, "it counts as no team")
  T.eq({ model:Add(id, "Lost One") }, { true }, "so the character can be added")

  -- Remove
  T.eq({ member.model:Remove("Nota Scam") }, { false, "not an officer" }, "a member cannot remove")
  T.eq({ model:Remove("Third One") }, { true }, "Remove takes a character out")
  T.eq({ model:TeamOf("Third One") }, { nil, false }, "it has no team then")
  T.eq(officer.sync:Get(TABLE, data.characterKey("Third One")), nil, "its link is deleted")
  T.eq({ model:Remove("Third One") }, { false, "no team" }, "a character without a team cannot be removed")
  T.eq(model:Detail(id).members, { "Lost One", "Nota Scam", "Nota Tall" }, "the others stay")
  T.eq({ model:Remove("Other One") }, { true }, "the last character of a team is removed")
  T.eq(model:Detail(others), nil, "and the team is gone")
  T.eq(officer.sync:Get(TABLE, data.teamKey(others)), nil, "its record is deleted")

  -- The alias of the officer
  T.eq({ model:SetOfficerAlias(id, " Scam Clan ") }, { true }, "SetOfficerAlias changes the alias")
  T.eq(model:Alias(id), "Scam Clan", "cut")
  T.eq({ model:SetOfficerAlias(id, "  ") }, { false, "empty" }, "an empty alias is refused")
  T.eq({ model:SetOfficerAlias(id, "a|b") }, { false, "bad character" }, "and a bad one")
  T.eq({ model:SetOfficerAlias("no such team", "x") }, { false, "no team" }, "and a team that does not exist")
  T.eq({ member.model:SetOfficerAlias(id, "x") }, { false, "not an officer" }, "a member cannot set it")
  T.eq(model:Alias(id), "Scam Clan", "the refusals change nothing")

  -- The request of a player, and the denial
  local alone = officer.ns.teams.new({ sync = officer.sync, playerName = function() return nil end })
  T.eq({ alone:SubmitAlias("Boss") }, { false, "not ready" }, "SubmitAlias without the own name is not ready")
  T.eq(alone:OwnRequest(), nil, "and there is no own request")
  alone:Stop()
  T.eq({ model:SubmitAlias("Boss") }, { false, "no team" }, "an officer without a team cannot ask either")
  T.eq({ model:Add(id, "Officer One") }, { true }, "the officer is added")
  T.eq({ model:SubmitAlias("a|b") }, { false, "bad character" }, "SubmitAlias refuses a bad alias")
  T.eq({ model:SubmitAlias("") }, { false, "empty" }, "and an empty one")
  T.eq({ model:SubmitAlias("  Boss  ") }, { true }, "SubmitAlias writes the request")
  T.eq(officer.sync:Get(REQUEST_TABLE, "Officer One"), { a = "Boss" }, "cut, under the own name")
  T.eq(model:OwnRequest(), "Boss", "OwnRequest gives it")
  T.eq(model:Alias(id), "Scam Clan", "the request alone changes nothing")
  local requestId = officer.sync:GetId(REQUEST_TABLE, "Officer One")
  T.eq(member.model:ApplyRequest("Officer One"), false, "a member's model applies nothing")
  T.eq(model:ApplyRequest("Nota Scam"), false, "a character without a request has nothing to apply")
  T.eq(model:ApplyRequest("Officer One"), true, "ApplyRequest copies the request into the team")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)), { a = "Scam Clan", p = "Boss", pv = requestId },
    "with the id of the request")
  T.eq(model:ApplyRequest("Officer One"), false, "applying it again does nothing")
  T.eq(model:Alias(id), "Boss", "the player's alias is shown")
  T.eq(model:AliasOf("Nota Scam"), "Boss", "for every character of the team")
  local detail = model:Detail(id)
  T.eq({ detail.alias, detail.officerAlias, detail.playerAlias, detail.denied }, { "Boss", "Scam Clan", "Boss", false },
    "Detail shows both aliases")
  T.eq({ member.model:SetDenied(id, true) }, { false, "not an officer" }, "a member cannot deny")
  T.eq({ model:SetDenied("no such team", true) }, { false, "no team" }, "a team that does not exist cannot be denied")
  T.eq({ model:SetDenied(id, true) }, { true }, "SetDenied denies the player's alias")
  T.eq(model:Alias(id), "Scam Clan", "the alias of the officer is shown then")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)), { a = "Scam Clan", p = "Boss", pv = requestId, f = true },
    "and the player's alias stays recorded")
  detail = model:Detail(id)
  T.eq({ detail.alias, detail.playerAlias, detail.denied }, { "Scam Clan", "Boss", true }, "Detail shows the denial")
  T.eq({ model:SetOfficerAlias(id, "Clan") }, { true }, "the officer's alias can change while denied")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)).f, true, "and the denial stays")
  T.eq({ model:SetDenied(id, false) }, { true }, "SetDenied allows it again")
  T.eq(model:Alias(id), "Boss", "the player's alias is shown again")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)), { a = "Clan", p = "Boss", pv = requestId }, "without f")
  T.eq({ model:SetDenied(id, false) }, { true }, "allowing it twice is no error")

  -- Merge
  local alpha = model:Create("Alpha", { "Merge One" })
  local beta = model:Create("Beta", { "Merge Two", "Merge Three" })
  T.eq({ model:Merge(alpha, alpha) }, { false, "same team" }, "a team cannot merge into itself")
  T.eq({ model:Merge(alpha, "no such team") }, { false, "no team" }, "nor into a team that does not exist")
  T.eq({ model:Merge("no such team", alpha) }, { false, "no team" }, "nor can a missing team merge")
  T.eq({ member.model:Merge(beta, alpha) }, { false, "not an officer" }, "a member cannot merge")
  T.eq({ model:Merge(beta, alpha) }, { true }, "Merge moves a team into another")
  T.eq(model:Detail(beta), nil, "the merged team is gone")
  T.eq(officer.sync:Get(TABLE, data.teamKey(beta)), nil, "its record is deleted")
  T.eq(model:Detail(alpha).members, { "Merge One", "Merge Three", "Merge Two" }, "its characters are in the other")
  T.eq(model:Alias(alpha), "Alpha", "whose alias stays")

  -- Disband
  T.eq({ member.model:Disband(alpha) }, { false, "not an officer" }, "a member cannot disband")
  T.eq({ model:Disband(alpha) }, { true }, "Disband ends a team")
  T.eq(model:Detail(alpha), nil, "it is gone")
  for _, name in ipairs({ "Merge One", "Merge Two", "Merge Three" }) do
    T.eq(officer.sync:Get(TABLE, data.characterKey(name)), nil, "the link of " .. name .. " is deleted")
  end
  T.eq({ model:Disband(alpha) }, { false, "no team" }, "a team cannot be disbanded twice")
  T.eq(model:Detail(id).alias, "Boss", "the other team is untouched")
end

--------------------------------------------------------------------------------
-- Account ids: detection, conflicts, and what moves with a character
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false })
  local member = withTeams(net, "Member One", { login = false })
  local model, data = officer.model, officer.ns.teamData

  arriveCharacter(officer, "Alt One", { "BBBB" })
  arriveCharacter(officer, "Alt Two", { "BBBB" })
  arriveCharacter(officer, "Alt Three", { "CCCC", "BBBB" })
  T.eq(model:OriginsOf("Alt Three"), { "BBBB", "CCCC" }, "OriginsOf lists the account ids of a character, sorted")
  T.eq(model:OriginsOf("Nobody Here"), {}, "and none for a character without a record")
  local alts = model:Create("Alts", { "Alt One" })
  T.eq(officer.sync:Get(TABLE, data.accountKey("BBBB")), { t = alts }, "Create links the account id of the character")
  T.eq(model:Detail(alts).origins, { "BBBB" }, "Detail lists it")
  T.eq({ model:TeamOf("Alt Two") }, { alts, true }, "a character that shares the account id is detected")
  T.eq(model:AliasOf("Alt Two"), "Alts", "and shows the alias of the team")
  T.eq({ model:TeamOf("Alt Three") }, { alts, true }, "also with a second account id")
  T.eq(model:Detail(alts).detected, { "Alt Three", "Alt Two" }, "Detail lists the detected characters")
  T.eq(model:Detail(alts).members, { "Alt One" }, "apart from the assigned ones")
  local detectedModel = officer.ns.teams.new({ sync = officer.sync, playerName = function() return "Alt Two" end })
  T.eq({ detectedModel:SubmitAlias("Twos") }, { false, "no team" }, "a detected character cannot ask for an alias")
  detectedModel:Stop()

  local others = model:Create("Others", { "Other One" })
  T.eq({ model:Add(others, "Alt Two") }, { false, "account in another team", alts },
    "Add refuses a character whose account id is in another team")
  T.eq({ model:Move("Alt Two", others) }, { false, "account in another team" },
    "and Move of a character without a team")
  T.eq({ model:Create("Thirds", { "Alt Three" }) }, { nil, "account in another team" }, "and so does Create")
  T.eq(officer.sync:Get(TABLE, data.characterKey("Alt Two")), nil, "nothing is written")
  T.eq({ model:Add(alts, "Alt Two") }, { true }, "the character can join the team of its account id")
  T.eq({ model:TeamOf("Alt Two") }, { alts, false }, "it is assigned then")
  T.eq(model:Detail(alts).detected, { "Alt Three" }, "and no longer detected")
  T.eq({ model:Add(alts, "Alt Three") }, { true }, "the character with two account ids joins too")
  T.eq(model:Detail(alts).origins, { "BBBB", "CCCC" }, "and brings its second account id")

  -- A deleted record of a character detects nothing
  arriveCharacter(officer, "Gone One", { "BBBB" })
  T.eq({ model:TeamOf("Gone One") }, { alts, true }, "a new character of the account is detected")
  officer.sync:ApplyRemote(CHARACTER_TABLE, { { key = "Gone One", tombstone = true,
    id = officer.ns.versionId.make(math.floor(net:Now()) + 1, "BBBB", 1) } })
  T.eq({ model:TeamOf("Gone One") }, { nil, false }, "after the deletion of its record it is not")

  -- Remove keeps an account id while another member of the team shares it
  arriveCharacter(officer, "Pair One", { "JJJJ" })
  arriveCharacter(officer, "Pair Two", { "JJJJ" })
  local pair = model:Create("Pair", { "Pair One", "Pair Two" })
  T.eq(model:Detail(pair).origins, { "JJJJ" }, "the shared account id is linked once")
  T.eq({ model:Remove("Pair One") }, { true }, "one of two characters of an account is removed")
  T.eq(officer.sync:Get(TABLE, data.accountKey("JJJJ")), { t = pair }, "the account id stays with the team")
  T.eq({ model:TeamOf("Pair One") }, { pair, true }, "so the removed character is detected again")
  T.eq({ model:Remove("Pair Two") }, { true }, "the other one is removed")
  T.eq(officer.sync:Get(TABLE, data.accountKey("JJJJ")), nil, "then the account id leaves")
  T.eq(officer.sync:Get(TABLE, data.teamKey(pair)), nil, "and the empty team is deleted")
  T.eq({ model:TeamOf("Pair One") }, { nil, false }, "and nothing is detected")

  -- Remove takes an own account id along that no other member has
  arriveCharacter(officer, "Solo Main", { "KKKK" })
  arriveCharacter(officer, "Solo Alt", { "LLLL" })
  local solo = model:Create("Solo", { "Solo Main", "Solo Alt" })
  T.eq({ model:Remove("Solo Alt") }, { true }, "a character with its own account id is removed")
  T.eq(model:Detail(solo).origins, { "KKKK" }, "and its account id leaves the team")

  -- Move takes along the characters of the old team that share an account id
  arriveCharacter(officer, "Mover", { "DDDD" })
  arriveCharacter(officer, "Mover Alt", { "DDDD", "MMMM" })
  arriveCharacter(officer, "Mover Third", { "MMMM" })
  arriveCharacter(officer, "Stayer", { "EEEE" })
  arriveCharacter(officer, "Target", { "FFFF" })
  local old = model:Create("Old", { "Mover", "Mover Alt", "Mover Third", "Stayer", "No Addon" })
  local target = model:Create("Target", { "Target" })
  T.eq(model:Detail(old).origins, { "DDDD", "EEEE", "MMMM" }, "the old team holds the account ids")
  T.eq({ member.model:Move("Mover", target) }, { false, "not an officer" }, "a member cannot move")
  T.eq({ model:Move("Mover", "no such team") }, { false, "no team" }, "nor can a character move to no team")
  local ok, reason, moved = model:Move("Mover", target)
  T.eq({ ok, reason }, { true, nil }, "Move moves a character")
  T.eq(moved and moved[1], "Mover", "the character itself first")
  T.eq(sorted(moved or {}), { "Mover", "Mover Alt", "Mover Third" },
    "with the characters that share an account id, also through another character")
  T.eq(model:Detail(target).members, { "Mover", "Mover Alt", "Mover Third", "Target" }, "they are in the new team")
  T.eq(model:Detail(target).origins, { "DDDD", "FFFF", "MMMM" }, "with their account ids")
  T.eq(model:Detail(old).members, { "No Addon", "Stayer" }, "the others stay in the old team")
  T.eq(model:Detail(old).origins, { "EEEE" }, "with their account ids")
  T.eq(model:Alias(target), "Target", "the alias of the new team stays")
  T.eq({ model:Move("Stayer", target) }, { true, nil, { "Stayer" } }, "a character with its own account id moves alone")
  T.eq({ model:Move("No Addon", target) }, { true, nil, { "No Addon" } }, "the last one of the old team moves")
  T.eq(model:Detail(old), nil, "and the emptied team is deleted")
  T.eq(officer.sync:Get(TABLE, data.teamKey(old)), nil, "with its record")
  T.eq(officer.sync:Get(TABLE, data.accountKey("EEEE")), { t = target },
    "the moved account id is linked to the new team")
  T.eq({ model:Move("Stayer", target) }, { true, nil, {} }, "a move into the own team moves nothing")
  T.eq({ model:Move("Newcomer", target) }, { true, nil, { "Newcomer" } }, "Move adds a character without a team")
  T.eq({ model:TeamOf("Newcomer") }, { target, false }, "which is then assigned")

  -- Move is refused when an account id of the group is held by a third team
  arriveCharacter(officer, "Split", { "HHHH" })
  local split = model:Create("Split", { "Split" })
  arriveCharacter(officer, "Dee", { "IIII" })
  local dee = model:Create("Dee", { "Dee" })
  arriveCharacter(officer, "Split", { "HHHH", "IIII" })
  T.eq({ model:Move("Split", others) }, { false, "account in another team" },
    "Move refuses a character with an account id of a third team")
  T.eq({ model:TeamOf("Split") }, { split, false }, "and moves nothing")
  T.eq(model:Detail(others).members, { "Other One" }, "nothing arrives in the target")
  T.eq({ model:Move("Split", dee) }, { true, nil, { "Split" } }, "the move into the team that holds it works")
  T.eq(model:Detail(dee).origins, { "HHHH", "IIII" }, "with both account ids")
  T.eq(model:Detail(split), nil, "and the emptied team is deleted")

  -- Merge takes the account ids along; Disband deletes them
  T.eq({ model:Merge(dee, others) }, { true }, "a team with account ids is merged")
  T.eq(officer.sync:Get(TABLE, data.accountKey("HHHH")), { t = others }, "its account ids are linked to the other team")
  T.eq(model:Detail(others).origins, { "HHHH", "IIII" }, "both")
  T.eq({ model:TeamOf("Dee") }, { others, false }, "and its characters are in it")
  T.eq({ model:Disband(others) }, { true }, "the team is disbanded")
  for _, key in ipairs({ data.accountKey("HHHH"), data.accountKey("IIII"), data.characterKey("Dee"),
    data.characterKey("Split"), data.characterKey("Other One"), data.teamKey(others) }) do
    T.eq(officer.sync:Get(TABLE, key), nil, "Disband deletes " .. key)
  end
end

--------------------------------------------------------------------------------
-- Replication and permissions on the fake network
--------------------------------------------------------------------------------

-- One officer and two members: the officer's team reaches everyone, a member's request goes through the clerk,
-- and a denial keeps the officer's alias
do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, delay = fast })
  local member = withTeams(net, "Nota Scam")
  local other = withTeams(net, "Other One")
  local everyone = { officer, member, other }
  net:Advance(100)
  local data = officer.ns.teamData

  T.eq({ member.model:SubmitAlias("Scammy") }, { false, "no team" }, "before an assignment a member cannot ask")
  T.eq(member.sync:Get(REQUEST_TABLE, "Nota Scam"), nil, "and writes no request")
  T.eq({ member.model:Create("Mine", { "Nota Scam" }) }, { nil, "not an officer" }, "a member cannot create a team")
  T.eq({ member.sync:Put(TABLE, data.characterKey("Nota Scam"), { t = officer.sync:NewId(TABLE) }) },
    { nil, "not an officer" }, "nor write the table team through the engine")
  T.eq({ member.sync:Put(REQUEST_TABLE, "Other One", { a = "Other" }) }, { nil, "not the owner" },
    "nor a request of another character")

  local id = officer.model:Create("Scams", { "Nota Scam" })
  net:Advance(120)
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Scams", replica.name .. " shows the alias of the officer")
    T.eq({ replica.model:TeamOf("Nota Scam") }, { id, false }, replica.name .. " has the assignment")
  end
  T.eq({ member.model:Add(id, "Other One") }, { false, "not an officer" }, "a member cannot add to the team")
  T.eq({ other.model:SubmitAlias("Others") }, { false, "no team" }, "a member outside the team cannot ask")

  T.eq({ member.model:SubmitAlias("  Scammy ") }, { true }, "the assigned member asks for an alias")
  T.eq(member.model:OwnRequest(), "Scammy", "and sees its request")
  T.eq(member.model:AliasOf("Nota Scam"), "Scams", "the alias changes only when an officer has taken it")
  net:Advance(120)
  local requestId = member.sync:GetId(REQUEST_TABLE, "Nota Scam")
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Scammy", replica.name .. " shows the player's alias")
    T.eq(replica.sync:Get(TABLE, data.teamKey(id)), { a = "Scams", p = "Scammy", pv = requestId },
      replica.name .. " holds the request in the team record")
  end
  T.eq(#member.teamWrites + #other.teamWrites, 0, "the clerk of a member writes nothing")

  -- A denied team keeps the officer's alias, but records the next request
  T.eq({ officer.model:SetDenied(id, true) }, { true }, "the officer denies the player's alias")
  net:Advance(120)
  T.eq({ member.model:SubmitAlias("Rude Word") }, { true }, "the player asks for another one")
  net:Advance(120)
  local rudeId = member.sync:GetId(REQUEST_TABLE, "Nota Scam")
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Scams", replica.name .. " shows the officer's alias while denied")
    T.eq(replica.sync:Get(TABLE, data.teamKey(id)), { a = "Scams", p = "Rude Word", pv = rudeId, f = true },
      replica.name .. " still records the request")
  end
  T.eq({ officer.model:SetDenied(id, false) }, { true }, "the officer allows it again")
  net:Advance(120)
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Rude Word", replica.name .. " shows the player's alias again")
  end
  T.eq(#member.teamWrites + #other.teamWrites, 0, "the members wrote nothing to the table team")
end

-- Two officers online: one writes, the other finds the work done; with random delays the result is the same
do
  local net = Fakenet.new({ random = random })
  local first = withTeams(net, "Officer One", { rankIndex = OFFICER, delay = fast })
  local second = withTeams(net, "Officer Two", { rankIndex = SECOND_OFFICER, delay = slow })
  local member = withTeams(net, "Nota Scam")
  local everyone = { first, second, member }
  net:Advance(100)
  local data = first.ns.teamData
  local id = first.model:Create("Scams", { "Nota Scam" })
  net:Advance(120)
  local before = { #first.teamWrites, #second.teamWrites }
  T.eq({ member.model:SubmitAlias("Scammy") }, { true }, "the member asks with two officers online")
  net:Advance(120)
  T.eq({ #first.teamWrites - before[1], #second.teamWrites - before[2] }, { 1, 0 },
    "the faster clerk writes once, the slower one finds the request applied")
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Scammy", replica.name .. " shows the player's alias")
    T.eq(replica:Version(TABLE), first:Version(TABLE), replica.name .. " has the version of the first officer")
  end

  -- Both officers assign one character at the same time: every replica ends with the same team for it
  local firstTeam = first.model:Create("Firsts", { "Same Time" })
  local secondTeam = second.model:Create("Seconds", { "Same Time" })
  T.ok(firstTeam and secondTeam and firstTeam ~= secondTeam, "two officers make a team for one character at once")
  net:Advance(120)
  local winner = first.model:TeamOf("Same Time")
  T.ok(winner == firstTeam or winner == secondTeam, "one of the two teams has the character")
  for _, replica in ipairs(everyone) do
    T.eq({ replica.model:TeamOf("Same Time") }, { winner, false }, replica.name .. " agrees on its team")
    T.eq(replica:Version(TABLE), first:Version(TABLE), replica.name .. " has the same version")
  end

  for round = 1, 5 do
    first.delay, second.delay = function() return random() end, function() return random() end
    local alias = "Try " .. round
    T.eq({ member.model:SubmitAlias(alias) }, { true }, "round " .. round .. ": the member asks again")
    net:Advance(120)
    local record = first.sync:Get(TABLE, data.teamKey(id))
    T.eq(record, { a = "Scams", p = alias, pv = member.sync:GetId(REQUEST_TABLE, "Nota Scam") },
      "round " .. round .. ": the newest request is applied")
    for _, replica in ipairs(everyone) do
      T.eq(replica.sync:GetTable(TABLE).records, first.sync:GetTable(TABLE).records,
        "round " .. round .. ": " .. replica.name .. " holds the same records")
      T.eq(replica:Version(TABLE), first:Version(TABLE), "round " .. round .. ": and the same version")
    end
  end
end

-- The newest request of two characters of one team wins, and an officer who logs in later takes a request that
-- was written while no officer was online
do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, delay = fast })
  local scam = withTeams(net, "Nota Scam")
  local tall = withTeams(net, "Nota Tall")
  local other = withTeams(net, "Other One")
  local everyone = { officer, scam, tall, other }
  net:Advance(100)
  local id = officer.model:Create("Notas", { "Nota Scam", "Nota Tall" })
  net:Advance(120)
  T.eq({ scam.model:SubmitAlias("Scammy") }, { true }, "the first character asks")
  net:Advance(10)
  T.eq({ tall.model:SubmitAlias("Tally") }, { true }, "ten seconds later the second one asks")
  net:Advance(120)
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Tally", replica.name .. " shows the newest request")
  end
  T.eq(officer.model:ApplyRequest("Nota Scam"), false, "the older request is not applied again")

  logout(officer)
  net:Advance(10)
  T.eq({ scam.model:SubmitAlias("Offline") }, { true }, "a request while no officer is online")
  net:Advance(120)
  T.eq(other.sync:Get(REQUEST_TABLE, "Nota Scam"), { a = "Offline" }, "it reaches the members online")
  T.eq(other.model:AliasOf("Nota Scam"), "Tally", "but nobody applies it")
  login(officer)
  net:Advance(600)
  for _, replica in ipairs(everyone) do
    T.eq(replica.model:AliasOf("Nota Scam"), "Offline", replica.name .. " shows it after the officer's login")
  end
  T.eq(officer.model:Detail(id).playerAlias, "Offline", "the team records it")
end

-- The clerk's check is cut off by a logout; the scan after the next login applies the stored request
do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, delay = slow })
  local member = withTeams(net, "Nota Scam")
  net:Advance(100)
  local id = officer.model:Create("Scams", { "Nota Scam" })
  net:Advance(120)
  local start = net:Now()
  T.eq({ member.model:SubmitAlias("Scammy") }, { true }, "the member asks")
  local waited = 0
  while officer.sync:Get(REQUEST_TABLE, "Nota Scam") == nil and waited < 30 do
    net:Advance(0.5)
    waited = waited + 0.5
  end
  T.eq(officer.sync:Get(REQUEST_TABLE, "Nota Scam"), { a = "Scammy" }, "the request reaches the officer")
  T.ok(net:Now() - start < 9, "before the slow clerk checks it")
  T.ok(next(officer.clerk.pending) ~= nil, "a check waits")
  logout(officer)
  net:Advance(60)
  T.eq(member.model:AliasOf("Nota Scam"), "Scams", "the logout cut the check off")
  T.eq(officer.model:Alias(id), "Scams", "also in the officer's database")
  login(officer)
  net:Advance(officer.ns.teamClerk.SCAN_DELAY - 1)
  T.eq(officer.model:Alias(id), "Scams", "before the scan nothing is applied")
  net:Advance(120)
  T.eq(officer.model:Alias(id), "Scammy", "the scan applies the stored request")
  T.eq(member.model:AliasOf("Nota Scam"), "Scammy", "and the member receives it")
end

-- Alts of one install: the account id detects the other character on every replica
do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, delay = fast })
  local other = withTeams(net, "Other One")
  local main = withTeams(net, "Nota Scam", { offline = true })
  local alt = withTeams(net, "Nota Tall", { offline = true, data = main.data })
  net:Advance(100)
  login(main)
  T.eq(writeCharacter(main), true, "the main writes its character record")
  net:Advance(200)
  logout(main)
  net:Advance(10)
  login(alt)
  T.eq(writeCharacter(alt), true, "the alt of the same install writes its record")
  net:Advance(200)
  local origin = main.sync:GetOrigin()
  T.eq(officer.model:OriginsOf("Nota Tall"), { origin }, "the officer holds both records with one account id")
  local id = officer.model:Create("Notas", { "Nota Scam" })
  net:Advance(120)
  for _, replica in ipairs({ officer, other, alt }) do
    T.eq(replica.model:Detail(id).origins, { origin }, replica.name .. " has the account id in the team")
    T.eq({ replica.model:TeamOf("Nota Tall") }, { id, true }, replica.name .. " detects the alt")
    T.eq(replica.model:AliasOf("Nota Tall"), "Notas", replica.name .. " shows the alias for the alt")
  end
  T.eq({ alt.model:SubmitAlias("Tally") }, { false, "no team" }, "the detected alt cannot ask for an alias")
  local others = officer.model:Create("Others", { "Other One" })
  T.eq({ officer.model:Add(others, "Nota Tall") }, { false, "account in another team", id },
    "the alt cannot join another team")
end

--------------------------------------------------------------------------------
-- The clerk, on one officer replica with records that arrive as from other members
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false, delay = fast })
  startClerk(officer)
  local model, data, versionId = officer.model, officer.ns.teamData, officer.ns.versionId
  local now = math.floor(net:Now())

  -- A request that arrives before the assignment is applied once the assignment arrives
  local first = arrive(officer, REQUEST_TABLE, "Nota Scam", { a = "Scammy" }, "RRRR")
  net:Advance(20)
  T.eq(#officer.teamWrites, 0, "the request of a character without a team is left alone")
  local id = versionId.make(now, "OFFI", 1)
  arrive(officer, TABLE, data.teamKey(id), { a = "Scams" }, "OFFI")
  T.eq(model:Alias(id), "Scams", "the team of another officer arrives")
  net:Advance(20)
  T.eq(#officer.teamWrites, 0, "a team without the character changes nothing")
  arrive(officer, TABLE, data.characterKey("Nota Scam"), { t = id }, "OFFI")
  net:Advance(20)
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)), { a = "Scams", p = "Scammy", pv = first },
    "the assignment arrives and the waiting request is applied")
  T.eq(model:AliasOf("Nota Scam"), "Scammy", "the player's alias is shown")

  -- The newest request of the characters of one team wins, whatever the order of arrival
  arrive(officer, TABLE, data.characterKey("Nota Tall"), { t = id }, "OFFI")
  arrive(officer, TABLE, data.characterKey("Nota Short"), { t = id }, "OFFI")
  net:Advance(20)
  local newer = arrive(officer, REQUEST_TABLE, "Nota Tall", { a = "Tally" }, "TTTT")
  net:Advance(20)
  T.eq(model:AliasOf("Nota Scam"), "Tally", "a newer request of another character of the team wins")
  local writes = #officer.teamWrites
  arrive(officer, REQUEST_TABLE, "Nota Short", { a = "Shorty" }, "SSSS", 100)
  net:Advance(20)
  T.eq(model:AliasOf("Nota Scam"), "Tally", "an older request that arrives later does not")
  T.eq(officer.sync:Get(TABLE, data.teamKey(id)).pv, newer, "the team keeps the id of the newest request")
  T.eq(#officer.teamWrites, writes, "and nothing is written")

  -- A new account id of an assigned character is added; one of another team stays there
  arriveCharacter(officer, "Nota Scam", { "NNNN" })
  net:Advance(20)
  T.eq(officer.sync:Get(TABLE, data.accountKey("NNNN")), { t = id }, "the account id of a new record is added")
  T.eq(model:Detail(id).origins, { "NNNN" }, "to the team of the character")
  arriveCharacter(officer, "Holder", { "PPPP" })
  local holder = model:Create("Holder", { "Holder" })
  net:Advance(20)
  arriveCharacter(officer, "Nota Scam", { "NNNN", "PPPP", "QQQQ" })
  net:Advance(20)
  T.eq(model:Detail(id).origins, { "NNNN", "QQQQ" }, "a further account id is added when the record changes")
  T.eq(officer.sync:Get(TABLE, data.accountKey("PPPP")), { t = holder }, "an account id of another team stays there")
  arriveCharacter(officer, "Detected One", { "NNNN", "UUUU" })
  net:Advance(20)
  T.eq({ model:TeamOf("Detected One") }, { id, true }, "a character of the account is detected")
  T.eq(officer.sync:Get(TABLE, data.accountKey("UUUU")), nil, "but its other account id is not added")

  -- A stopped clerk checks nothing
  officer.delay = slow
  arrive(officer, TABLE, data.characterKey("Late One"), { t = id }, "OFFI")
  arrive(officer, REQUEST_TABLE, "Late One", { a = "Latey" }, "VVVV")
  officer.clerk:Stop()
  net:Advance(60)
  T.eq(model:AliasOf("Late One"), "Tally", "after Stop the pending check does not run")

  -- The scan of a new clerk applies what is stored
  startClerk(officer)
  net:Advance(officer.ns.teamClerk.SCAN_DELAY)
  T.eq(model:AliasOf("Late One"), "Tally", "not before the scan")
  net:Advance(officer.ns.teamClerk.DELAY_MAX)
  T.eq(model:AliasOf("Late One"), "Latey", "the scan applies the stored request")
  officer.clerk:Stop()
end

-- The clerk of a member does nothing
do
  local net = Fakenet.new({ random = random })
  local member = withTeams(net, "Member One", { login = false, delay = fast })
  startClerk(member)
  local data, versionId = member.ns.teamData, member.ns.versionId
  local id = versionId.make(math.floor(net:Now()), "OFFI", 1)
  arrive(member, TABLE, data.teamKey(id), { a = "Scams" }, "OFFI")
  arrive(member, TABLE, data.characterKey("Nota Scam"), { t = id }, "OFFI")
  arrive(member, REQUEST_TABLE, "Nota Scam", { a = "Scammy" }, "RRRR")
  arriveCharacter(member, "Nota Scam", { "NNNN" })
  T.eq(next(member.clerk.pending), nil, "a member's clerk schedules nothing")
  net:Advance(200)
  T.eq(#member.teamWrites, 0, "and writes nothing, also in its scan")
  T.eq(member.model:AliasOf("Nota Scam"), "Scams", "the request stays unapplied")
end

-- On the network: the account id of a character that was assigned before it had a record
do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER })
  local member = withTeams(net, "Nota Scam")
  local other = withTeams(net, "Other One")
  net:Advance(100)
  local id = officer.model:Create("Scams", { "Nota Scam" })
  net:Advance(120)
  T.eq(officer.model:Detail(id).origins, {}, "a character without a record brings no account id")
  T.eq(writeCharacter(member), true, "the member writes its character record")
  net:Advance(200)
  local origin = member.sync:GetOrigin()
  for _, replica in ipairs({ officer, member, other }) do
    T.eq(replica.model:Detail(id).origins, { origin }, replica.name .. " has the account id that the clerk added")
  end
  T.eq(writeCharacter(member, { "ZZZZ" }), true, "the record lists a second install")
  net:Advance(800)
  for _, replica in ipairs({ officer, member, other }) do
    T.eq(replica.model:Detail(id).origins, sorted({ origin, "ZZZZ" }), replica.name .. " has both account ids")
  end
end

--------------------------------------------------------------------------------
-- TeamChat: the alias in front of a chat line
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local replica = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false })
  local ns = replica.ns
  local teamChat = ns.teamChat
  local decorated = "|Haddon:OOOOguildcompanion:team|h|cffc0c0c0nota|r|h: hello"
  T.eq(teamChat.decorate("hello", "nota"), decorated, "decorate puts a link with the alias in front of the text")

  local aliases = { ["Nota Scam"] = "nota", ["Same Name"] = "same NAME", ["Bad Alias"] = "a|b" }
  teamChat.aliasOf = function(name)
    return aliases[name]
  end
  T.eq(teamChat:Filter("hello", "Nota Scam"), decorated, "Filter decorates a line of a character with a team")
  T.eq(teamChat:Filter("hello", "Nota Scam-Realm"), decorated, "also with a realm suffix")
  T.eq(teamChat:Filter("hello", "Nobody Here"), nil, "a sender without a team stays as it is")
  T.eq(teamChat:Filter("hello", "Same Name"), nil, "an alias equal to the name, ignoring the case, is not shown")
  T.eq(teamChat:Filter("hello", "Bad Alias"), nil, "an alias with a bad character is not shown")
  T.eq(teamChat:Filter(nil, "Nota Scam"), nil, "a line without text stays")
  T.eq(teamChat:Filter(42, "Nota Scam"), nil, "a text that is no string too")
  T.eq(teamChat:Filter("hello", nil), nil, "a line without a sender too")
  T.eq(teamChat:Filter("hello", 42), nil, "and one whose sender is no string")
  local secret = setmetatable({}, { __tostring = function() return "secret" end })
  local savedSecret = _G.issecretvalue
  _G.issecretvalue = function(value)
    return value == secret
  end
  T.eq(teamChat:Filter(secret, "Nota Scam"), nil, "a secret text stays as it came")
  T.eq(teamChat:Filter("hello", secret), nil, "a secret sender too")
  _G.issecretvalue = savedSecret

  -- Without a stub, the alias comes from the model of the game
  teamChat.aliasOf = nil
  ns.teams.current = nil
  T.eq(teamChat:Filter("hello", "Nota Scam"), nil, "without a model nothing is shown")
  local id = replica.model:Create("nota", { "Nota Scam" })
  ns.teams.current = replica.model
  T.eq(teamChat:AliasOf("Nota Scam"), "nota", "AliasOf asks the model")
  T.eq(teamChat:Filter("hello", "Nota Scam"), decorated, "and Filter shows the alias of the model")
  T.eq(replica.model:SetOfficerAlias(id, "Nota Scam"), true, "the alias is set to the name")
  T.eq(teamChat:Filter("hello", "Nota Scam"), nil, "then it is not shown")
  replica.model:SetOfficerAlias(id, "nota")

  -- The filters of the chat frames
  local installed = {}
  _G.ChatFrameUtil = {
    AddMessageEventFilter = function(event, filter)
      installed[event] = filter
    end,
    RemoveMessageEventFilter = function(event, filter)
      if installed[event] == filter then
        installed[event] = nil
      end
    end,
  }
  T.eq(teamChat.filtersInstalled, false, "the filters are off at the start")
  teamChat:SetFiltersInstalled(true)
  T.eq(teamChat.filtersInstalled, true, "SetFiltersInstalled installs them")
  local events = {}
  for event in pairs(installed) do
    events[#events + 1] = event
  end
  T.eq(sorted(events), sorted(teamChat.EVENTS), "one per chat event")
  local filter = installed.CHAT_MSG_GUILD
  ns.db = nil
  T.eq(teamChat:IsEnabled(), false, "without the settings the aliases are off")
  T.eq({ filter(nil, "CHAT_MSG_GUILD", "hello", "Nota Scam", "x", 7) }, { false }, "and the filter changes nothing")
  ns.db = { profile = { general = {} } }
  T.eq(teamChat:IsEnabled(), true, "the aliases are on by default")
  T.eq({ filter(nil, "CHAT_MSG_GUILD", "hello", "Nota Scam", "x", 7) }, { false, decorated, "Nota Scam", "x", 7 },
    "the filter gives the new text with the other arguments")
  T.eq({ filter(nil, "CHAT_MSG_GUILD", "hello", "Nobody Here", "x") }, { false },
    "and nothing for a sender without a team")
  teamChat:SetEnabled(false)
  T.eq(ns.db.profile.general.teamAliases, false, "SetEnabled writes the setting")
  T.eq({ filter(nil, "CHAT_MSG_GUILD", "hello", "Nota Scam", "x") }, { false }, "switched off, nothing changes")
  teamChat:SetEnabled(true)
  T.eq(ns.db.profile.general.teamAliases, true, "and on again")
  teamChat:SetFiltersInstalled(false)
  T.eq({ teamChat.filtersInstalled, next(installed) }, { false, nil }, "the filters are removed")
  _G.ChatFrameUtil = nil

  -- The slash command /oooo alias
  local savedUnitName = _G.UnitName
  _G.UnitName = function()
    return "Officer", "One"
  end
  ---Runs `/oooo alias` with a text and returns the last line that it printed.
  local function alias(text)
    ns.slash:Dispatch("alias" .. text)
    return replica.notices[#replica.notices]
  end
  ns.teams.current = nil
  T.eq(alias(""), "The shared database is not ready.", "without a model the command says so")
  ns.teams.current = replica.model
  T.eq(alias(""), "This character is in no team. An officer makes the teams.", "a character without a team")
  T.eq(alias(" Boss"), "The alias was not changed: an officer has not assigned this character to a team.",
    "cannot ask")
  replica.model:Create("Chiefs", { "Officer One" })
  T.eq(alias(""), "Your team is shown as \"Chiefs\". Change it with /oooo alias <text>.", "the alias is shown")
  T.eq(alias("   Boss  "), "Asked for the alias \"Boss\". It shows once an online officer's addon has taken it.",
    "a request is written")
  T.eq(alias(""), "Your team is shown as \"Chiefs\". You asked for \"Boss\". Change it with /oooo alias <text>.",
    "and shown with the alias")
  T.eq(alias(" a|b"), "The alias was not changed: the alias has a character that is not allowed (|).",
    "a refusal is explained")
  T.eq(alias(" " .. string.rep("x", 25)), "The alias was not changed: the alias is longer than 24 bytes.",
    "also a long alias")
  _G.UnitName = savedUnitName
  ns.teams.current = nil
end

--------------------------------------------------------------------------------
-- TeamRoster: the rows of the roster tab
--------------------------------------------------------------------------------

do
  local net = Fakenet.new({ random = random })
  local officer = withTeams(net, "Officer One", { rankIndex = OFFICER, login = false })
  arriveCharacter(officer, "Alpha One", { "SSSS" }, "MAGE")
  arriveCharacter(officer, "Gamma One", { "SSSS" }, "PRIEST")
  local id = officer.model:Create("Alphas", { "Alpha One" })
  local roster = {
    ["Beta One"] = { online = false, class = "WARRIOR" },
    ["Alpha One"] = { online = false, class = "HUNTER" },
    ["Gamma One"] = { online = true },
    ["Delta One"] = { online = true, class = "ROGUE" },
    ["Epsilon One"] = {},
  }
  local rows = officer.ns.teamRoster.rows({ roster = roster, model = officer.model, sync = officer.sync })
  T.eq(rows, {
    { name = "Delta One", online = true, class = "ROGUE", detected = false, hasAddon = false },
    { name = "Gamma One", online = true, class = "PRIEST", teamId = id, alias = "Alphas", detected = true,
      hasAddon = true },
    { name = "Alpha One", online = false, class = "HUNTER", teamId = id, alias = "Alphas", detected = false,
      hasAddon = true },
    { name = "Beta One", online = false, class = "WARRIOR", detected = false, hasAddon = false },
    { name = "Epsilon One", online = false, detected = false, hasAddon = false },
  }, "rows: online first, then by name; the class of the roster, else of the table character; the team")
  T.eq(officer.ns.teamRoster.rows({ roster = {}, model = officer.model, sync = officer.sync }), {},
    "an empty roster gives no rows")
end

T.finish()
