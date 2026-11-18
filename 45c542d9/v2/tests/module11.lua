-- module11.lua -- acceptance tests for layer 11 (silent anti-debug deviation).
--
-- Pipeline under test: layers 1-10 build a randomized, block-chained payload;
-- src/antidebug.lua adds load-time probes and, when one fires, rotates every
-- value-only string constant before execution. Nothing is printed, no error is
-- raised and the debug library is never written to: a hooked session runs to
-- completion on wrong data. Field names, pool canaries and pool headers are
-- excluded, and if a corrupted API string still makes the program raise, the
-- entry restores the original constants and reruns clean -- never an empty
-- result.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Consts = require("src.consts")
local Flatten = require("src.flatten")
local Opaque = require("src.opaque")
local Strings = require("src.strings")
local Compiler = require("src.compiler")
local VM = require("tests.vmref")
local VMGen = require("src.vmgen")
local Bytecode = require("src.bytecode")
local Selfmod = require("src.selfmod")
local Antidebug = require("src.antidebug")

local checks = 0
local failures = 0
local notes = {}

local function check(name, ok, detail)
  checks = checks + 1
  if ok then return end
  failures = failures + 1
  local line = "FAIL " .. name
  if detail ~= nil then line = line .. ": " .. tostring(detail) end
  notes[#notes + 1] = line
end

local function parse(src)
  local ast, errors = Parser.parse(src, "case.lua")
  return Ast.normalize(ast), errors
end

local function build(src, opts)
  opts = opts or {}
  local ast, errors = parse(src)
  if not ast then return nil, errors end
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  if not opts.raw then
    Consts.run(ast, { seed = 0x0C057A })
    Flatten.run(ast, { seed = 3 })
    Opaque.run(ast, { seed = 5, prob = 0.6 })
    Strings.run(ast, { seed = 0x5CE41D })
  end
  return Compiler.compile(ast, {}), errors
end

-- ---------------------------------------------------------------- execution
local loadChunk = loadstring or load

local function newEnv(out)
  local env = setmetatable({}, { __index = _G })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  return env
end

local function loadWith(src, env)
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(src, "@vm")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@vm", "t", env)
  end
  return chunk, err
end

local function runIn(src, env)
  local out = {}
  local e = env or {}
  if not getmetatable(e) then setmetatable(e, { __index = _G }) end
  e.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local chunk, err = loadWith(src, e)
  if not chunk then return nil, "load: " .. tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function execute(src)
  local out = {}
  local env = newEnv(out)
  local chunk, err = loadWith(src, env)
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------ fixture
local SAMPLE = [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local tags = {"alpha", "beta", "gamma"}
local c = counter(10)
print(fact(5), tags[1], tags[2], tags[3], c(1), c(2), 6 * 7, "tail")
]]

local sampleCompiled = build(SAMPLE)

local function pipeline(src, seed, opts)
  opts = opts or {}
  local compiled
  if src == SAMPLE then
    compiled = sampleCompiled
  else
    compiled = build(src)
  end
  local plan = VMGen.randomize(compiled, { seed = seed, decoys = 160 })
  if opts.selfmod ~= false then Selfmod.apply(plan, { seed = seed }) end
  local payload = Bytecode.pack(plan, { seed = seed })
  local source, stats = VMGen.emit(plan, {
    payload = payload, antidebug = opts.antidebug,
  })
  return source, stats, plan, payload
end

-- Probe stubs. A hooked session is simulated with a `debug` table whose
-- gethook returns a function; everything else stays real.
local function cleanDebug()
  return { gethook = function() return nil end, getinfo = debug.getinfo }
end

local function hookedDebug()
  return { gethook = function() return function() end end,
    getinfo = debug.getinfo }
end

local function fakeString()
  return setmetatable({ dump = function() return "" end }, { __index = string })
end

local function hookedEnv(extra)
  local env = { debug = hookedDebug() }
  if extra then for k, v in pairs(extra) do env[k] = v end end
  return env
end

