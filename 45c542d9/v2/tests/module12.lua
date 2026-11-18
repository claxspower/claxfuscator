-- module12.lua -- acceptance tests for layer 12 (assembly, integrity, auto-fix).
--
-- Covers:
--   * src/integrity.lua plan/hash contract and emitted line shape
--   * the assembled pipeline (Obfuscate.run), default preset `strong`
--   * runtime integrity: canary tamper, handler probe line, blob hash, and a
--     clean run that matches the source
--   * src/autofix.lua sandbox (determinism, capture, blocked io/os, step
--     limit), comparison rules and the escalation ladder
--   * src/cli.lua parsing and end-to-end file behavior
--   * scale/build budget and per-seed polymorphism
local Obfuscate = require("src.obfuscate")
local Autofix = require("src.autofix")
local Cli = require("src.cli")
local Integrity = require("src.integrity")
local Tamper = require("src.tamper")

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

local function note(text)
  notes[#notes + 1] = "MODULE12_NOTE " .. text
end

-- ---------------------------------------------------------------- fixtures
local MARKER = "M12_SECRET_MARKER"
local SAMPLE = [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local tags = {"alpha", "beta", "gamma", "M12_SECRET_MARKER"}
local c = counter(10)
local sum = 0
for i = 1, 60 do
  if i % 3 == 0 then sum = sum + i end
end
print(fact(6), tags[1], tags[2], tags[3], tags[4], c(1), c(2), sum, "tail")
local t = {}
for i = 1, 12 do t[#t + 1] = i * i end
print(table.concat(t, ","))
return fact(5), tags[2]
]]

local function runEnv(code, env)
  local out = {}
  env = env or {}
  if not getmetatable(env) then setmetatable(env, { __index = _G }) end
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local fn, err
  if setfenv then
    fn, err = loadstring(code, "@case")
    if fn then setfenv(fn, env) end
  else
    fn, err = load(code, "@case", "t", env)
  end
  if not fn then return nil, false, "load: " .. tostring(err) end
  local ok, first = pcall(fn)
  -- A silent tamper stop returns nothing at all, so `first` distinguishes it
  -- from a run that completed and handed its values back.
  return table.concat(out, "\n"), ok, ok and nil or first, first
end

local REFERENCE = Autofix.sandboxRun(SAMPLE)
check("reference fixture runs", REFERENCE.ok, REFERENCE.error)

-- ---------------------------------------------------------------- integrity
local planA = Integrity.plan({ seed = 0x51A7 })
local planB = Integrity.plan({ seed = 0x51A7 })
check("plan: deterministic for a seed",
  planA.canary == planB.canary and planA.salt == planB.salt and
  planA.period == planB.period and planA.expect == planB.expect)
local planC = Integrity.plan({ seed = 0x51A8 })
check("plan: seed changes canary and salt",
  planA.canary ~= planC.canary or planA.salt ~= planC.salt)
check("plan: period in 4097..6144",
  planA.period > 4096 and planA.period <= 6144, planA.period)
check("plan: canary is 12..20 alphanumerics",
  planA.canaryLen >= 12 and planA.canaryLen <= 20 and
  #planA.canary == planA.canaryLen and
  planA.canary:match("^[%w]+$") ~= nil, planA.canary)
check("plan: salt stays below 2^31", planA.salt >= 0 and planA.salt < 2147483648,
  planA.salt)
check("plan: expect is the SipHash of the canary",
  planA.expect == Integrity.sipHash(planA.canary, planA.k0, planA.k1) and
  planA.expect >= 0 and planA.expect < 4294967296, planA.expect)
check("plan: canary hash is not the FNV mirror",
  planA.expect ~= Integrity.hash(planA.canary, planA.salt))

-- Independent reference for the 16-bit split FNV variant.
local function refHash(s, salt)
  local h = (2166136261 + salt) % 4294967296
  for i = 1, #s do
    h = (h + s:byte(i)) % 4294967296
    local lo = h % 65536
    local hi = (h - lo) / 65536
    h = (lo * 403 + ((lo * 256 + hi * 403) % 65536) * 65536) % 4294967296
  end
  return h
end
local probeStrings = { "", "a", "canary", planA.canary, "0123456789abcdef" }
local hashOk = true
for i = 1, #probeStrings do
  if Integrity.hash(probeStrings[i], planA.salt) ~=
    refHash(probeStrings[i], planA.salt) then hashOk = false end
end
check("hash: matches the independent split multiply", hashOk)

check("FAIL action is a nil index",
  Integrity.FAIL == "local zp=nil local _=zp[1]" and
  not Integrity.FAIL:find("error") and not Integrity.FAIL:find("os%.") and
  not Integrity.FAIL:find("print"))

local fakeNames = {}
for _, key in ipairs({ "H", "HB", "D", "IT", "IF", "IB", "IC", "IE", "IG",
  "II", "IP", "UB", "E", "IZ" }) do fakeNames[key] = "$" .. key end
local prologue = Integrity.prologue(fakeNames, planA, "$SP")
local prologueText = table.concat(prologue, "\n")
local p1, p2 = planA.canaryParts[1][1], planA.canaryParts[1][2]
check("prologue: defines the check function and the state table",
  prologueText:find("local $IF=function(s) return $SP(s,(", 1, true) ~= nil and
  prologueText:find("local $IB=function", 1, true) ~= nil and
  prologueText:find("local $IZ={", 1, true) ~= nil and
  prologueText:find('"' .. p1 .. '".."' .. p2 .. '"', 1, true) ~= nil and
  prologueText:find("," .. planA.digests[1] .. ",", 1, true) ~= nil and
  prologueText:find("local $IP=" .. (planA.period + planA.chain0 % 1021) %
    4294967296, 1, true) ~= nil)
check("plan: three split canaries",
  planA.count == 3 and #planA.canaries == 3 and
  planA.canaryParts[1][1] .. planA.canaryParts[1][2] == planA.canary and
  #planA.checkpoints == 6)
check("plan: third probe key per checkpoint",
  #planA.probeC == planA.checkpointCount and #planA.probeA == #planA.probeC)
local loopLine = Integrity.loop(fakeNames, planA)
check("loop: rotates checkpoints and checks hash, length, chain",
  loopLine:find("local iq=$IZ[11]%6+1", 1, true) ~= nil and
  loopLine:find("local dv=$IZ[3+ci] if iq<=3 then dv=$IF($IZ[ci]) end",
    1, true) ~= nil and
  loopLine:find("#$IZ[ci]~=$IZ[6+ci]", 1, true) ~= nil and
  loopLine:find("$IZ[10]~=$IZ[17][iq]", 1, true) ~= nil and
  loopLine:find("IP=$IZ[14]+$IZ[10]%1021", 1, true) ~= nil)
check("loop: samples two handler keys against the backup",
  loopLine:find(fakeNames.IT .. "(" .. fakeNames.H .. "[pa])~=\"function\"",
    1, true) ~= nil and
  loopLine:find(fakeNames.IT .. "(" .. fakeNames.H .. "[pb])~=\"function\"",
    1, true) ~= nil and
  loopLine:find(fakeNames.H .. "[pa]~=" .. fakeNames.HB .. "[pa]", 1, true) ~=
    nil and
  loopLine:find(fakeNames.H .. "[pb]~=" .. fakeNames.HB .. "[pb]", 1, true) ~=
    nil and
  loopLine:find(Integrity.FAIL, 1, true) ~= nil)
check("loop: samples a third handler key (pe)",
  loopLine:find(fakeNames.IT .. "(" .. fakeNames.H .. "[pe])~=\"function\"",
    1, true) ~= nil and
  loopLine:find(fakeNames.H .. "[pe]~=" .. fakeNames.HB .. "[pe]", 1, true) ~=
    nil and
  loopLine:find("$IZ[21][iq]", 1, true) ~= nil)
check("loop: standalone plan (no keys) skips the full audit",
  loopLine:find("for k,v in", 1, true) == nil)
local blobLine = Integrity.blobCheck(fakeNames, planA, "blob-data")
check("blob check: SipHash for small payloads",
  blobLine:find("$IF($D)~=" ..
    Integrity.sipHash("blob-data", planA.k0, planA.k1), 1, true) ~= nil and
  blobLine:find(Integrity.FAIL, 1, true) ~= nil)
local big = string.rep("x", Integrity.BULK_LIMIT + 1)
local bigLine = Integrity.blobCheck(fakeNames, planA, big)
check("blob check: bulk payloads use the split FNV",
  bigLine:find("$IB($D)~=" .. Integrity.hash(big, planA.salt), 1, true) ~= nil)

-- ------------------------------------------------------------ pipeline run
local SEED = 0x12A0B5
local built = Obfuscate.run(SAMPLE, { preset = "strong", seed = SEED })
check("pipeline: strong preset succeeds", built.ok, built.stage)
check("pipeline: default preset is strong", Obfuscate.DEFAULT_PRESET == "strong")

if built.ok then
  local stats = built.stats
  check("stats: integrity on with a period in range",
    stats.integrity == true and stats.integrityPeriod > 4096 and
    stats.integrityPeriod <= 6144, stats.integrityPeriod)
  check("stats: canary length reported", stats.integrityCanaryLen ==
    #stats.integrityCanary)
  check("stats: probe key is a real handler",
    stats.integrityProbe >= 1 and type(stats.map) == "table")
  check("stats: opcode space is at least 200",
    stats.opcodes + stats.decoys >= 200,
    stats.opcodes .. "+" .. stats.decoys)
  check("stats: decoys at least match the real opcodes",
    stats.decoys >= stats.opcodes, stats.decoys .. "/" .. stats.opcodes)
  check("stats: selfmod and anti-debug active", stats.selfmod and stats.antidebug)
  check("stats: sampled dispatch guard is wired", stats.dispatchGuard == true and
    built.code:find("==" .. stats.integrityProbe .. " and " .. stats.names.VHF ..
      "~=" .. stats.names.HB .. "[" .. stats.integrityProbe .. "] then ", 1, true)
      ~= nil)
  check("stats: integrity chain shape",
    stats.integrityCanaries == 3 and stats.integrityCheckpoints == 6 and
    stats.integrityAuditTotal == #stats.realKeys + #stats.decoyKeys,
    stats.integrityCanaries .. "/" .. stats.integrityCheckpoints .. "/" ..
      stats.integrityAuditTotal)
  check("stats: late-hook latch wired into the tick",
    stats.names.ADH ~= nil and built.code:find("or " .. stats.names.ADH ..
      ">=2", 1, true) ~= nil)
  check("stats: environment chaff is emitted",
    stats.envChaff >= 20 and
    built.code:find("local " .. stats.names.CH .. "={", 1, true) ~= nil,
    stats.envChaff)
  check("stats: post-load primitive snapshot wired into the tick",
    stats.identityChecks == 5 + stats.identityExtra and
    stats.names.ADL == nil and stats.names.ALS == nil and
    stats.identityExtra >= 20 and
    built.code:find("local " .. stats.names.IS .. "={", 1, true) ~= nil and
    built.code:find(stats.names.IS .. "[1] and " .. stats.names.ADY .. "(" ..
      stats.names.ADB0 .. "," .. stats.names.AGH .. ")~=" ..
      stats.names.IS .. "[1]", 1, true) ~= nil and
    built.code:find(stats.names.IS .. "[5] and " .. stats.names.ADY .. "(" ..
      stats.names.ADS0 .. "," .. stats.names.AGD .. ")~=" ..
      stats.names.IS .. "[5]", 1, true) ~= nil)

  check("output: source marker does not leak",
    built.code:find(MARKER, 1, true) == nil)
  check("output: canary parts are embedded split",
    built.code:find('"' .. stats.integrityCanaryParts[1][1] .. '".."' ..
      stats.integrityCanaryParts[1][2] .. '"', 1, true) ~= nil)
  check("output: full canary literal never appears",
    built.code:find('"' .. stats.integrityCanary .. '"', 1, true) == nil)
  check("output: blob check is emitted",
    built.code:find(stats.names.IF .. "(" .. stats.names.D .. ")~=", 1, true)
      ~= nil)

  local run = Autofix.sandboxRun(built.code)
  check("run: obfuscated output matches the source",
    run.ok and run.output == REFERENCE.output and
    Autofix.compare(REFERENCE, run), run.error)
  check("run: return values survive", run.rets and run.rets.n == 2 and
    run.rets[1] == 120 and run.rets[2] == "beta")

  -- Canary tamper: replace one half of the first canary with a different
  -- equal-length half. The runtime digest and the running chain both break, so
  -- the tick fails with the nil index.
  local part = stats.integrityCanaryParts[1][1]
  local needle = '"' .. part .. '"'
  local at = built.code:find(needle, 1, true)
  check("tamper: canary part is findable", at ~= nil)
  if at then
    local replacement = (part:sub(1, 1) == "q" and "w" or "q") ..
      part:sub(2)
    local broken = built.code:sub(1, at - 1) .. '"' .. replacement .. '"' ..
      built.code:sub(at + #needle)
    local _, ok, err, first = runEnv(broken)
    check("tamper: canary mismatch stops the chunk silently",
      ok == true and err == nil and first == nil, tostring(err))
  end

  -- Handler probe: two sampled keys are type-checked and identity-checked
  -- against the private backup table, and the one-shot audit is present.
  check("tamper: handler probe is type- and identity-checked at runtime",
    built.code:find(stats.names.IT .. "(" .. stats.names.H ..
      "[pa])~=\"function\"", 1, true) ~= nil and
    built.code:find(stats.names.H .. "[pa]~=" .. stats.names.HB ..
      "[pa]", 1, true) ~= nil and
    built.code:find(stats.names.H .. "[pb]~=" .. stats.names.HB ..
      "[pb]", 1, true) ~= nil and
    built.code:find(stats.names.H .. "[pe]~=" .. stats.names.HB ..
      "[pe]", 1, true) ~= nil)
  check("tamper: handler table audit is emitted",
    built.code:find("for k,v in", 1, true) ~= nil)
  local probeCalls = 0
  for _ in built.code:gmatch("_tq%(function") do probeCalls = probeCalls + 1 end
  check("tamper: game-side probe block and count latch are emitted",
    stats.tamperProbes and stats.tamperProbes >= 30 and
    probeCalls == stats.tamperProbes and
    built.code:find("_tn~=" .. stats.tamperProbes, 1, true) ~= nil and
    built.code:find("_tt+3", 1, true) ~= nil, probeCalls)
end

local noInt = Obfuscate.run(SAMPLE, {
  preset = "fast", seed = SEED, integrity = false,
})
check("pipeline: integrity override disables the layer",
  noInt.ok and noInt.stats.integrity == false)
if noInt.ok then
  check("pipeline: no integrity check when disabled",
    noInt.code:find("zp=nil", 1, true) == nil)
  local plainRun = Autofix.sandboxRun(noInt.code)
  check("pipeline: partial preset still matches",
    plainRun.ok and plainRun.output == REFERENCE.output, plainRun.error)
end

-- Strong build with a hooked host: M11 deviates, M12 must stay silent.
local tripped = {
  debug = {
    gethook = function() return function() end end,
    getinfo = debug.getinfo,
    sethook = function() end,
  },
}
local tripOut, tripOk, tripErr = runEnv(built.code, tripped)
check("hooked host: no error escapes", tripOk == true, tostring(tripErr))
check("hooked host: output deviates silently",
  tripOut ~= nil and tripOut ~= REFERENCE.output)

local cleanOut, cleanOk = runEnv(built.code)
check("clean host: output matches", cleanOk == true and cleanOut ~= nil and
  cleanOut:find("720", 1, true) ~= nil)

-- Post-load dump hook: the runtime snapshots string.dump (and the debug entry
-- points) at load. A harness that replaces one of them while the program runs
-- must trip the integrity tick. The program itself performs the swap, so it
-- happens after the snapshot and before the first tick, and it writes to a
-- private copy of the string library so the test host stays intact.
local SWAP = [[
string.dump = function() return "canned" end
local s = 0
for i = 1, 4000 do s = s + i end
return s
]]
local swapBuilt = Obfuscate.run(SWAP, { preset = "strong", seed = 0x5150 })
if swapBuilt.ok and type(string.dump) == "function" then
  local strCopy = {}
  for k, v in pairs(string) do strCopy[k] = v end
  local _, swapOk, swapErr, swapRet = runEnv(swapBuilt.code, { string = strCopy })
  check("anti-dump: a post-load string.dump swap trips the tick",
    swapOk == true and swapErr == nil and swapRet == nil, tostring(swapErr))
else
  note("string.dump unavailable; post-load dump-hook check skipped")
end

-- ------------------------------------------------------- tamper probes (game)
-- The game-side block is inert off a live DataModel, so the mock below fakes
-- enough of the value model to enter it: typeof answers Instance through a
-- metatable marker, and every surface the block needs is either present and
-- consistent or absent (which each probe skips). Only the blocks the mock
-- contradicts may count.
local tamperBlock = Tamper.emit({ E = "E", G3 = "G3", G4 = "G4", DM = "DM" })
local function tamperRun(code, mock)
  local warned = false
  local flags = {}
  local E = {
    typeof = function(v)
      local mt = getmetatable(v)
      if type(mt) == "table" and mt.__t then return mt.__t end
      return type(v)
    end,
    game = mock.game, workspace = mock.workspace, string = string,
    warn = function() warned = true end, print = function() end, _G = flags,
  }
  local src = "local G3=pcall local G4=type local DM=string.char local E=... " ..
    code
  local fn, err
  if setfenv then
    fn, err = loadstring(src, "@tp")
    if fn then setfenv(fn, setmetatable({}, { __index = _G })) end
  else
    fn, err = load(src, "@tp", "t", setmetatable({}, { __index = _G }))
  end
  if not fn then return false, err end
  local ok, runErr = pcall(fn, E)
  return ok, runErr, warned, flags
end
local function fakeInst(t) return setmetatable(t, { __t = "Instance" }) end
local function cleanMock()
  return {
    game = fakeInst({ ClassName = "DataModel", PlaceId = 1, GameId = 2,
      JobId = "job-1" }),
    workspace = fakeInst({ ClassName = "Workspace", Gravity = 196.2 }),
  }
end

local okClean, errClean, warnedClean, flagsClean =
  tamperRun(tamperBlock, cleanMock())
check("tamper block: a clean mock registers every probe",
  okClean and errClean == nil and not warnedClean and
  flagsClean.ClaxFuscatorFG20 == true and flagsClean.ClaxFuscatorTP20 == nil,
  tostring(errClean))

local badMock = cleanMock()
badMock.workspace.Gravity = "high"
badMock.game.PlaceId = "not-a-number"
badMock.workspace.CurrentCamera = {}
local okBad, errBad, warnedBad, flagsBad = tamperRun(tamperBlock, badMock)
check("tamper block: three contradictions raise the warning",
  okBad and errBad == nil and warnedBad and
  flagsBad.ClaxFuscatorTP20 == true and flagsBad.ClaxFuscatorFG20 == nil,
  tostring(errBad))

local stripped = tamperBlock:gsub("_tn~=" .. (Tamper.probeCount or 39),
  "_tn~=1", 1)
local okStrip, _, warnedStrip = tamperRun(stripped, cleanMock())
check("tamper block: a short-circuited probe is itself an answer",
  okStrip and warnedStrip)

-- ----------------------------------------------------------------- sandbox
local ioRun = Autofix.sandboxRun('print("a") io.write("b", 1, "\\n") print("c")')
check("sandbox: captures print and io.write in order",
  ioRun.ok and ioRun.output == "a\nb1\nc\n", string.format("%q", ioRun.output))

local deterministic = [[
math.randomseed(os.time())
print(math.random(1, 1000), math.random(1, 1000), os.time(), os.clock())
]]
local d1 = Autofix.sandboxRun(deterministic)
local d2 = Autofix.sandboxRun(deterministic)
check("sandbox: deterministic environment", d1.ok and d1.output == d2.output,
  d1.output .. " vs " .. d2.output)

local noFile = Autofix.sandboxRun('io.open("x", "w")')
check("sandbox: io.open is blocked", not noFile.ok and
  tostring(noFile.error):find("disabled") ~= nil, noFile.error)
local noExit = Autofix.sandboxRun("os.exit(0)")
check("sandbox: os.exit is blocked", not noExit.ok and
  tostring(noExit.error):find("disabled") ~= nil, noExit.error)

if rawget(_G, "debug") and debug.sethook then
  local spin = Autofix.sandboxRun("while true do end", {
    maxSteps = 3000000, stepChunk = 1000000, seconds = 4,
  })
  check("sandbox: step limit stops a runaway loop",
    not spin.ok and tostring(spin.error):find("step limit") ~= nil,
    spin.error)
else
  note("debug.sethook unavailable; step-limit check skipped")
end

local capCompare = Autofix.compare(
  { ok = true, stage = "run", output = "x\n", rets = { n = 1, 5 } },
  { ok = true, stage = "run", output = "x\n", rets = { n = 1, 6 } })
check("compare: return mismatch is detected", capCompare == false)
local capLoose = Autofix.compare(
  { ok = true, stage = "run", output = "x\n", rets = { n = 1, 5 } },
  { ok = true, stage = "run", output = "x\n", rets = { n = 1, 6 } },
  { compareReturns = false })
check("compare: return check can be disabled", capLoose == true)
check("compare: output mismatch is detected",
  Autofix.compare({ ok = true, stage = "run", output = "a", rets = { n = 0 } },
    { ok = true, stage = "run", output = "b", rets = { n = 0 } }) == false)
check("compare: runtime failure is detected",
  Autofix.compare({ ok = true, stage = "run", output = "", rets = { n = 0 } },
    { ok = false, stage = "error", output = "", rets = { n = 0 } }) == false)

-- ----------------------------------------------------------------- autofix
local auto = Autofix.run(SAMPLE, { seed = 0x7070 })
check("auto-fix: strong verifies on the first attempt",
  auto.ok and auto.verified and #auto.attempts == 1 and
  auto.attempts[1].label == "strong" and auto.attempts[1].match == true,
  auto.stage .. " / " .. tostring(auto.attempts and auto.attempts[1] and
    auto.attempts[1].reason))
check("auto-fix: returns the winning code", auto.ok and
  auto.code ~= nil and #auto.code > 1000)
check("auto-fix: reports the winning settings", auto.ok and
  auto.preset == "strong" and auto.settings ~= nil and
  auto.settings.preset == "strong")

local fastStart = Autofix.run(SAMPLE, { seed = 0x7070, preset = "fast",
  verify = false })
check("auto-fix: preset selects the ladder start",
  fastStart.ok and fastStart.attempts[1].label == "fast" and
  fastStart.verified == false, fastStart.stage)

-- Forced compile failure: strong cannot build, normal can.
local calls = 0
local forced = function(source, opts)
  calls = calls + 1
  if opts.preset == "strong" then
    return {
      ok = false, stage = "compile", seed = opts.seed, preset = opts.preset,
      errors = { { line = 1, col = 1, msg = "forced compile failure" } },
    }
  end
  return Obfuscate.run(source, opts)
end
local ladder = Autofix.run(SAMPLE, { seed = 0x8080, engine = forced })
check("auto-fix: escalates past a compile failure",
  ladder.ok and ladder.verified and ladder.attempts[1].label == "strong" and
  ladder.attempts[1].ok == false and ladder.attempts[2].label == "normal" and
  ladder.attempts[2].match == true and calls == 2,
  "#" .. #ladder.attempts .. " " .. tostring(ladder.attempts[2] and
    ladder.attempts[2].preset))

-- Output mismatch on every preset: the ladder must exhaust and report.
local wrong = function(source, opts)
  local result = Obfuscate.run(source, opts)
  if result.ok then result.code = 'print("wrong")' end
  return result
end
local exhausted = Autofix.run(SAMPLE, { seed = 0x9090, engine = wrong })
check("auto-fix: exhaustion is reported", exhausted.ok == false and
  exhausted.stage == "exhausted" and #exhausted.attempts == #Autofix.LADDER,
  exhausted.stage .. " / " .. #exhausted.attempts)

-- Non-preset failure: parse errors stop the ladder immediately.
local fatal = function(source, opts)
  return {
    ok = false, stage = "parse", seed = opts.seed, preset = opts.preset,
    errors = { { line = 1, col = 1, msg = "syntax" } },
  }
end
local stopped = Autofix.run(SAMPLE, { seed = 0xA0A0, engine = fatal })
check("auto-fix: fatal stages do not retry",
  stopped.ok == false and stopped.stage == "parse" and
  #stopped.attempts == 1, #stopped.attempts)

local brokenSource = Obfuscate.run("local = 3", { preset = "strong" })
check("pipeline: parse error is surfaced", not brokenSource.ok and
  brokenSource.stage == "parse" and #brokenSource.errors > 0)

-- A source that raises at runtime must still produce a matching chunk.
local raiser = 'print("before") error("boom")'
local raised = Autofix.run(raiser, { seed = 0xB0B0, preset = "fast" })
check("auto-fix: matching runtime errors verify",
  raised.ok and raised.verified, raised.stage)

-- A source that never terminates cannot be judged; the budget must not turn
-- that into a hard failure.
local endless = Autofix.run("while true do end", {
  seed = 0xD0D0, preset = "fast", maxSteps = 2000000, stepChunk = 1000000,
  seconds = 5,
})
check("auto-fix: non-terminating source is inconclusive",
  endless.ok and endless.stage == "unverified" and endless.verified == false and
  tostring(endless.note):find("budget") ~= nil,
  endless.stage .. " / " .. tostring(endless.note))

-- A candidate that alone exhausts the budget is a sandbox limit, not a wrong
-- output: keep the build, mark it unverified, and stop climbing the ladder.
local slowEngine = function(source, opts)
  local result = Obfuscate.run(source, opts)
  result.code = "while true do end"
  return result
end
local slow = Autofix.run(SAMPLE, {
  seed = 0xE0E0, preset = "fast", engine = slowEngine,
  maxSteps = 2000000, stepChunk = 1000000, seconds = 5,
})
check("auto-fix: budget abort keeps the build unverified",
  slow.ok and slow.stage == "unverified" and slow.verified == false and
  slow.code == "while true do end" and #slow.attempts == 1,
  slow.stage .. " / " .. #slow.attempts)

-- --------------------------------------------------------------------- cli
local parsed = Cli.parse({ "input.lua" })
check("cli: default preset is strong and output is derived",
  parsed and parsed.preset == "strong" and parsed.output == "input.obf.lua")
local eqForm = Cli.parse({ "in.lua", "out.lua", "--preset=normal",
  "--seed=4294967295" })
check("cli: --key=value form parses", eqForm and eqForm.preset == "normal" and
  eqForm.seedNumber == 4294967295 and eqForm.output == "out.lua")
check("cli: invalid seed rejected", Cli.parse({ "in.lua", "--seed", "4294967296" }) == nil)
check("cli: non-numeric seed rejected", Cli.parse({ "in.lua", "--seed", "abc" }) == nil)
check("cli: unknown flag rejected", Cli.parse({ "in.lua", "--wat" }) == nil)
check("cli: unknown preset rejected", Cli.parse({ "in.lua", "--preset", "max" }) == nil)
check("cli: too many arguments rejected",
  Cli.parse({ "a.lua", "b.lua", "c.lua" }) == nil)
local outFlag = Cli.parse({ "in.lua", "positional.lua", "--out", "flag.lua" })
check("cli: --out wins over the positional output",
  outFlag and outFlag.output == "flag.lua")

local tmp = os.tmpname()
local inPath = tmp .. ".lua"
local outPath = tmp .. ".obf.lua"

local function writeSource(path, text)
  local f = io.open(path, "w")
  f:write(text)
  f:close()
end

local function readSource(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function capture()
  local lines = {}
  return lines, {
    out = function(s) lines[#lines + 1] = s end,
    err = function(s) lines[#lines + 1] = "ERR " .. s end,
  }
end

writeSource(inPath, SAMPLE)
os.remove(outPath)
local cliLines, cliSink = capture()
local cliCode = Cli.main({ inPath, outPath, "--seed", "4242" }, cliSink)
local cliFile = readSource(outPath)
check("cli: writes the obfuscated file", cliCode == 0 and cliFile ~= nil and
  #cliFile > 1000, cliCode)
if cliFile then
  local cliRun = Autofix.sandboxRun(cliFile)
  check("cli: written file loads and matches",
    cliRun.ok and cliRun.output == REFERENCE.output, cliRun.error)
end

local runLines, runSink = capture()
local runCode = Cli.main({ inPath, outPath, "--seed", "4242", "--run" }, runSink)
check("cli: --run verifies",
  runCode == 0 and table.concat(runLines, ""):find("verified") ~= nil, runCode)

local fixLines, fixSink = capture()
local fixCode = Cli.main({ inPath, outPath, "--seed", "4242", "--auto-fix" },
  fixSink)
check("cli: --auto-fix succeeds",
  fixCode == 0 and table.concat(fixLines, ""):find("attempt 1/strong") ~= nil,
  fixCode)

local badPath = tmp .. ".bad.lua"
local badOut = tmp .. ".bad.obf.lua"
writeSource(badPath, "local = 3")
os.remove(badOut)
local badLines, badSink = capture()
local badCode = Cli.main({ badPath, badOut }, badSink)
check("cli: obfuscation failure exits 2 and writes nothing",
  badCode == 2 and readSource(badOut) == nil,
  badCode .. " " .. table.concat(badLines, ""))

local missingLines, missingSink = capture()
local missingCode = Cli.main({ tmp .. ".missing.lua" }, missingSink)
check("cli: missing input exits 1", missingCode == 1, missingCode)

local helpLines, helpSink = capture()
local helpCode = Cli.main({ "--help" }, helpSink)
check("cli: help exits 0", helpCode == 0 and
  table.concat(helpLines, ""):find("usage:") ~= nil)

local dashLines, dashSink = capture()
local dashCode = Cli.main({ inPath, "-", "--seed", "77" }, dashSink)
check("cli: '-' writes to the sink", dashCode == 0 and
  table.concat(dashLines, ""):find("local ", 1, true) ~= nil)

os.remove(inPath)
os.remove(outPath)
os.remove(badPath)
os.remove(badOut)

-- --------------------------------------------------------------- scale run
local parts = {}
for i = 1, 150 do
  parts[#parts + 1] = string.format(
    "local function f%d(a, b) local s = a + b * %d " ..
    "if s %% 3 == 0 then s = s + 1 end return s end", i, i)
end
parts[#parts + 1] = "local total = 0"
for i = 1, 150 do
  parts[#parts + 1] = string.format("total = total + f%d(%d, %d)", i, i, i + 1)
end
parts[#parts + 1] = 'print("total", total)'
local BIG = table.concat(parts, "\n")
check("scale: fixture is at least 300 lines",
  select(2, BIG:gsub("\n", "\n")) + 1 >= 300)

local bigRef = Autofix.sandboxRun(BIG)
check("scale: fixture reference runs", bigRef.ok, bigRef.error)
local t0 = os.clock()
local bigBuilt = Obfuscate.run(BIG, { preset = "strong", seed = 0xC0FFEE })
local buildMs = math.floor((os.clock() - t0) * 1000 + 0.5)
check("scale: strong build succeeds", bigBuilt.ok, bigBuilt.stage)
check("scale: build stays under 10 s", buildMs < 10000, buildMs .. " ms")
if bigBuilt.ok then
  check("scale: output is substantial", #bigBuilt.code > 70000, #bigBuilt.code)
  local bigRun = Autofix.sandboxRun(bigBuilt.code, {
    maxSteps = 2000000000, seconds = 60,
  })
  check("scale: obfuscated build matches", bigRun.ok and
    bigRun.output == bigRef.output, bigRun.error)
  note(string.format("scale: %d lines -> %d B in %d ms",
    select(2, BIG:gsub("\n", "\n")) + 1, #bigBuilt.code, buildMs))
end

-- ------------------------------------------------------------- polymorphism
local seen = {}
local distinct = 0
for i = 1, 5 do
  local one = Obfuscate.run(SAMPLE, { preset = "fast", seed = 1000 + i * 7919 })
  if one.ok and not seen[one.code] then
    seen[one.code] = true
    distinct = distinct + 1
  end
end
check("polymorphism: five seeds give five outputs", distinct == 5, distinct)
local sameA = Obfuscate.run(SAMPLE, { preset = "fast", seed = 2024 })
local sameB = Obfuscate.run(SAMPLE, { preset = "fast", seed = 2024 })
check("polymorphism: same seed reproduces the output",
  sameA.ok and sameB.ok and sameA.code == sameB.code)

-- ------------------------------------------------------------------ report
for i = 1, #notes do print(notes[i]) end
if failures == 0 then
  print(string.format("MODULE12_CHECKS %d", checks))
  print("MODULE12_RESULT PASS")
  return
end
print(string.format("MODULE12_CHECKS %d FAILURES %d", checks, failures))
print("MODULE12_RESULT FAIL")
