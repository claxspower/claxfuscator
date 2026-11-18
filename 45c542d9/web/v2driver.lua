-- v2driver.lua -- browser-side entry point for the layer 12 pipeline.
--
-- The page defines __ACTION ("build" | "run" | "fix"), __SRC, __CODE,
-- __PRESET, __SEED (-1 = auto), __MAXSTEPS and __SECONDS, mounts the v2
-- modules under their `src.*` names and then runs this chunk in the Lua VM.
--
-- Result framing (fields separated by \1):
--
--   status \1 jsonLength \1 json \1 code
--
-- `json` is pure ASCII (its string values are percent-encoded), so its byte
-- length is also its JavaScript string length and the header can be sliced
-- safely. `code` is whatever remains of the frame: raw UTF-8, never
-- length-sliced, so multi-byte symbols in the payload survive transport.
--
-- Large sources are built in pieces (src.split + src.big). Each finished
-- piece is handed to the host right away through __PUSH, so no single string
-- ever holds the whole artifact and the page can assemble a blob. Streamed
-- builds leave `code` empty and set "streamed": true in the JSON.

local function pct(s)
  s = tostring(s)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or
       (b >= 97 and b <= 122) or b == 32 or b == 46 or b == 95 or
       b == 45 or b == 47 or b == 58 or b == 44 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = string.format("%%%02X", b)
    end
  end
  return table.concat(out)
end

local function q(s) return '"' .. pct(s) .. '"' end
local function num(v) return string.format("%.0f", math.floor(tonumber(v) or 0)) end
local function bool(v) return v and "true" or "false" end