-- ---------------------------------------------------------------------------
-- 1. Plan: deterministic, always carries the hook probe, build diversity
-- ---------------------------------------------------------------------------
local cfg = Antidebug.plan({ seed = 0x11A })
check("plan: threshold is two", cfg.threshold == 2, cfg.threshold)
check("plan: hook probe always compiled", cfg.mask % 2 == 1, cfg.mask)
check("plan: hook weight is two", cfg.weights.hook == 2, cfg.weights.hook)
check("plan: at least two probes", #cfg.probes >= 2, #cfg.probes)
check("plan: only known probe names", (function()
  for i = 1, #cfg.probes do
    local known = false
    for j = 1, #Antidebug.PROBES do
      if Antidebug.PROBES[j] == cfg.probes[i] then known = true end
    end
    if not known then return false end
  end
  return true
end)())

local again = Antidebug.plan({ seed = 0x11A })
check("plan: same seed is deterministic", (function()
  if again.mask ~= cfg.mask then return false end
  if #again.probes ~= #cfg.probes then return false end
  for i = 1, #cfg.probes do
    if again.probes[i] ~= cfg.probes[i] then return false end
  end
  for _, k in ipairs({ "hook", "what", "func", "dump" }) do
    if again.weights[k] ~= cfg.weights[k] then return false end
  end
  return true
end)())

local signatures, distinct = {}, 0
for i = 1, 20 do
  local c = Antidebug.plan({ seed = 0x11B00 + i * 977 })
  local sig = tostring(c.mask) .. ":" .. c.weights.what .. c.weights.func ..
    c.weights.dump .. ":" .. table.concat(c.probes, ",")
  if not signatures[sig] then distinct = distinct + 1 end
  signatures[sig] = true
end
check("plan: seeds give varied probe sets", distinct >= 8, distinct)
notes[#notes + 1] = string.format("MODULE11_PLAN distinct=%d/20", distinct)

-- ---------------------------------------------------------------------------
-- 1b. Late-hook latch: armed by the prologue, advanced by the integrity tick
-- ---------------------------------------------------------------------------
do
  local names = { ADT = "ADT", ADX = "ADX", ADH = "ADH", ADG = "ADG",
    ADR = "ADR", AGH = "AGH", AGI = "AGI", AGW = "AGW", AGL = "AGL",
    AGF = "AGF", AGD = "AGD", ADL = "ADL", ALS = "ALS", ADU = "ADU",
    AGR = "AGR", ADLD = "ADLD", ADB = "ADB", ADS = "ADS", ADE = "ADE",
    E = "E", DM = "DM", G3 = "G3", G4 = "G4" }
  local pro = table.concat(Antidebug.prologue(names, cfg), "\n")
  check("late: prologue arms the latch", pro:find("local ADH=0", 1, true) ~= nil)
  local probe = Antidebug.lateCheck(names)
  check("late: guard requires a clean, non-executor session",
    probe:find("if ADT==0 and ADE==0", 1, true) ~= nil, probe)
  check("late: only a live hook advances the latch",
    probe:find("then ADH=ADH+1 else ADH=0 end end", 1, true) ~= nil, probe)
  check("late: gethook call is type-checked",
    probe:find('G4(ADB[AGH])=="function"', 1, true) ~= nil, probe)
  check("late: missing names disable the probe", Antidebug.lateCheck({}) == "")

  -- Runtime copy with short names so the snippet's ADB[AGH] reads a real table.
  local probeRun = Antidebug.lateCheck({ ADT = "ADT", ADE = "ADE",
    ADH = "ADH", ADB = "D", AGH = "AGH", G4 = "G4" })
  local function latch(debugSrc, adt, ade, rounds)
    local body = {}
    for i = 1, rounds do body[i] = probeRun end
    local src = "local G4=type local AGH=\"gh\" local ADT=" .. adt ..
      " local ADE=" .. ade .. " local D=" .. debugSrc .. " local ADH=0 " ..
      table.concat(body, " ") .. " return ADH"
    local chunk, err = loadWith(src, setmetatable({}, { __index = _G }))
    if not chunk then return nil, err end
    local ok, v = pcall(chunk)
    return ok and v or nil, ok and nil or v
  end
  local live = "{gh=function() return function() end end}"
  local quiet = "{gh=function() return nil end}"
  check("late: two live-hook ticks reach the failure threshold",
    latch(live, 0, 0, 2) == 2)
  check("late: one tick stays below the threshold", latch(live, 0, 0, 1) == 1)
  check("late: a clean host resets the latch", latch(quiet, 0, 0, 2) == 0)
  check("late: a load-time trip never latches", latch(live, 1, 0, 2) == 0)
  check("late: an executor host never latches", latch(live, 0, 1, 2) == 0)

  -- The rotating library re-checks re-test one family per tick. A clean host
  -- must stay at zero across a full rotation; a wrapper installed after load
  -- latches on the first tick that reaches its family.
  local lateNames = { ADT = "ADT", ADE = "ADE", ADH = "ADH", ADZ = "ADZ",
    ADB = "ADB", AGH = "AGH", ADS = "ADS", DM = "DM", E = "E",
    G3 = "G3", G4 = "G4" }
  local rotate = Antidebug.lateCheck(lateNames)
  check("late: rotating block is emitted with the library snapshot",
    rotate:find("ADZ=ADZ%4+1", 1, true) ~= nil, #rotate)
  local function rotateTick(env, rounds)
    local body = {}
    for i = 1, rounds do
      body[i] = rotate .. " if ADH>MX then MX=ADH end"
    end
    local src = "local G3=pcall local G4=type local DM=string.char " ..
      "local AGH=\"gh\" local ADB={gh=function() return nil end} " ..
      "local ADT=0 local ADE=0 local ADH=0 local ADZ=0 local MX=0 " ..
      "local E=... " .. table.concat(body, " ") .. " return MX"
    local chunk, err = loadWith(src, setmetatable({}, { __index = _G }))
    if not chunk then return nil, err end
    local ok, v = pcall(chunk, env)
    return ok and v or nil, ok and nil or v
  end
  local cleanEnv = { string = string, select = select, table = table }
  check("late: rotating clean checks stay at zero",
    rotateTick(cleanEnv, 4) == 0)
  check("late: rotating clean checks stay at zero across cycles",
    rotateTick(cleanEnv, 9) == 0)
  local badFormat = setmetatable({ format = function() return "x" end },
    { __index = string })
  local latched = rotateTick({ string = badFormat, select = select,
    table = table }, 4)
  check("late: a post-load format wrapper latches", latched ~= nil and
    latched >= 2, latched)
end

-- ---------------------------------------------------------------------------
-- 2. Reference probe: clean env never fires, instrumentation always does
-- ---------------------------------------------------------------------------
local cleanOk, cleanWhy = true, nil
for i = 1, 20 do
  local c = Antidebug.plan({ seed = 0x11C00 + i * 613 })
  local r = Antidebug.probe(c, { env = _G })
  if r.trip ~= 0 or r.score ~= 0 then
    cleanOk, cleanWhy = false, "seed " .. i .. " score " .. r.score
  end
end
check("probe: clean host never trips", cleanOk, cleanWhy)

local hookOk, hookWhy = true, nil
for i = 1, 20 do
  local c = Antidebug.plan({ seed = 0x11D00 + i * 613 })
  local r = Antidebug.probe(c, { env = { debug = hookedDebug(),
    string = string } })
  if r.trip ~= 1 or not r.hits.hook then
    hookOk, hookWhy = false, "seed " .. i .. " score " .. r.score
  end
end
check("probe: an active hook always trips", hookOk, hookWhy)

-- Executors install their own debug hooks, so an ambiguous probe must not
-- deviate a real executor session: the protected program has to run intact.
local exOk, exWhy = true, nil
for i = 1, 20 do
  local c = Antidebug.plan({ seed = 0x11D80 + i * 613 })
  local r = Antidebug.probe(c, { env = { debug = hookedDebug(),
    string = string, getgenv = function() return {} end } })
  if r.trip ~= 0 then
    exOk, exWhy = false, "seed " .. i .. " score " .. r.score
  end
end
check("probe: executor host never trips on its own hook", exOk, exWhy)

-- The same executor host still trips when the core library was tampered with.
local libOk, libWhy = true, nil
for i = 1, 20 do
  local c = Antidebug.plan({ seed = 0x11E80 + i * 613 })
  local compiled = false
  for j = 1, #c.probes do
    if c.probes[j] == "byte" then compiled = true end
  end
  if compiled then
    local bad = setmetatable({ byte = function() return 0 end },
      { __index = string })
    local r = Antidebug.probe(c, { env = { debug = hookedDebug(),
      string = bad, getgenv = function() return {} end } })
    if r.trip ~= 1 or not r.hits.byte then
      libOk, libWhy = false, "seed " .. i .. " score " .. r.score
    end
  end
end
check("probe: executor host still trips on library tampering", libOk, libWhy)

-- Mirrors the emitted arithmetic: score is the sum of the enabled weights.
local function expectedTrip(c, hits)
  local score = 0
  for i = 1, #c.probes do
    local p = c.probes[i]
    if hits[p] then score = score + c.weights[p] end
  end
  return score >= c.threshold and 1 or 0, score
end

local srcBit = 0
for j = 1, #Antidebug.PROBES do
  if Antidebug.PROBES[j] == "src" then srcBit = 2 ^ (j - 1) end
end
local lineBit = 0
for j = 1, #Antidebug.PROBES do
  if Antidebug.PROBES[j] == "line" then lineBit = 2 ^ (j - 1) end
end
local mirrorOk, mirrorWhy = true, nil
for i = 1, 12 do
  local c = Antidebug.plan({ seed = 0x11E00 + i * 389 })
  local whatFake = { gethook = function() return nil end,
    getinfo = function() return { what = "C", linedefined = -1,
      func = function() end } end }
  local r = Antidebug.probe(c, { env = { debug = whatFake, string = string } })
  local hits = {}
  if c.mask % 4 >= 2 then hits.what = true end
  if c.mask % 8 >= 4 then hits.func = true end
  if srcBit > 0 and c.mask % (srcBit * 2) >= srcBit then hits.src = true end
  -- The fake getinfo never reports a currentline, so the line probe fires
  -- whenever it is compiled.
  if lineBit > 0 and c.mask % (lineBit * 2) >= lineBit then hits.line = true end
  local want, score = expectedTrip(c, hits)
  if r.trip ~= want or r.score ~= score then
    mirrorOk = false
    mirrorWhy = "seed " .. i .. " trip " .. r.trip .. "/" .. want ..
      " score " .. r.score .. "/" .. score
  end
end
check("probe: disabled probes contribute nothing", mirrorOk, mirrorWhy)

local dumpCfg = Antidebug.plan({ seed = 0x11F01 })
local dumpOnly, dumpScore = expectedTrip(dumpCfg, { dump = true })
local dumpProbe = Antidebug.probe(dumpCfg, { env = { string = fakeString() } })
check("probe: unstable dump mirrors the weight table",
  dumpProbe.trip == dumpOnly and dumpProbe.score == dumpScore,
  dumpProbe.trip .. "/" .. dumpOnly)

local noDebug = Antidebug.probe(cfg, { env = { debug = false, string = string } })
check("probe: missing debug library is not a hit", noDebug.trip == 0 and
  noDebug.score == 0, noDebug.score)

-- ---------------------------------------------------------------------------
-- 3. Clean runtime equivalence over the semantic corpus
-- ---------------------------------------------------------------------------
local corpus = {
  { "arith", [[
local function f(a, b) return a * b + a - b / 2 end
print(f(3, 4), f(-2, 5), 2 ^ 10, 7 % 3, -7 % 3, 1 / 4)
print(10, 1, 10 + 1, 10 / 2, 10.0 / 2, 3 * 4, 2 ^ 8)
]] },
  { "strings", [[
local s = "ab" .. 1 .. "-" .. 2.5
print(s, #s, ("abc"):upper(), string.rep("xy", 3))
print("tab\tline\nend", "A\66", ("a,b,c"):find(",", 1, true))
]] },
  { "tables", [[
local t = {10, 20, 30, x = "hi"}
t[4] = 40
t.y = "bye"
local u = {0, t[1], t.x}
print(#t, t[1] + t[2] + t[3] + t[4], t.x, t.y, #u, u[2])
]] },
  { "recursion", [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fact(7), fib(10))
]] },
  { "closures", [[
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local c = counter(10)
print(c(1), c(2), c(3))
]] },
  { "loop capture", [[
local t = {}
for i = 1, 3 do t[i] = function() return i * 10 end end
print(t[1](), t[2](), t[3]())
]] },
  { "nested upvalues", [[
local function outer(a)
  local b = a * 2
  local function middle(c)
    local function inner(d) return a + b + c + d end
    return inner(4)
  end
  return middle(3)
end
print(outer(1))
]] },
  { "varargs", [[
local function f(...) local n = select("#", ...) return n, ... end
print(f(1, nil, 3))
local function sum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s
end
print(sum(1, 2, 3, 4))
]] },
  { "method multi assign", [[
local acc = {v = 0}
function acc:add(d) self.v = self.v + d return self end
acc:add(5):add(7)
local function two() return 8, 9 end
local a, b, c = two()
print(acc.v, a, b, c)
]] },
  { "control", [[
local s = 0
for i = 10, 1, -3 do
  s = s + i
  if i == 4 then break end
end
local j = 0
repeat j = j + 2 until j >= 7
print(s, j, 1 < 2, "a" < "b", nil == false, false and 1 or 2)
]] },
  { "generic for", [[
local t = {4, 5, 6}
local s = 0
for i, v in ipairs(t) do s = s + i * v end
local h = {10, 20, 30}
local hsum = 0
for _, v in ipairs(h) do hsum = hsum + v end
print(s, hsum)
]] },
  { "number subtypes", [[
local k = 2.5
print(k * 2, k + 1, -0.0, 1 / 3, 1e300, math.huge, -math.huge)
print(9007199254740991, 123456789012345, 0.1 + 0.2, 1.0, 1)
]] },
  { "constant operands", [[
local x = 10
print(x + 0.5, x - 0.25, x * 1.5, x / 0.5, x % 2.5, 4 ^ 0.5,
      x + 3, x - 3, x * 3, x / 4, x % 3)
]] },
  { "do scope shadowing", [[
local x = 1
do local x = 2 print(x) end
print(x)
local function bump() x = x + 1 return x end
print(bump(), bump(), x)
]] },
}

local covered, corpusFail = 0, nil
for ci = 1, #corpus do
  local name, src = corpus[ci][1], corpus[ci][2]
  local seed = 0xAB01 + ci * 131
  local source, stats = pipeline(src, seed, { antidebug = true })
  local want = execute(src)
  local got, genErr = runIn(source)
  local ok = want ~= nil and got == want and stats.antidebug == true
  if ok then
    covered = covered + 1
  elseif not corpusFail then
    corpusFail = name .. ": " .. tostring(genErr or
      ("got=" .. tostring(got) .. " want=" .. tostring(want)))
  end
end
check("corpus: anti-debug runtime matches source", corpusFail == nil,
  corpusFail)
notes[#notes + 1] = string.format("MODULE11_CORPUS %d/%d", covered, #corpus)

-- Regression guard for silent empty output: in a tripped session the program
-- must still run and print something. Only values may change; names, headers
-- and entry boundaries must survive. (Line counts can legitimately differ:
-- a corrupted string may carry a different number of newlines.)
local tripFail = nil
for ci = 1, #corpus do
  local name, s = corpus[ci][1], corpus[ci][2]
  local code = pipeline(s, 0xAB01 + ci * 131, { antidebug = true })
  local got, err = runIn(code, hookedEnv())
  if not got or #got == 0 then
    tripFail = name .. ": got=" .. tostring(got) .. " err=" .. tostring(err)
    break
  end
end
check("trip: hooked run never collapses to empty output", tripFail == nil,
  tripFail)

-- The emitted runtime must also agree with the reference VM.
local refCompiled = build(corpus[7][2])
local refPlan = VMGen.randomize(refCompiled, { seed = 0xAC01, decoys = 160 })
Selfmod.apply(refPlan, { seed = 0xAC01 })
local refPayload = Bytecode.pack(refPlan, { seed = 0xAC01 })
local refSource = VMGen.emit(refPlan, { payload = refPayload,
  antidebug = Antidebug.plan({ seed = 0xAC01 }) })
local refOut = {}
local refOk, refErr = pcall(VM.run, refCompiled, newEnv(refOut))
check("reference VM: runs", refOk, refErr)
check("reference VM: agrees with anti-debug runtime",
  table.concat(refOut, "\n") == runIn(refSource))

-- ---------------------------------------------------------------------------
-- 4. Tripped runtime: wrong output, no error, no hang, no plaintext
-- ---------------------------------------------------------------------------
local cleanSample = runIn(pipeline(SAMPLE, 0xAD01, { antidebug = true }))
local sampleSrc = pipeline(SAMPLE, 0xAD01, { antidebug = true })
local deviated, devErr = runIn(sampleSrc, hookedEnv())
check("trip: hooked run raises nothing", devErr == nil, devErr)
check("trip: hooked run produces output", deviated ~= nil and deviated ~= "",
  tostring(deviated))
check("trip: hooked output differs from clean", deviated ~= cleanSample,
  tostring(deviated))
check("trip: clean output is intact", cleanSample == execute(SAMPLE),
  tostring(cleanSample))
check("trip: numbers stay correct",
  deviated ~= nil and string.find(deviated, "120") ~= nil, tostring(deviated))

-- A serialized M6 pool must be deviated by rotating ciphertext blobs only. The
-- entry headers carry the key/plaintext/blob lengths the decoder trusts; a
-- rotated header made the loader raise, and the swallow-all pcall turned that
-- into a completely empty result. Same-length garbage in, same-length garbage
-- out.
local poolPlan = VMGen.randomize(sampleCompiled, { seed = 0xAD03, decoys = 160 })
local poolFound, poolBad = false, nil
for pi = 1, #(poolPlan.poolRanges or {}) do
  local list = poolPlan.poolRanges[pi]
  for i = 1, #(list or {}) do
    local e = list[i]
    local s = poolPlan.protos[pi].k[e.index]
    if type(s) ~= "string" then
      poolBad = "proto " .. pi .. " idx " .. e.index
    else
      if #e.ranges % 2 ~= 0 then poolBad = "odd range list" end
      for x = 1, #e.ranges, 2 do
        if e.ranges[x] < 1 or e.ranges[x + 1] > #s or
           e.ranges[x] > e.ranges[x + 1] then
          poolBad = "range outside the pool"
        end
      end
      for j = 1, #poolPlan.safeStrings[pi] do
        if poolPlan.safeStrings[pi][j] == e.index then
          poolBad = "pool also whole-rotated"
        end
      end
      poolFound = true
    end
  end
end
check("deviation: pool blobs are range-rotated", poolFound and poolBad == nil,
  poolBad)

local mixSrc = [[
local t = {"alpha", "beta", "gamma", "delta"}
print(#table.concat(t), t[1], t[2], t[3], t[4])
]]
local mixSource = pipeline(mixSrc, 0xAD02, { antidebug = true })
local mixClean = runIn(mixSource)
local mixDev, mixErr = runIn(mixSource, hookedEnv())
-- The deviated pool may decode data to text of a different length (the
-- huffman decoder can stop early on a corrupted bitstream), and a program
-- that prints a decoded string's length legitimately computes a new number.
-- What must hold is that the chunk still runs and produces output rather
-- than dying inside the swallow-all pcall.
check("trip: deviated pool still runs and prints",
  mixErr == nil and type(mixDev) == "string" and #mixDev > 0,
  tostring(mixDev) .. " / " .. tostring(mixErr))
check("trip: deviated pool text still changes",
  mixErr == nil and mixDev ~= mixClean, tostring(mixDev))

-- A deviated API string can make a real program raise (here `select("#", ...)`
-- receives a corrupted sentinel). The entry retries on the restored constants
-- instead of swallowing the error into an empty result -- the exact symptom a
-- hooked executor session showed.
local strictSrc = [[
local function n(...) return select("#", ...) end
print(n(1, nil, 3), ("%d"):format(7))
]]
local strictSource = pipeline(strictSrc, 0xAD04, { antidebug = true })
local strictWant = execute(strictSrc)
local strictGot, strictErr = runIn(strictSource, hookedEnv())
check("trip: structural failure falls back to a clean run",
  strictErr == nil and strictGot == strictWant,
  tostring(strictGot) .. " / " .. tostring(strictErr))

-- Without the debug library (Luau-like sandbox) nothing may deviate.
local noDbgEnv = { debug = false }
local noDbgOut = runIn(sampleSrc, noDbgEnv)
check("trip: missing debug library leaves output intact",
  noDbgOut == cleanSample, tostring(noDbgOut))

-- A single weak probe must not trip: enable only the dump probe (weight 1)
-- and make it fire through a stubbed string.dump.
local dumpCfg2 = nil
for i = 1, 200 do
  local c = Antidebug.plan({ seed = 0xAD10 + i })
  if c.mask % 16 >= 8 and c.weights.dump == 1 then
    dumpCfg2 = c
    break
  end
end
if dumpCfg2 then
  local source = pipeline(SAMPLE, 0xAD10, { antidebug = dumpCfg2 })
  local out = runIn(source, { string = fakeString() })
  check("trip: one weak probe is not enough", out == execute(SAMPLE),
    tostring(out))
else
  notes[#notes + 1] = "MODULE11_NOTE no weak-dump plan found"
end

-- A real executor session (own hook + getgenv) must run fully intact: the
-- anti-debug layer may not silently neutralize the owner's own program.
local exSource = pipeline(SAMPLE, 0xAF10, { antidebug = true })
local exOut, exErr = runIn(exSource, hookedEnv({
  getgenv = function() return {} end,
}))
check("trip: executor host runs intact",
  exErr == nil and exOut == execute(SAMPLE),
  tostring(exOut) .. " / " .. tostring(exErr))

-- Every corpus program survives a hooked session.
local survived, surviveFail = 0, nil
for ci = 1, #corpus do
  local name, src = corpus[ci][1], corpus[ci][2]
  local source = pipeline(src, 0xAE01 + ci * 137, { antidebug = true })
  local out, err = runIn(source, hookedEnv())
  if out ~= nil and err == nil then
    survived = survived + 1
  elseif not surviveFail then
    surviveFail = name .. ": " .. tostring(err)
  end
end
check("trip: every corpus program terminates without error",
  surviveFail == nil, surviveFail)
notes[#notes + 1] = string.format("MODULE11_SURVIVE %d/%d", survived, #corpus)

-- Numeric-only programs have no value-only string constants; they are left
-- alone by design, which is the safe end of the tradeoff.
local numericSrc = [[
local s = 0
for i = 1, 10 do s = s + i * i end
print(s, 3.5 * 2, 9007199254740991)
]]
local numericClean = pipeline(numericSrc, 0xAF01, { antidebug = true })
local numCleanOut = runIn(numericClean)
local numHookOut = runIn(numericClean, hookedEnv())
check("trip: numeric-only program is unaffected", numHookOut == numCleanOut,
  tostring(numHookOut))
check("trip: numeric-only program still runs hooked", numHookOut ==
  execute(numericSrc), tostring(numHookOut) .. " | " .. tostring(execute(numericSrc)))

-- Negative zero must survive the whole pipeline. It is checked on its own:
-- 5.1's parser reuses an existing +0 constant for a later -0.0 literal, so a
-- chunk that also writes `0` loses the sign before any obfuscation.
local negZeroSrc = "print(-0.0, 1 / -0.0 < 0)"
local negZeroPacked = pipeline(negZeroSrc, 0xAF02, { antidebug = true })
check("trip: negative zero survives the pipeline",
  runIn(negZeroPacked) == execute(negZeroSrc), tostring(runIn(negZeroPacked)))

-- ---------------------------------------------------------------------------
-- 5. Silence: no error paths, no os.exit, no debug writes
-- ---------------------------------------------------------------------------
local srcTxt = pipeline(SAMPLE, 0xB101, { antidebug = true })
check("silence: no os.exit in emitted code",
  string.find(srcTxt, "os.exit", 1, true) == nil)
check("silence: no debugger word", string.find(srcTxt, "debugger", 1, true) ==
  nil)
check("silence: probes never install hooks",
  string.find(srcTxt, "sethook", 1, true) == nil)
check("silence: no plain instruction list", string.find(srcTxt, "c={{", 1,
  true) == nil)

local function keysOf(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = tostring(k) end
  table.sort(list)
  return table.concat(list, ",")
end
local before = keysOf(_G)
runIn(srcTxt, hookedEnv())
runIn(srcTxt)
check("silence: host globals untouched", keysOf(_G) == before)

-- A real hook on the host: trip, deviate, swallow, and leave the hook alone.
local hookCalls = 0
local hookFn = function() hookCalls = hookCalls + 1 end
debug.sethook(hookFn, "", 1)
local realHookOut = runIn(srcTxt)
local stillHook = debug.gethook()
debug.sethook()
check("real hook: chunk terminates without error", realHookOut ~= nil)
check("real hook: output deviates", realHookOut ~= cleanSample,
  tostring(realHookOut))
check("real hook: hook still installed afterwards", stillHook == hookFn)
check("real hook: hook actually fired", hookCalls > 0, hookCalls)

-- ---------------------------------------------------------------------------
-- 6. Integration with layers 9 and 10, non-packed path, stats
-- ---------------------------------------------------------------------------
local sourceSelf, statsSelf = pipeline(SAMPLE, 0xB201, { antidebug = true })
check("integration: self-mod layer active", statsSelf.selfmod == true and
  statsSelf.selfmodBlocks > 0, statsSelf.selfmodBlocks)
check("integration: anti-debug active", statsSelf.antidebug == true)
check("integration: clean output", runIn(sourceSelf) == execute(SAMPLE))
check("integration: hooked output deviates",
  runIn(sourceSelf, hookedEnv()) ~= execute(SAMPLE))

local nonPacked = (function()
  local plan = VMGen.randomize(sampleCompiled, { seed = 0xB301, decoys = 160 })
  return VMGen.emit(plan, { antidebug = Antidebug.plan({ seed = 0xB301 }) })
end)()
check("integration: non-packed path clean", runIn(nonPacked) ==
  execute(SAMPLE))
check("integration: non-packed path deviates",
  runIn(nonPacked, hookedEnv()) ~= execute(SAMPLE))

local plan2 = VMGen.randomize(sampleCompiled, { seed = 0xB401, decoys = 160 })
local autoCfg = VMGen.emit(plan2, { antidebug = true })
local explicitCfg = VMGen.emit(plan2, { antidebug =
  Antidebug.plan({ seed = 0xB401 }) })
check("stats: antidebug=true derives the plan seed", autoCfg == explicitCfg)

local _, statsOn = pipeline(SAMPLE, 0xB501, { antidebug = true })
check("stats: probe count", statsOn.antidebugProbes ==
  #Antidebug.plan({ seed = 0xB501 }).probes, statsOn.antidebugProbes)
check("stats: mask reported", statsOn.antidebugMask % 2 == 1,
  statsOn.antidebugMask)
check("stats: threshold reported", statsOn.antidebugThreshold == 2,
  statsOn.antidebugThreshold)
local _, statsOff = pipeline(SAMPLE, 0xB501)
check("stats: off by default", statsOff.antidebug == false and
  statsOff.antidebugProbes == 0)

-- Grow one prototype past the full-residency cap (1024 blocks x 8) so replay
-- still evicts.
local padPlan = VMGen.randomize(sampleCompiled, { seed = 0xB201, decoys = 160 })
for i = 1, 8500 do
  local c = padPlan.protos[1].c
  c[#c + 1] = { 1, 0, 0, 0, 0 }
end
Selfmod.apply(padPlan, { seed = 0xB201 })
local replay = Selfmod.replay(padPlan, { seed = 0xB201 })
check("integration: self-mod replay still healthy", replay.error == nil and
  replay.mutations > 0, replay.error)

-- ---------------------------------------------------------------------------
-- 7. Polymorphism and determinism with anti-debug enabled
-- ---------------------------------------------------------------------------
local sourceSet, distinctSources = {}, 0
for i = 1, 10 do
  local src = pipeline(SAMPLE, 0xB601 + i * 1013, { antidebug = true })
  if not sourceSet[src] then distinctSources = distinctSources + 1 end
  sourceSet[src] = true
end
check("polymorphism: ten distinct sources", distinctSources == 10,
  distinctSources)
notes[#notes + 1] = string.format("MODULE11_POLY %d/10", distinctSources)

local sameA = pipeline(SAMPLE, 0xB701, { antidebug = true })
local sameB = pipeline(SAMPLE, 0xB701, { antidebug = true })
check("polymorphism: same seed is deterministic", sameA == sameB)

-- ---------------------------------------------------------------------------
-- 8. Scale and load cost
-- ---------------------------------------------------------------------------
local lines = { "local s = 0" }
for i = 1, 298 do
  lines[#lines + 1] = string.format("s = s + %d", (i * 37) % 23 + 1)
end
lines[#lines + 1] = 'print(s, "done")'
local scaleSrc = table.concat(lines, "\n")

local t0 = os.clock()
local scaleCompiled = build(scaleSrc)
local compileMs = (os.clock() - t0) * 1000

t0 = os.clock()
local scalePlan = VMGen.randomize(scaleCompiled,
  { seed = 0xB801, decoys = 160 })
Selfmod.apply(scalePlan, { seed = 0xB801 })
local scalePayload = Bytecode.pack(scalePlan, { seed = 0xB801 })
local scaleSource = VMGen.emit(scalePlan,
  { payload = scalePayload, antidebug = true })
local buildMs = (os.clock() - t0) * 1000

local scaleWant = execute(scaleSrc)
local scaleGot = runIn(scaleSource)
check("scale: clean output matches source", scaleWant ~= nil and
  scaleGot == scaleWant, tostring(scaleGot))
check("scale: build stays under the 10 s budget",
  compileMs + buildMs < 10000, string.format("%.1f ms", compileMs + buildMs))

local hookedScale = runIn(scaleSource, hookedEnv())
check("scale: hooked run terminates", hookedScale ~= nil)
check("scale: hooked run deviates", hookedScale ~= scaleWant)

-- Optional-API compatibility. A denied or proxied optional namespace means
-- "probe unavailable", never a false deviation and never a load-time raise:
-- healthy executors ship proxies over debug, restrict single debug entry
-- points and expose `syn` as a table.
do
  local denied = function() error("optional API denied", 2) end
  local proxy = setmetatable({}, { __index = function() error("denied", 2) end })
  local deniedDebug = { gethook = denied, getinfo = denied,
    getupvalue = denied, getregistry = denied, sethook = denied,
    getlocal = denied }
  local tablePlaceholder = {}
  for k, v in pairs(table) do tablePlaceholder[k] = v end
  tablePlaceholder.unpack = "restricted"
  local compat = {
    { "debug-proxy", { debug = proxy } },
    { "debug-denied", { debug = deniedDebug } },
    { "debug-table-syn", { debug = hookedDebug(), syn = {} } },
    { "debug-proxy-syn", { debug = proxy, syn = {} } },
    { "gc-denied", { collectgarbage = denied } },
    -- Real hosts keep the 5.1 global even when table.unpack is a placeholder.
    { "unpack-placeholder", { table = tablePlaceholder,
      unpack = table.unpack or unpack } },
    { "mixed-denials", { debug = deniedDebug, collectgarbage = denied,
      table = tablePlaceholder, unpack = table.unpack or unpack } },
  }
  for i = 1, #compat do
    local got = runIn(scaleSource, compat[i][2])
    check("compat: " .. compat[i][1] .. " preserves output",
      got == scaleWant, tostring(got))
  end
end

local function loadTime(code, env)
  local start = os.clock()
  local chunk = loadWith(code, env or setmetatable({}, { __index = _G }))
  local ok = chunk ~= nil
  if ok then pcall(chunk) end
  return (os.clock() - start) * 1000, ok
end
local plainPlan = VMGen.randomize(scaleCompiled,
  { seed = 0xB802, decoys = 160 })
Selfmod.apply(plainPlan, { seed = 0xB802 })
local plainPayload = Bytecode.pack(plainPlan, { seed = 0xB802 })
local plainSource = VMGen.emit(plainPlan, { payload = plainPayload })
local baseMs = loadTime(plainSource)
local adMs = loadTime(scaleSource)
check("scale: anti-debug load overhead is small", adMs - baseMs < 100,
  string.format("%.2f - %.2f ms", adMs, baseMs))
notes[#notes + 1] = string.format(
  "MODULE11_SCALE lines=%d instr=%d source=%d compile_ms=%.1f build_ms=%.1f " ..
  "load_base_ms=%.2f load_ad_ms=%.2f hooked_len=%d",
  select(2, string.gsub(scaleSrc, "\n", "")) + 1, #plainPlan.protos,
  #scaleSource, compileMs, buildMs, baseMs, adMs,
  hookedScale and #hookedScale or -1)

do
  local names = { E = "E", DM = "DM", G3 = "G3", G4 = "G4" }
  for _, key in ipairs({ "ADT", "ADX", "ADG", "ADR", "AGH", "AGI", "AGW",
      "AGL", "AGF", "AGD", "ADL", "ALS", "ADU", "AGR", "ADLD", "ADB",
      "ADS", "ADE", "ADY", "ADB0", "ADS0" }) do
    names[key] = key
  end
  local function probeParity(label, config, env, trip, score)
    local refOk, reference = pcall(Antidebug.probe, config, { env = env })
    check("probe parity " .. label .. ": reference", refOk and
      reference.trip == trip and reference.score == score,
      refOk and (reference.trip .. "/" .. reference.score) or reference)
    local source = table.concat(Antidebug.prologue(names, config), "\n") .. "\nreturn ADT"
    local chunk, err = loadWith(source, { E = env, DM = string.char, G3 = pcall, G4 = type })
    check("probe parity " .. label .. ": compiles", chunk ~= nil, err)
    if chunk then
      local ok, actual = pcall(chunk)
      check("probe parity " .. label .. ": runtime", ok and actual == trip and
        refOk and actual == reference.trip, actual)
    end
  end
  local families = {
    { "byte", "concat", "pcall", "select" },
    { "char", "mathl", "tablel" },
    { "tonum", "nextp", "raw", "sm", "raweq" },
  }
  local filled = { 0, 0, 0 }
  for i = 1, 512 do
    local seed = 0xB900 + i * 977
    local config = Antidebug.plan({ seed = seed })
    local repeated = Antidebug.plan({ seed = seed })
    local present, initial = {}, { hook = true }
    local mask, unique, preserved, weights = 0, true, true, true
    local state, weak = (seed + 0xA11D) % 4294967296, 0
    for j = 2, #Antidebug.PROBES do
      state = (state * 1664525 + 1013904223) % 4294967296
      if math.floor(state / 65536) % 2 == 0 then
        initial[Antidebug.PROBES[j]] = true
        weak = weak + 1
      end
    end
    if weak == 0 then initial.what = true end
    for _, name in ipairs(config.probes) do
      if present[name] then unique = false end
      present[name] = true
    end
    local known = 0
    for j, name in ipairs(Antidebug.PROBES) do
      if present[name] then mask = mask + 2 ^ (j - 1) known = known + 1 end
      if initial[name] and not present[name] then preserved = false end
      if config.weights[name] ~= repeated.weights[name] then weights = false end
    end
    check("plan coverage: mask parity " .. i, unique and known == #config.probes and
      mask == config.mask, config.mask)
    check("plan coverage: initial probes retained " .. i, preserved)
    check("plan coverage: threshold and hook weight " .. i,
      config.threshold == 2 and config.weights.hook == 2)
    for fi, family in ipairs(families) do
      local covered, already = false, false
      for _, name in ipairs(family) do
        covered = covered or present[name]
        already = already or initial[name]
      end
      if not already then filled[fi] = filled[fi] + 1 end
      check("plan coverage: family " .. fi .. " seed " .. i, covered)
    end
    check("plan coverage: deterministic plan " .. i, weights and
      config.mask == repeated.mask and config.threshold == repeated.threshold and
      table.concat(config.probes, ",") == table.concat(repeated.probes, ","))
    check("plan coverage: deterministic prologue " .. i,
      table.concat(Antidebug.prologue(names, config), "\n") ==
      table.concat(Antidebug.prologue(names, repeated), "\n"))
    if i <= 32 then
      probeParity("clean seed " .. i, config, _G, 0, 0)
      local executor = setmetatable({ debug = hookedDebug(),
        getgenv = function() return {} end }, { __index = _G })
      probeParity("executor seed " .. i, config, executor, 0, 0)
      local proxy = setmetatable({}, { __index = function()
        error("optional debug denied", 2) end })
      local proxied = setmetatable({ debug = proxy }, { __index = _G })
      probeParity("debug-proxy seed " .. i, config, proxied, 0, 0)
      local denied = function() error("optional debug denied", 2) end
      local locked = setmetatable({ debug = { gethook = denied,
        getinfo = denied, getupvalue = denied, getregistry = denied } },
        { __index = _G })
      probeParity("debug-denied seed " .. i, config, locked, 0, 0)
      local tableSyn = setmetatable({ debug = hookedDebug(), syn = {} },
        { __index = _G })
      probeParity("table-syn seed " .. i, config, tableSyn, 0, 0)
    end
  end
  check("plan coverage: each fallback exercised", filled[1] > 0 and
    filled[2] > 0 and filled[3] > 0, table.concat(filled, ","))
  notes[#notes + 1] = "MODULE11_COVERAGE seeds=512 filled=" .. table.concat(filled, ",")
  local cases = {
    { "math-native", "mathl", { math = math }, 0 },
    { "table-native", "tablel", { table = table }, 0 },
    { "raw-equality-native", "raweq", { rawequal = rawequal }, 0 },
  }
  for _, value in ipairs({ false, 42, "not a library", function() end }) do
    cases[#cases + 1] = { "math-" .. type(value), "mathl", { math = value }, 0 }
    cases[#cases + 1] = { "table-" .. type(value), "tablel", { table = value }, 0 }
  end
  local pcallCases = {
    { "native", pcall, 0 },
    { "forwarding", function(...) return pcall(...) end, 0 },
    { "drops-nil", function(...)
      local ok, a, b, c = pcall(...)
      if ok then return ok, b, c end
      return ok, a
    end, 1 },
    { "drops-false", function(...)
      local ok, a, b, c = pcall(...)
      if ok then return ok, a, c end
      return ok, a
    end, 1 },
    { "drops-tail", function(...)
      local ok, a, b = pcall(...)
      return ok, a, b
    end, 1 },
    { "changes-error-table", function(...)
      local ok, a, b, c = pcall(...)
      if not ok and type(a) == "table" then return false, {} end
      return ok, a, b, c
    end, 1 },
    { "stringifies-error-table", function(...)
      local ok, a, b, c = pcall(...)
      if not ok then return false, tostring(a) end
      return ok, a, b, c
    end, 1 },
    { "changes-error-string", function(...)
      local ok, a, b, c = pcall(...)
      if not ok and type(a) == "string" then return false, "other" end
      return ok, a, b, c
    end, 1 },
    { "raises", function() error("pcall wrapper") end, 1 },
  }
  for _, case in ipairs(pcallCases) do
    cases[#cases + 1] = { "pcall-" .. case[1], "pcall",
      { pcall = case[2], error = error, string = string }, case[3] }
  end
  cases[#cases + 1] = { "pcall-error-forwarding", "pcall",
    { pcall = pcall, error = function(...) return error(...) end, string = string }, 0 }
  cases[#cases + 1] = { "pcall-error-replacement", "pcall",
    { pcall = pcall, error = function(obj)
      if type(obj) == "table" then obj = {} end
      return error(obj)
    end, string = string }, 1 }
  cases[#cases + 1] = { "pcall-error-returns", "pcall",
    { pcall = pcall, error = function(obj) return obj end, string = string }, 1 }
  cases[#cases + 1] = { "pcall-find-raises", "pcall",
    { pcall = pcall, error = error, string = {
      find = function() error("find wrapper") end } }, 1 }
  cases[#cases + 1] = { "pcall-find-missing", "pcall",
    { pcall = pcall, error = error, string = {} }, 0 }
  cases[#cases + 1] = { "pcall-captured-type", "pcall",
    { pcall = pcall, error = error, type = function() error("type wrapper") end }, 0 }
  local selectCases = {
    { "native", select, 0 },
    { "forwarding", function(...) return select(...) end, 0 },
    { "bad-count", function(index, ...)
      if index == "#" then return 2 end
      return select(index, ...)
    end, 1 },
    { "bad-zero-count", function(index, ...)
      if index == "#" and select("#", ...) == 0 then return 1 end
      return select(index, ...)
    end, 1 },
    { "drops-nil", function(index, ...)
      if index == "#" then return select(index, ...) end
      local a, b, c = select(index, ...)
      if a == nil then return b, c end
      return select(index, ...)
    end, 1 },
    { "drops-false", function(index, ...)
      if index == "#" then return select(index, ...) end
      local a, b, c = select(index, ...)
      if b == false then return a, c end
      return select(index, ...)
    end, 1 },
    { "drops-results", function(index, ...)
      local a = select(index, ...)
      return a
    end, 1 },
    { "bad-negative", function(index, ...)
      if type(index) == "number" and index < 0 then index = -index end
      return select(index, ...)
    end, 1 },
    { "bad-last", function(index, ...)
      if index == -1 then return nil end
      return select(index, ...)
    end, 1 },
    { "negative-raises", function(index, ...)
      if type(index) == "number" and index < 0 then error("negative index") end
      return select(index, ...)
    end, 1 },
    { "raises", function() error("select wrapper") end, 1 },
  }
  for _, case in ipairs(selectCases) do
    cases[#cases + 1] = { "select-" .. case[1], "select", { select = case[2] }, case[3] }
  end
  cases[#cases + 1] = { "select-captured-handles", "select",
    { select = select, pcall = function() error("pcall wrapper") end,
      type = function() error("type wrapper") end }, 0 }
  cases[#cases + 1] = { "pcall-missing", "pcall", { error = error }, 0 }
  cases[#cases + 1] = { "error-missing", "pcall", { pcall = pcall }, 0 }
  cases[#cases + 1] = { "select-missing", "select", {}, 0 }
  for _, value in ipairs({ false, 42, "not callable", setmetatable({}, {
      __call = function() error("non-function called") end }) }) do
    cases[#cases + 1] = { "pcall-" .. type(value), "pcall",
      { pcall = value, error = error }, 0 }
    cases[#cases + 1] = { "error-" .. type(value), "pcall",
      { pcall = pcall, error = value }, 0 }
    cases[#cases + 1] = { "find-" .. type(value), "pcall",
      { pcall = pcall, error = error, string = { find = value } }, 0 }
    cases[#cases + 1] = { "select-" .. type(value), "select", { select = value }, 0 }
  end
  cases[#cases + 1] = { "soft-math", "mathl",
    { math = { floor = function() return 0 end, abs = math.abs, max = math.max } }, 1 }
  cases[#cases + 1] = { "ambiguous-hook", "hook", { debug = hookedDebug() }, 1 }
  for _, case in ipairs(cases) do
    local config = { seed = 4, threshold = 2, probes = { case[2] },
      weights = { [case[2]] = 2 } }
    for i, name in ipairs(Antidebug.PROBES) do
      if name == case[2] then config.mask = 2 ^ (i - 1) end
    end
    probeParity(case[1], config, case[3], case[4], case[4] * 2)
    local executor = {}
    for key, value in pairs(case[3]) do executor[key] = value end
    executor.getgenv = function() return {} end
    local score = case[4] * 2
    if Antidebug.AMBIGUOUS[case[2]] then score = 0 end
    if Antidebug.SOFT[case[2]] then score = case[4] end
    probeParity(case[1] .. " executor", config, executor, score >= 2 and 1 or 0, score)
  end
  probeParity("two soft executor", { seed = 4, threshold = 2,
    probes = { "mathl", "raweq" }, weights = { mathl = 2, raweq = 2 },
    mask = 2 ^ 19 + 2 ^ 20 }, { math = { floor = function() return 0 end,
    abs = math.abs, max = math.max }, rawequal = function() return true end,
    getgenv = function() return {} end }, 1, 2)
  local removed = { load = true, reload = true, dump2 = true }
  for _, name in ipairs(Antidebug.PROBES) do
    check("source evaluation probe removed: " .. name, not removed[name])
  end
  local source = "local n=0 for i=1,12000 do n=n+i end print(n)"
  local result = require("src.obfuscate").run(source, { preset = "normal", seed = 4 })
  check("loader-free VM: builds", result.ok)
  if result.ok then
    local expected = execute(source)
    local calls = 0
    local function blockedLoader()
      calls = calls + 1
      error("generated runtime called a source loader")
    end
    local hosts = {
      { load = false, loadstring = false },
      { load = blockedLoader, loadstring = blockedLoader },
      { load = blockedLoader, loadstring = blockedLoader, getgenv = function() return {} end },
    }
    for i, env in ipairs(hosts) do
      local actual, err = runIn(result.code, env)
      check("loader-free VM: host " .. i .. " preserves output", actual == expected, err or actual)
    end
    check("loader-free VM: no source evaluation", calls == 0, calls)
  end
end

-- ---------------------------------------------------------------------------
-- 9. Summary
-- ---------------------------------------------------------------------------
notes[#notes + 1] = string.format(
  "MODULE11_PROBES list=%s mask=%.0f threshold=%d weights=%d/%d/%d/%d",
  table.concat(cfg.probes, ","), cfg.mask, cfg.threshold, cfg.weights.hook,
  cfg.weights.what, cfg.weights.func, cfg.weights.dump)
local diffChars = 0
if deviated then
  for i = 1, math.max(#cleanSample, #deviated) do
    if cleanSample:sub(i, i) ~= deviated:sub(i, i) then
      diffChars = diffChars + 1
    end
  end
end
notes[#notes + 1] = string.format(
  "MODULE11_DEVIATION clean=%d hooked=%d diff=%d",
  #cleanSample, #(deviated or ""), diffChars)
notes[#notes + 1] = string.format("MODULE11_CHECKS %d/%d",
  checks - failures, checks)

local printOut = print
for i = 1, #notes do printOut(notes[i]) end
printOut("MODULE11_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
