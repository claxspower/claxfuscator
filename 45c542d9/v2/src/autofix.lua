-- autofix.lua -- layer 12: verify the obfuscated chunk, escalate when it fails.
--
--   Autofix.run(source, opts)        -> ladder: obfuscate, run, compare, retry
--   Autofix.verify(source, code)     -> compare one candidate against the source
--   Autofix.sandboxRun(chunk, opts)  -> run a chunk with captured stdout
--
-- The reference run and the obfuscated run share one deterministic
-- environment: fixed os.time/os.clock, a fixed math.randomseed and captured
-- print/io.write. Outputs are compared byte for byte, so a layer that breaks
-- the program (or the VM itself) is caught here instead of in the user's
-- executor.
--
-- The sandbox is a verification harness, not a security boundary. It blocks
-- the file/process side of io and os so a stray script cannot touch the host,
-- and it installs a count hook (per thread) that aborts runaway loops. The
-- debug library stays available because the M11 probes read it, but the
-- chunk sees `debug.gethook` report nil: without that, the harness's own step
-- hook would trip layer 11 and the "verified" run would be the deviated one.
local Obfuscate = require("src.obfuscate")

local unpackFn = table.unpack or unpack

local Autofix = {}

Autofix.DEFAULTS = {
  maxSteps = 400000000,
  stepChunk = 1000000,
  seconds = 10,
  randomSeed = 1,
  time = 1700000000,
}

Autofix.GOLDEN = 2654435761 -- 0x9E3779B1, below 2^32 so 5.1 is exact

-- Decreasing risk. `minimal` drops every optional layer except encryption and
-- the runtime integrity check, which is what finally ships.
Autofix.LADDER = {
  { label = "strong", preset = "strong" },
  { label = "normal", preset = "normal" },
  { label = "fast", preset = "fast" },
  {
    label = "minimal", preset = "fast",
    integrity = false, decoys = 32, schemes = 1,
  },
}

-- Parse and scope failures do not depend on the preset, so escalating cannot
-- help. Compile failures can come from flatten/opaque, so they retry.
local FATAL = { input = true, parse = true, scope = true }

local function pack(...)
  return { n = select("#", ...), ... }
end

local function blocked(name)
  return function()
    error("autofix: " .. name .. " is disabled in the sandbox", 0)
  end
end

-- Embedded hosts (fengari-web) have no `io` library at all, so a missing
-- library copies to an empty table instead of raising.
local function copyTable(src)
  local out = {}
  if type(src) ~= "table" then return out end
  for k, v in pairs(src) do out[k] = v end
  return out
end