local function finish(status, json, code)
  json = json or ""
  return table.concat({ status, tostring(#json), json, code or "" },
    string.char(1))
end

local function errorsJson(errs)
  local parts = {}
  local count = #(errs or {})
  if count > 20 then count = 20 end
  for i = 1, count do
    local e = errs[i]
    parts[#parts + 1] = '{"line":' .. num(e.line) .. ',"col":' .. num(e.col) ..
      ',"msg":' .. q(e.msg or "") .. '}'
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function statsJson(stats)
  if not stats then return "null" end
  return "{" ..
    '"bytes":' .. num(stats.bytes) ..
    ',"protos":' .. num(stats.protos) ..
    ',"instructions":' .. num(stats.instructions) ..
    ',"opcodes":' .. num(stats.opcodes) ..
    ',"aliases":' .. num(stats.aliases) ..
    ',"decoys":' .. num(stats.decoys) ..
    ',"payload":' .. num(stats.payloadBytes) ..
    ',"intPeriod":' .. num(stats.integrityPeriod) ..
    ',"smBlocks":' .. num(stats.selfmodBlocks) ..
    ',"smProtos":' .. num(stats.selfmodProtos) ..
    ',"adProbes":' .. num(stats.antidebugProbes) ..
    "}"
end

local RUN_LIMIT = 24000

-- Brand header. A block comment keeps the artifact a single physical line
-- (the loader pipeline never needs a newline), and it still opens with `--`
-- exactly as asked. It is added last, after the minifier, so compact() can
-- never drop it.
local BANNER = "--[[ This, File Protected By Claxfuscator V0.2 https://discord.gg/cHawU8Wmzj ]] "

local function runJson(run)
  if not run then return "null" end
  local output = run.output or ""
  local truncated = false
  if #output > RUN_LIMIT then
    output = output:sub(1, RUN_LIMIT) ..
      "\n... [" .. tostring(#run.output - RUN_LIMIT) .. " B kirpildi]"
    truncated = true
  end
  return "{" ..
    '"ok":' .. bool(run.ok) ..
    ',"stage":' .. q(run.stage or "") ..
    ',"output":' .. q(output) ..
    ',"truncated":' .. bool(truncated) ..
    ',"error":' .. q(run.error or "") ..
    ',"steps":' .. num(run.steps) ..
    ',"elapsed":' .. num(run.elapsed) ..
    "}"
end

local function attemptsJson(list)
  local parts = {}
  for i = 1, #(list or {}) do
    local a = list[i]
    parts[#parts + 1] = "{" ..
      '"index":' .. num(a.index) ..
      ',"label":' .. q(a.label or "") ..
      ',"preset":' .. q(a.preset or "") ..
      ',"ok":' .. bool(a.ok) ..
      ',"match":' .. bool(a.match) ..
      ',"reason":' .. q(a.reason or a.stage or "") ..
      ',"ms":' .. num(a.ms) ..
      "}"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local NUM_STATS = {
  "bytes", "protos", "instructions", "opcodes", "aliases", "decoys",
  "payloadBytes", "integrityPeriod", "selfmodBlocks", "selfmodProtos",
  "antidebugProbes",
}

local function addStats(acc, stats)
  if not stats then return acc end
  for i = 1, #NUM_STATS do
    local key = NUM_STATS[i]
    acc[key] = (acc[key] or 0) + (tonumber(stats[key]) or 0)
  end
  return acc
end

local function buildJson(result, ms, extra)
  return "{" ..
    '"kind":"build",' ..
    '"ok":' .. bool(result.ok) ..
    ',"stage":' .. q(result.stage or "") ..
    ',"seed":' .. num(result.seed) ..
    ',"preset":' .. q(result.preset or "") ..
    ',"errors":' .. errorsJson(result.errors) ..
    ',"stats":' .. statsJson(result.stats) ..
    ',"selfmod":' .. bool(result.selfmod) ..
    ',"antidebug":' .. bool(result.antidebug) ..
    ',"integrity":' .. bool(result.integrity) ..
    (extra or "") ..
    ',"ms":' .. num(ms) ..
    "}"
end

local function checkJson(check)
  return "{" ..
    '"kind":"run",' ..
    '"ok":' .. bool(check.ok) ..
    ',"verified":' .. bool(check.verified) ..
    ',"reason":' .. q(check.reason or "") ..
    ',"note":' .. q(check.note or "") ..
    ',"source":' .. runJson(check.reference) ..
    ',"obfuscated":' .. runJson(check.candidate) ..
    "}"
end

local function fixJson(result)
  return "{" ..
    '"kind":"fix",' ..
    '"ok":' .. bool(result.ok) ..
    ',"stage":' .. q(result.stage or "") ..
    ',"verified":' .. bool(result.verified) ..
    ',"note":' .. q(result.note or "") ..
    ',"seed":' .. num(result.seed) ..
    ',"preset":' .. q(result.preset or "") ..
    ',"stats":' .. statsJson(result.stats) ..
    ',"selfmod":' .. bool(result.selfmod) ..
    ',"antidebug":' .. bool(result.antidebug) ..
    ',"integrity":' .. bool(result.integrity) ..
    ',"attempts":' .. attemptsJson(result.attempts) ..
    ',"source":' .. runJson(result.reference) ..
    ',"obfuscated":' .. runJson(result.run) ..
    ',"errors":' .. errorsJson(result.errors) ..
    ',"ms":' .. num(result.ms) ..
    "}"
end

local function buildOptions(base, override)
  local o = {
    preset = base.preset, seed = base.seed,
    flatten = base.flatten, opaque = base.opaque,
    selfmod = base.selfmod, antidebug = base.antidebug,
    integrity = base.integrity, executor = base.executor,
    gethui = base.gethui, antiwebhook = base.antiwebhook,
  }
  if override then
    o.flatten = override.flatten
    o.opaque = override.opaque
  end
  return o
end

-- The compact engine exists so a throwaway snippet (`print("h")`) does not
-- carry the full randomized runtime: the VM pipeline ships a fixed handler
-- table by design, which is worth it for real scripts but dwarfs a one-liner.
-- The older compact VM is far cheaper to reverse, so it is reserved for
-- snippets only: anything a user would call a script goes through the strong
-- pipeline. A 1 KB threshold still covers pasted examples and tests while
-- keeping paid/production code off the weak engine.
local COMPACT_MAX = 1024
-- If the strong front end rejects a file, the compact parser is only a last
-- resort for snippets. Silently downgrading a real script to the cheap engine
-- is worse than surfacing the parse failure, so this stays tiny.
local COMPACT_FALLBACK_MAX = 4096

local function formatCode(result)
  if result.ok and type(result.code) == "string" and result.code ~= "" then
    result.code = require("v1.src.util").compact(result.code)
    if result.code:sub(1, #BANNER) ~= BANNER then
      result.code = BANNER .. result.code
    end
    if result.stats then result.stats.bytes = #result.code end
  end
  return result
end

-- The delivered file must not be readable Lua: cut it into blocks, pack,
-- encrypt and hide it behind a loader stub. An artifact past the seal ceiling
-- fails the build instead of being shipped with a protected banner over
-- readable source.
local function sealCode(result)
  if result.ok and type(result.code) == "string" and result.code ~= "" then
    local ok, sealed, err = pcall(function()
      return require("src.seal").wrap(result.code, result.seed)
    end)
    if not ok then sealed, err = nil, sealed end
    if not sealed then
      result.ok = false
      result.stage = "seal"
      result.code = ""
      result.errors = { { line = 0, msg = tostring(err or "seal failed") } }
      return result
    end
    result.code = sealed
    if result.stats then result.stats.bytes = #result.code end
  end
  return result
end

-- Dead-code injection is the only random size multiplier in this path, and a
-- lucky roll could push a tiny snippet past the 17 KB compact ceiling. The
-- whole chain is reseeded per attempt, so a lighter density replays the same
-- build with strictly less padding.
local COMPACT_CEILING = 16900

local function compactBuild(src, seed)
  local Parser = require("v1.src.parser")
  local T = require("v1.src.transforms")
  local Resolver = require("v1.src.resolver")
  local Compiler = require("v1.src.compiler")
  local VMGen = require("v1.src.vmgen")
  local U = require("v1.src.util")

  local function attempt(density)
    local result = {
      ok = false, stage = "parse", seed = seed, preset = "compact",
      code = "", errors = {}, selfmod = false, antidebug = false,
      integrity = false,
    }
    U.seed(seed)
    local ast, parseErrors = Parser.parse(src, "input.lua")
    if not ast or #parseErrors > 0 then
      result.errors = parseErrors
      return result
    end
    T.deadcode(ast, { density = density })
    local resolved = Resolver.resolve(ast)
    if #resolved.errors > 0 then
      result.stage, result.errors = "scope", resolved.errors
      return result
    end
    local compiled = Compiler.compile(resolved, {})
    if #compiled.errors > 0 then
      result.stage, result.errors = "compile", compiled.errors
      return result
    end
    local ok, code, stats = pcall(VMGen.generate, compiled,
      { seed = seed, decoys = 36 })
    if not ok then
      result.stage = "emit"
      result.errors = { { line = 0, col = 0, msg = tostring(code) } }
      return result
    end
    result.ok, result.stage, result.code, result.stats = true, "done", code, stats
    result.integrity = true
    return formatCode(result)
  end

  local result
  for _, density in ipairs({ 3, 1, 0 }) do
    result = attempt(density)
    if not result.ok or #result.code <= COMPACT_CEILING then break end
  end
  return result
end

local ok, frame = pcall(function()
  local Obfuscate = require("src.obfuscate")
  local Big = require("src.big")
  local Split = require("src.split")

  -- Drop the two source-level multipliers when they would make the build crawl.
  local function tuneCost(opts, text)
    if opts.flatten == false then return opts end
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end
    if #text > Big.FLATTEN_MAX or
       (#text > Big.DENSE_BYTES and lines < Big.DENSE_LINES) then
      opts.flatten = false
      opts.opaque = false
    end
    return opts
  end

  local maxSteps = tonumber(__MAXSTEPS) or 400000000
  local seconds = tonumber(__SECONDS) or 12
  local stepChunk = tonumber(__STEPCHUNK) or 250000
  local seed = tonumber(__SEED)
  if seed ~= nil and seed < 0 then seed = nil end
  -- A split build derives every piece seed from this base, so leaving it nil
  -- would make each piece fall back to 0 + index and repeat the same opcode
  -- keys on every build of the same file.
  if seed == nil then seed = math.floor(math.random() * 4294967296) % 4294967296 end
  local sandbox = { maxSteps = maxSteps, seconds = seconds, stepChunk = stepChunk }

  local action = tostring(__ACTION or "")
  if action == "build" then
    local bopts = { preset = __PRESET, seed = seed }
    if __FLATTEN ~= nil then bopts.flatten = __FLATTEN == 1 end
    if __OPAQUE ~= nil then bopts.opaque = __OPAQUE == 1 end
    if __SELFMOD ~= nil then bopts.selfmod = __SELFMOD == 1 end
    if __ANTIDEBUG ~= nil then bopts.antidebug = __ANTIDEBUG == 1 end
    if __INTEGRITY ~= nil then bopts.integrity = __INTEGRITY == 1 end
    if __EXECUTOR ~= nil then bopts.executor = __EXECUTOR == 1 end
    if __GETHUI ~= nil then bopts.gethui = __GETHUI == 1 end
    if __ANTIWEBHOOK ~= nil then bopts.antiwebhook = __ANTIWEBHOOK == 1 end

    local src = tostring(__SRC or "")
    local t0 = os.clock()
    local engine = tostring(__ENGINE or "auto")
    if engine ~= "vm" and #src <= COMPACT_MAX then
      local result = compactBuild(src, seed)
      if result.ok then
        sealCode(result)
        local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
        return finish("OK", buildJson(result, ms,
          ',"engine":"compact"'),
          result.code)
      end
      -- A construct the compact parser cannot read still deserves a build; the
      -- VM pipeline below has the wider front end and reports its own errors.
    end
    local plan = Big.choose(#src)
    local splitPlan = nil
    if plan then
      local attempt = Split.run(src, { chunkBytes = plan.chunkBytes })
      if not attempt.unsafe and #attempt.chunks > 1 then splitPlan = attempt end
    end

    if not splitPlan then
      -- One piece: either it fits the budget or the file uses constructs that
      -- forbid piecewise rewriting (top-level goto/labels, attributed locals).
      local opts = tuneCost(buildOptions(bopts, plan), src)
      local result = Obfuscate.run(src, opts)
      if not result.ok and engine ~= "vm" and #src <= COMPACT_FALLBACK_MAX then
        local fallback = compactBuild(src, seed)
        if fallback.ok then
          sealCode(fallback)
          local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
          return finish("OK", buildJson(fallback, ms,
            ',"engine":"compact","fallback":true'), fallback.code)
        end
      end
      formatCode(result)
      sealCode(result)
      local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
      return finish(result.ok and "OK" or "FAIL",
        buildJson(result, ms, ',"engine":"vm"'), result.code)
    end

    local total = #splitPlan.chunks
    local push = __PUSH
    if push == nil then push = function() end end
    local step = __STEP
    if step == nil then step = function() end end

    local compact = require("v1.src.util").compact
    local Seal = require("src.seal")
    local header, footer = compact(Big.header()), compact(Big.footer())
    -- Pieces stay inline inside the Big wrapper (they share its locals), and
    -- the assembled stream is sealed once at the end. Sealing per piece would
    -- cut each piece out of the wrapper's scope. The whole stream therefore
    -- has to sit in memory; past the seal ceiling the build stops with an
    -- error instead of handing the host the assembled program in the clear.
    local cap = Seal.MAX_BYTES
    local acc = { header .. " " }
    local accBytes = #header + 1
    local stats = {}
    local last = nil
    for i = 1, total do
      step(i, total)
      local piece = splitPlan.chunks[i]
      local opts = tuneCost(buildOptions(bopts, plan), piece.text)
      opts.seed = Big.seedFor(bopts.seed or 0, i)
      -- The stream is sealed as a whole, so a per-piece poison card would only
      -- double the file: the copy hanging off each piece is already ciphertext.
      opts.selfCopy = false
      local result = Obfuscate.run(piece.text, opts)
      if not result.ok then
        -- Chunk-relative line numbers become file lines for the error panel.
        local offset = (piece.line or 1) - 1
        for k = 1, #(result.errors or {}) do
          local e = result.errors[k]
          e.line = (tonumber(e.line) or 0) + offset
        end
        result.chunk = i
        result.chunks = total
        local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
        return finish("FAIL", buildJson(result, ms), "")
      end
      local body = compact(Big.open()) .. compact(result.code) ..
        compact(Big.close(i == total, piece.returns))
      accBytes = accBytes + #body + 1
      if accBytes > cap then
        local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
        local fail = {
          ok = false, stage = "seal", chunk = i, chunks = total,
          errors = { { line = piece.line or 0, msg =
            "assembled output exceeds the seal limit (" .. cap ..
              " bytes); raise Seal.MAX_BYTES or split the input" } },
        }
        return finish("FAIL", buildJson(fail, ms), "")
      end
      acc[#acc + 1] = body .. " "
      addStats(stats, result.stats)
      last = result
      body, result = nil, nil
      piece.text = nil
      splitPlan.chunks[i] = nil
      collectgarbage("collect")
    end
    acc[#acc + 1] = footer
    local sealed, sealErr = Seal.wrap(BANNER .. table.concat(acc), bopts.seed or seed)
    if not sealed then
      local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
      local fail = { ok = false, stage = "seal", chunks = total,
        errors = { { line = 0, msg = tostring(sealErr or "seal failed") } } }
      return finish("FAIL", buildJson(fail, ms), "")
    end
    acc = nil
    collectgarbage("collect")
    push(sealed)
    local bytes = #sealed
    stats.bytes = bytes
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    local extra = ',"streamed":true' ..
      ',"bytes":' .. num(bytes) ..
      ',"chunks":' .. num(total) ..
      ',"engine":"vm"'
    local result = {
      ok = true, stage = "done", seed = bopts.seed or 0,
      preset = bopts.preset, code = "",
      errors = {}, stats = stats,
      selfmod = last and last.selfmod, antidebug = last and last.antidebug,
      integrity = last and last.integrity,
    }
    return finish("OK", buildJson(result, ms, extra), "")
  end

  if action == "run" then
    if tostring(__CODE or "") == "" then
      return finish("EMPTY", '{"kind":"run","ok":false,"reason":"no-code"}')
    end
    local Autofix = require("src.autofix")
    local check = Autofix.verify(__SRC, __CODE, sandbox)
    return finish("OK", checkJson(check))
  end

  if action == "fix" then
    local Autofix = require("src.autofix")
    local result = Autofix.run(__SRC, {
      preset = __PRESET, seed = seed,
      maxSteps = maxSteps, seconds = seconds, stepChunk = stepChunk,
      executor = __EXECUTOR == 1, gethui = __GETHUI == 1,
      antiwebhook = __ANTIWEBHOOK == 1,
    })
    formatCode(result)
    sealCode(result)
    return finish(result.ok and "OK" or "FAIL", fixJson(result), result.code)
  end

  return finish("BAD", '{"kind":"error","msg":' .. q("unknown action") .. "}")
end)

if not ok then
  return finish("CRASH", '{"kind":"error","msg":' .. q(tostring(frame)) .. "}")
end
return frame
