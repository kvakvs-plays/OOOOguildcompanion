-- Host test of Addon/Src/Sync/VersionId.lua: making, parsing, and validating version ids.
local T = dofile("Tests/harness.lua")

local ns = T.load("Addon/Src/Sync/Base94.lua")
T.load("Addon/Src/Sync/VersionId.lua", ns)
local versionId = ns.versionId
local random = T.newRandom()

local START = 1795000000

-- Form
T.eq(versionId.LENGTH, 11, "an id has 11 characters")
T.eq(versionId.ZERO, "!!!!!!!!!!!", "the zero id is the smallest string of 11 characters")
local sample = versionId.make(START, "aB3$", 4711)
T.eq(#sample, 11, "make gives 11 characters")
T.eq({ versionId.parse(sample) }, { START, "aB3$", 4711 }, "parse returns what make put in")
T.eq(versionId.originOf(sample), "aB3$", "originOf reads characters 6 to 9")
T.eq(versionId.parse("short"), nil, "parse rejects a string that is not an id")

-- newOrigin
for _ = 1, 100 do
  local origin = versionId.newOrigin(random)
  if #origin ~= 4 or not ns.base94.isValid(origin) then
    T.ok(false, "newOrigin gives 4 base-94 characters, got '" .. origin .. "'")
  end
end
T.ok(true, "newOrigin gives 4 base-94 characters")
T.raises(function() versionId.newGenerator("abc", os.time, random) end, "a short origin raises", "origin")
T.raises(function() versionId.newGenerator("ab c", os.time, random) end, "an origin with a space raises", "origin")

-- One generator, a clock that stands still, moves ahead, and moves back: every id is greater than the one before
do
  local now = START
  local nextId = versionId.newGenerator("aB3$", function() return now end, random)
  local previous = versionId.ZERO
  for index = 1, 10000 do
    local step = random(1, 10)
    if step <= 5 then
      now = now + 0 -- stands still
    elseif step <= 8 then
      now = now + random(1, 3)
    else
      now = now - random(1, 5)
    end
    local id = nextId()
    if not versionId.isWellFormed(id) or id <= previous then
      T.ok(false, "id " .. index .. " '" .. id .. "' is greater than '" .. previous .. "'")
    end
    previous = id
  end
  T.ok(true, "10000 ids from one generator increase with a clock that stands still, moves ahead, and moves back")
end

-- More ids in one second than the counter holds
do
  local nextId = versionId.newGenerator("aB3$", function() return START end, random)
  local previous = versionId.ZERO
  for index = 1, 20000 do
    local id = nextId()
    if id <= previous then
      T.ok(false, "id " .. index .. " in one second is greater than the one before")
    end
    previous = id
  end
  local timestamp = versionId.parse(previous)
  T.ok(timestamp > START, "the timestamp moves ahead when the counter is used up")
  T.ok(timestamp <= START + 4, "20000 ids in one second use at most 4 more seconds")
end

-- The counter of a new second is in the lower half
do
  local now = START
  local nextId = versionId.newGenerator("aB3$", function() return now end, random)
  for _ = 1, 200 do
    now = now + 1
    local _, _, counter = versionId.parse(nextId())
    if counter >= 4418 then
      T.ok(false, "the counter of a new second is in the lower half, got " .. counter)
    end
  end
  T.ok(true, "the counter of a new second is in the lower half")
  local _, _, first = versionId.parse(nextId())
  local _, _, second = versionId.parse(nextId())
  T.eq(second, first + 1, "the counter rises by 1 within a second")
end

-- next(maxId) is greater than maxId
do
  local nextId = versionId.newGenerator("AAAA", function() return START end, random)
  local sameSecond = versionId.make(START, "zzzz", 8835)
  local id = nextId(sameSecond)
  T.ok(id > sameSecond, "an id is greater than a maxId of the same second from a greater origin")
  T.eq(versionId.parse(id), START + 1, "the timestamp is the second after maxId")
  local ahead = versionId.make(START + 180, "zzzz", 17)
  id = nextId(ahead)
  T.ok(id > ahead, "an id is greater than a maxId that is 3 minutes ahead")
  T.eq(versionId.parse(id), START + 181, "the timestamp is the second after the maxId that is ahead")
  local following = nextId()
  T.ok(following > id, "the id after that still increases although the clock is behind")
  local older = versionId.make(START - 60, "zzzz", 17)
  local third = nextId(older)
  T.ok(third > following, "an older maxId does not pull the ids back")
  T.ok(nextId("not an id") > third, "a maxId that is not an id is ignored")
end

-- Random maxId values: always greater than maxId and than the previous id
do
  local now = START
  local nextId = versionId.newGenerator("mmmm", function() return now end, random)
  local previous = versionId.ZERO
  for _ = 1, 5000 do
    now = now + random(0, 2)
    local maxId = versionId.make(now + random(-5, 5), versionId.newOrigin(random), random(0, 8835))
    local id = nextId(maxId)
    if id <= maxId or id <= previous then
      T.ok(false, "'" .. id .. "' is greater than maxId '" .. maxId .. "' and the previous '" .. previous .. "'")
    end
    previous = id
  end
  T.ok(true, "5000 ids are greater than a random maxId and than the id before")
end

-- Two origins in the same second: the order of the ids is the order of the origins
do
  local low = versionId.newGenerator("AAAA", function() return START end, random)
  local high = versionId.newGenerator("AAAB", function() return START end, random)
  for _ = 1, 100 do
    if low() >= high() then
      T.ok(false, "an id of origin AAAA sorts before an id of origin AAAB in the same second")
    end
  end
  T.ok(true, "ids of two origins in the same second are ordered by origin")
  T.ok(versionId.make(START, "zzzz", 0) < versionId.make(START + 1, "!!!!", 0), "a later second wins over the origin")
end

-- isValid
local now = START
T.eq(versionId.isValid(versionId.make(now, "aB3$", 0), now), true, "an id of the current second is valid")
T.eq(versionId.isValid(versionId.make(now - 86400 * 400, "aB3$", 0), now), true, "an old id is valid")
T.eq(versionId.isValid(versionId.make(now + 299, "aB3$", 0), now), true, "an id 299 seconds ahead is valid")
T.eq(versionId.isValid(versionId.make(now + 300, "aB3$", 0), now), true, "an id 300 seconds ahead is valid")
T.eq(versionId.isValid(versionId.make(now + 301, "aB3$", 0), now), false, "an id 301 seconds ahead is rejected")
T.eq(versionId.isValid(sample:sub(1, 10), now), false, "length 10 is rejected")
T.eq(versionId.isValid(sample .. "!", now), false, "length 12 is rejected")
T.eq(versionId.isValid(sample:sub(1, 5) .. " " .. sample:sub(7), now), false, "a space is rejected")
T.eq(versionId.isValid(sample:sub(1, 10) .. "\127", now), false, "byte 127 is rejected")
T.eq(versionId.isValid(12345678901, now), false, "a number is rejected")
T.eq(versionId.isValid(nil, now), false, "nil is rejected")
T.eq(versionId.isValid({}, now), false, "a table is rejected")
T.eq(versionId.isValid(versionId.ZERO, now), true, "the zero id is valid")

-- The file takes time, random source, and origin as parameters only
local source = assert(io.open("Addon/Src/Sync/VersionId.lua")):read("a")
for _, name in ipairs({ "GetServerTime", "math%.random", "os%.time", "time%(%)" }) do
  T.ok(not source:gsub("%-%-[^\n]*", ""):find(name), "VersionId.lua does not call " .. name)
end

T.finish()