-- ------------------------------------------------------------- sandbox env
local function makeEnv(parts, opts, attach)
  local env = copyTable(_G)
  env._G = env
  env.arg = { [0] = "sandbox" }

  local function emit(s) parts[#parts + 1] = s end

  env.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    emit(table.concat(t, "\t") .. "\n")
  end

  local ioCopy = copyTable(io)
  ioCopy.write = function(...)
    for i = 1, select("#", ...) do emit(tostring(select(i, ...))) end
  end
  ioCopy.read = blocked("io.read")
  ioCopy.open = blocked("io.open")
  ioCopy.lines = blocked("io.lines")
  ioCopy.popen = blocked("io.popen")
  ioCopy.tmpfile = blocked("io.tmpfile")
  env.io = ioCopy

  local fixedTime = opts.time
  if fixedTime == nil then fixedTime = Autofix.DEFAULTS.time end
  local realDate = os.date
  local osCopy = copyTable(os)
  osCopy.time = function() return fixedTime end
  osCopy.date = function(fmt, t)
    if t == nil then t = fixedTime end
    return realDate(fmt, t)
  end
  local ticks = 0
  osCopy.clock = function()
    ticks = ticks + 1
    return (ticks - 1) * 0.001
  end
  osCopy.exit = blocked("os.exit")
  osCopy.execute = blocked("os.execute")
  osCopy.remove = blocked("os.remove")
  osCopy.rename = blocked("os.rename")
  osCopy.tmpname = blocked("os.tmpname")
  env.os = osCopy

  local seed = opts.randomSeed
  if seed == nil then seed = Autofix.DEFAULTS.randomSeed end
  if env.math and env.math.randomseed then
    pcall(env.math.randomseed, seed)
  end

  -- Fengari's floor returns the float subtype where PUC 5.3+ returns an
  -- integer, so `tostring(math.floor(3.0))` would be "3.0" there. The VM
  -- normalises decoded operands through floor, which would turn every integer
  -- register into a float and make a correct program print differently only
  -- inside this harness. Narrow the result back to an integer when possible.
  if env.math and env.math.floor then
    local mathCopy = copyTable(env.math)
    local realFloor, tointeger = mathCopy.floor, mathCopy.tointeger
    if tointeger then
      mathCopy.floor = function(x)
        local r = realFloor(x)
        local i = tointeger(r)
        if i ~= nil then return i end
        return r
      end
    end
    env.math = mathCopy
  end

  if coroutine then
    local coCopy = copyTable(coroutine)
    local realCreate = coroutine.create
    coCopy.create = function(f)
      local co = realCreate(f)
      attach(co)
      return co
    end
    env.coroutine = coCopy
  end

  -- The step/time guard is a real debug hook, and M11 treats any installed
  -- hook as a debugger by design. Verification needs the clean-host baseline,
  -- so the chunk sees a debug library whose gethook reports none while the
  -- harness hook keeps firing. Everything else in debug stays real.
  local dbg = rawget(_G, "debug")
  if dbg then
    local dbgCopy = copyTable(dbg)
    dbgCopy.gethook = function() return nil end
    env.debug = dbgCopy
  end

  -- Executor-gate baseline: a gated chunk must still run under verification, so
  -- the harness presents the getgenv marker a real executor exposes. A plain
  -- website runner has no such marker and the gate no-ops there instead.
  env.getgenv = function() return env end

  return env
end

-- -------------------------------------------------------------- sandbox run
function Autofix.sandboxRun(chunk, opts)
  opts = opts or {}
  local parts = {}
  -- Both counters stay in the float domain: Fengari's lua_Integer is 32-bit, so
  -- a large budget past 2^31 would wrap negative and disable the step guard.
  local maxSteps = opts.maxSteps
  if maxSteps == nil then maxSteps = Autofix.DEFAULTS.maxSteps end
  maxSteps = maxSteps + 0.0
  local stepChunk = opts.stepChunk
  if stepChunk == nil then stepChunk = Autofix.DEFAULTS.stepChunk end
  local seconds = opts.seconds
  if seconds == nil then seconds = Autofix.DEFAULTS.seconds end
  seconds = seconds + 0.0

  local debugLib = rawget(_G, "debug")
  local steps, started = 0.0, os.clock()
  local function tick()
    steps = steps + stepChunk + 0.0
    if steps > maxSteps then error("autofix: step limit", 0) end
    if seconds > 0 and (os.clock() - started) > seconds then
      error("autofix: time limit", 0)
    end
  end
  local hookOn = maxSteps > 0 and debugLib ~= nil and debugLib.sethook ~= nil

  local function attach(thread)
    if not hookOn then return end
    if thread then
      pcall(debugLib.sethook, thread, tick, "", stepChunk)
    else
      pcall(debugLib.sethook, tick, "", stepChunk)
    end
  end

  local env = makeEnv(parts, opts, attach)
  local loader = loadstring or load
  local chunkName = opts.chunkname or "=sandbox"
  local fn, loadErr
  if setfenv then
    fn, loadErr = loader(chunk, chunkName)
    if fn then setfenv(fn, env) end
  else
    fn, loadErr = load(chunk, chunkName, "t", env)
  end
  if not fn then
    return {
      ok = false, stage = "load", output = "", error = tostring(loadErr),
      steps = 0, elapsed = 0,
    }
  end

  attach(nil)
  local call = pack(pcall(fn))
  if hookOn then pcall(debugLib.sethook) end
  local elapsed = math.floor((os.clock() - started) * 1000 + 0.5)

  local ok = call[1] == true
  local rets
  if ok then
    rets = pack(unpackFn(call, 2, call.n))
  else
    rets = pack()
  end
  return {
    ok = ok,
    stage = ok and "run" or "error",
    output = table.concat(parts),
    error = (not ok) and tostring(call[2]) or nil,
    rets = rets,
    steps = steps,
    elapsed = elapsed,
  }
end

-- ------------------------------------------------------------- comparison
local function sketch(v, depth, seen)
  local t = type(v)
  if t == "nil" or t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    return string.format("%.17g", v)
  end
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return "<" .. t .. ">" end
  if depth <= 0 then return "{...}" end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local items = {}
  local count = 0
  for k, val in pairs(v) do
    items[#items + 1] = sketch(k, depth - 1, seen) .. "=" ..
      sketch(val, depth - 1, seen)
    count = count + 1
    if count >= 128 then
      items[#items + 1] = "..."
      break
    end
  end
  seen[v] = nil
  table.sort(items)
  return "{" .. table.concat(items, ",") .. "}"
end

local function sameReturns(a, b)
  local an = a and a.n or 0
  local bn = b and b.n or 0
  if an ~= bn then return false end
  for i = 1, an do
    if sketch(a[i], 2, {}) ~= sketch(b[i], 2, {}) then return false end
  end
  return true
end

-- Both chunks must agree on whether they finished, on everything they printed
-- and (when both finished) on their return values. Error messages are not
-- compared: renames and line numbers legitimately change them.
function Autofix.compare(reference, candidate, opts)
  opts = opts or {}
  if not reference then return true, nil end
  if reference.stage == "load" then return false, "reference does not load" end
  if reference.ok ~= candidate.ok then
    return false, candidate.ok and "unexpected success" or "runtime error"
  end
  if reference.output ~= candidate.output then return false, "output mismatch" end
  if opts.compareReturns ~= false and candidate.ok and
    not sameReturns(reference.rets, candidate.rets) then
    return false, "return mismatch"
  end
  return true, nil
end

-- A chunk that was stopped by the sandbox budget, rather than by its own code,
-- did not finish. Both sides hitting the budget says nothing about agreement.
local function aborted(run)
  if run == nil or run.ok or type(run.error) ~= "string" then return false end
  return run.error:find("autofix: step limit", 1, true) ~= nil or
    run.error:find("autofix: time limit", 1, true) ~= nil
end

function Autofix.verify(source, code, opts)
  opts = opts or {}
  local reference = Autofix.sandboxRun(source, opts)
  local candidate = Autofix.sandboxRun(code, opts)
  local refAborted = aborted(reference)
  local matched, reason
  if refAborted then
    matched, reason = candidate.stage ~= "load", nil
  elseif aborted(candidate) then
    matched, reason = false, "sandbox limit"
  else
    matched, reason = Autofix.compare(reference, candidate, opts)
  end
  return {
    ok = matched,
    reason = reason,
    verified = reference.stage ~= "load" and not refAborted,
    reference = reference,
    candidate = candidate,
    note = reference.stage == "load" and "source chunk does not load"
      or refAborted and "source did not finish within the sandbox budget"
      or nil,
  }
end

-- ------------------------------------------------------------------- ladder
local function strategyArgs(strategy, seed, opts)
  local args = { preset = strategy.preset, seed = seed }
  local keys = { "selfmod", "antidebug", "integrity", "flatten", "opaque",
    "decoys", "schemes" }
  for i = 1, #keys do args[keys[i]] = strategy[keys[i]] end
  -- Orthogonal protections survive every ladder rung: a repaired build must
  -- not silently lose gethui/anti-webhook or the executor gate.
  if opts then
    args.executor = opts.executor
    args.gethui = opts.gethui
    args.antiwebhook = opts.antiwebhook
  end
  return args
end

local function seedAt(base, index)
  if base == nil then return nil end
  return (base + (index - 1) * Autofix.GOLDEN) % 4294967296
end

local function ladderFor(opts)
  if opts.ladder then return opts.ladder end
  local start = opts.preset or Obfuscate.DEFAULT_PRESET
  local from = 1
  for i = 1, #Autofix.LADDER do
    if Autofix.LADDER[i].preset == start then
      from = i
      break
    end
  end
  local list = {}
  for i = from, #Autofix.LADDER do list[#list + 1] = Autofix.LADDER[i] end
  return list
end

local function settingsOf(result)
  local s = result.settings or {}
  s.preset = result.preset
  s.selfmod = result.selfmod
  s.antidebug = result.antidebug
  s.integrity = result.integrity
  return s
end

-- opts:
--   preset       start of the ladder (default strong)
--   seed         base seed; each attempt derives its own
--   maxSteps / seconds / compareReturns  forwarded to the sandbox
--   engine       function(source, opts) -> Obfuscate result (tests inject one)
--   verify       false disables the reference run entirely
function Autofix.run(source, opts)
  opts = opts or {}
  local started = os.clock()
  local reference
  if opts.verify ~= false then
    reference = Autofix.sandboxRun(source, opts)
  end
  local verifiable = reference ~= nil and reference.stage ~= "load" and
    not aborted(reference)
  local unverifiedNote
  if reference == nil then
    unverifiedNote = "verification disabled"
  elseif reference.stage == "load" then
    unverifiedNote = "source chunk does not load on this host"
  else
    unverifiedNote = "source did not finish within the sandbox budget"
  end
  local strategies = ladderFor(opts)
  local engine = opts.engine or Obfuscate.run
  local attempts = {}

  for i = 1, #strategies do
    local strategy = strategies[i]
    local args = strategyArgs(strategy, seedAt(opts.seed, i), opts)
    local t0 = os.clock()
    local result = engine(source, args)
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    local record = {
      index = i,
      label = strategy.label,
      preset = strategy.preset,
      seed = args.seed,
      stage = result.stage,
      ok = result.ok,
      ms = ms,
    }

    if not result.ok then
      record.reason = result.stage
      record.errors = result.errors
      attempts[#attempts + 1] = record
      if FATAL[result.stage] then
        return {
          ok = false, stage = result.stage, attempts = attempts,
          errors = result.errors, reference = reference,
          failedPreset = strategy.preset, seed = args.seed,
          ms = math.floor((os.clock() - started) * 1000 + 0.5),
        }
      end
    else
      local run = Autofix.sandboxRun(result.code, {
        maxSteps = opts.maxSteps,
        stepChunk = opts.stepChunk,
        seconds = opts.seconds,
      })
      record.run = run
      -- A budget abort is not evidence the output is wrong, and a lower preset
      -- cannot make the same chunk cheaper. Keep the build, mark it unverified.
      local matched, reason, budgetLimited
      if verifiable then
        if aborted(run) then
          matched, reason, budgetLimited = false, "sandbox limit", true
        else
          matched, reason = Autofix.compare(reference, run, opts)
        end
      else
        matched, reason = run.stage ~= "load", run.stage == "load" and "load" or nil
      end
      record.match = matched
      record.reason = reason
      if matched or budgetLimited then
        attempts[#attempts + 1] = record
        local out = {
          ok = true,
          stage = (verifiable and not budgetLimited) and "done" or "unverified",
          code = result.code,
          stats = result.stats,
          seed = result.seed,
          preset = result.preset,
          attempts = attempts,
          reference = reference,
          run = run,
          verified = verifiable and not budgetLimited,
          note = budgetLimited and
            "sandbox budget exceeded on the obfuscated chunk" or
            (verifiable and nil or unverifiedNote),
          ms = math.floor((os.clock() - started) * 1000 + 0.5),
        }
        local extra = settingsOf(result)
        out.selfmod = extra.selfmod
        out.antidebug = extra.antidebug
        out.integrity = extra.integrity
        out.settings = extra
        return out
      end
      attempts[#attempts + 1] = record
    end
  end

  return {
    ok = false,
    stage = "exhausted",
    attempts = attempts,
    reference = reference,
    errors = {},
    ms = math.floor((os.clock() - started) * 1000 + 0.5),
  }
end

return Autofix
