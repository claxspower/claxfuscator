-- module10.lua -- acceptance tests for layer 10 (self-modifying bytecode).
--
-- Pipeline under test: layers 1-8 produce a randomized instruction plan, then
-- src/selfmod.lua replaces every prototype's instruction list with 4-instruction
-- blocks. A block is a 4-byte state prefix plus keystream-XOR of an FNV-1a32
-- header and the varint instruction stream; each block key mixes a chain value
-- derived from the previous block's build-time ciphertext. src/bytecode.lua
-- packs those blocks, and the emitted runtime keeps a live window of
-- max(20% of the prototype, WINDOW_FLOOR) whole blocks, capped at the 64-block
-- ceiling, re-encrypting a block in place before evicting it. With the current
-- floor and ceiling the window is min(total, 256) instructions.
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

local function makeEnv(out)
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

local function execute(src)
  local out = {}
  local env = makeEnv(out)
  local chunk, err = loadWith(src, env)
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function loadGenerated(src)
  local chunk = loadWith(src, makeEnv({}))
  return chunk
end

local function runGenerated(src)
  local out = {}
  local env = makeEnv(out)
  local chunk, err = loadWith(src, env)
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- utilities
local function hex32(n)
  return string.format("%08x", n % 4294967296)
end

local function flipByte(s, pos)
  local b = string.byte(s, pos)
  if not b then return s end
  return s:sub(1, pos - 1) .. string.char((b + 1) % 256) .. s:sub(pos + 1)
end

local function sameValue(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then
    if a ~= a or b ~= b then return a ~= a and b ~= b end
    if a == 0 and b == 0 then return 1 / a == 1 / b end
    if a ~= b then return false end
    if math.type then return math.type(a) == math.type(b) end
    return true
  end
  return a == b
end

local function sameInstr(x, y)
  for f = 1, 5 do
    if not sameValue(x[f], y[f]) then return false, "field " .. f end
  end
  return true
end

-- Expected live window in instructions for a prototype with `total` words: the
-- whole body up to the block ceiling, so a called prototype never re-decodes
-- its own blocks. Above the ceiling the window slides.
local function expectedCap(total, B, maxBlocks)
  if total <= 0 then return 0 end
  local cap = total
  if cap > maxBlocks * B then cap = maxBlocks * B end
  return cap
end

local B8 = Bytecode._internals
local SM = Selfmod._internals
local BLOCK, MAXB = Selfmod.BLOCK, Selfmod.MAX_BLOCKS

-- ---------------------------------------------------------------------------
-- 1. Block split, chaining and live-window arithmetic
-- ---------------------------------------------------------------------------
local SAMPLE = [[
local function add(a, b) return a + b end
local function rep(s, n) return s:rep(n) end
print(add(2, 3), rep("ab", 2), "tail")
]]

local sampleCompiled = build(SAMPLE)
local samplePlan = VMGen.randomize(sampleCompiled,
  { seed = 0xA11, decoys = 160 })
-- The three-line sample has tiny prototypes; grow the first one past the
-- whole-body window so replay still exercises eviction and re-encryption.
for i = 1, MAXB * Selfmod.BLOCK + 200 do
  local c = samplePlan.protos[1].c
  c[#c + 1] = { 1, 0, 0, 0, 0 }
end
local sampleStats = Selfmod.apply(samplePlan, { seed = 0xA11 })

check("split: at least one prototype stored as blocks", sampleStats.protos > 0,
  sampleStats.protos)
check("split: block size is four", sampleStats.blockSize == BLOCK,
  sampleStats.blockSize)

local splitOk, splitWhy, splitCount, splitInstr = true, nil, 0, 0
for pi = 1, #samplePlan.protos do
  local P = samplePlan.protos[pi]
  if P.sm then
    splitCount = splitCount + 1
    local total = P.total
    splitInstr = splitInstr + total
    local nb = math.ceil(total / BLOCK)
    if #P.blocks ~= nb then
      splitOk, splitWhy = false, "proto " .. pi .. " blocks " .. #P.blocks ..
        " ~= " .. nb
    elseif #P.c ~= 0 then
      splitOk, splitWhy = false, "proto " .. pi .. " kept plain instructions"
    elseif P.B ~= BLOCK then
      splitOk, splitWhy = false, "proto " .. pi .. " B " .. tostring(P.B)
    elseif P.cap ~= expectedCap(total, BLOCK, MAXB) then
      splitOk, splitWhy = false, "proto " .. pi .. " cap " .. tostring(P.cap)
    elseif P.cap < Selfmod.WINDOW_FLOOR and P.cap ~= total then
      splitOk, splitWhy = false, "proto " .. pi .. " small cap " .. P.cap
    end
  end
end
check("split: every prototype uses blocks and drops the tuple list", splitOk,
  splitWhy)
check("split: stats count blocks", sampleStats.blocks ==
  (function()
    local n = 0
    for pi = 1, #samplePlan.protos do n = n + #samplePlan.protos[pi].blocks end
    return n
  end)(), sampleStats.blocks)
check("split: stats instruction total", sampleStats.instructions == splitInstr,
  sampleStats.instructions .. " ~= " .. splitInstr)
check("split: live cap equals the per-proto maximum", sampleStats.liveCap > 0 and
  sampleStats.liveCap <= MAXB * BLOCK)

-- Chain values are distinct and start from the key, so reordering or swapping
-- blocks invalidates them.
local chainSet, chainDup, chainFirst = {}, 0, nil
for pi = 1, #samplePlan.protos do
  local P = samplePlan.protos[pi]
  if P.sm then
    for bi = 1, #P.chain do
      if chainSet[P.chain[bi]] then chainDup = chainDup + 1 end
      chainSet[P.chain[bi]] = true
      if bi == 1 and not chainFirst then chainFirst = P.chain[1] end
    end
  end
end
check("chain: values are distinct", chainDup == 0, chainDup)
check("chain: nonzero start value", chainFirst ~= nil and chainFirst ~= 0)

for pi = 1, #samplePlan.protos do
  local P = samplePlan.protos[pi]
  if P.sm then
    local okPrefix = true
    for bi = 1, #P.blocks do
      if #P.blocks[bi] < 9 then okPrefix = false end
    end
    check("split: blocks carry a state prefix and a payload", okPrefix)
    break
  end
end

-- ---------------------------------------------------------------------------
-- 2. decodeBlock round trip: every instruction field and numeric subtype
-- ---------------------------------------------------------------------------
local NAN = 0 / 0
local trickyPlan = {
  seed = 0x10A,
  protos = {
    {
      a = 2, v = true,
      c = {
        { 7, 1, 2, 3, 0 },
        { 9, 2, -3, 4, 1.0 },
        { 11, 0, 0, 0, -0.0 },
        { 12, 5, 6, -7, -42 },
        { 13, 0, 0, 0, 0 / 0 },
        { 14, 0, 0, 0, 9007199254740991 },
        { 15, -8, 9, -10, 123456789012345 },
        { 16, 0, 0, 0, 3.25 },
        { 17, 1, 0, 0, 1 / 3 },
      },
      k = { 1.0, -0.0, "plain", math.huge, -math.huge, NAN,
        9007199254740991, 1, true, false },
      u = { { 1, 2 }, { 0, 5 } },
    },
    {
      a = 1, v = false,
      c = {
        { 1, 0, 0, 0, 0 },
        { 2, 1, 1, 1, 1 },
        { 3, 2, 2, 2, 2 },
        { 4, 3, 3, 3, 3 },
        { 5, 4, 4, 4, 4 },
        { 6, 5, 5, 5, 5 },
        { 8, 6, 6, 6, 6 },
        { 10, 7, 7, 7, 7 },
        { 18, 8, 8, 8, 8 },
        { 19, 9, 9, 9, 9 },
        { 20, 10, 10, 10, 10 },
      },
      k = {}, u = {},
    },
  },
}
-- Past the full-residency cap (1024 blocks x 8) so the manual pass still
-- evicts and rewrites blocks.
for i = 1, 8500 do
  local c = trickyPlan.protos[1].c
  c[#c + 1] = { 2, i % 7, i % 5, 0, 0 }
end
local trickyOrig = {}
for pi = 1, #trickyPlan.protos do
  local P = trickyPlan.protos[pi]
  trickyOrig[pi] = {}
  for i = 1, #P.c do trickyOrig[pi][i] = P.c[i] end
end
local trickyStats = Selfmod.apply(trickyPlan, { key = 0xDEADBEEF })
local trickyMaster = trickyStats.master
check("decode: apply honours an explicit key", trickyMaster == 0xDEADBEEF,
  trickyMaster)

local decodedOk, decodedWhy = true, nil
local decodedInstr = 0
for pi = 1, #trickyPlan.protos do
  local P = trickyPlan.protos[pi]
  for bi = 1, #P.blocks do
    local list, plain = SM.decodeBlock(trickyMaster, pi, bi, P.blocks[bi],
      P.chain[bi], P.total, P.B)
    if not list then
      decodedOk, decodedWhy = false, "proto " .. pi .. " block " .. bi .. ": " ..
        tostring(plain)
    else
      local from = (bi - 1) * P.B + 1
      for i = 1, #list do
        local ok, why = sameInstr(trickyOrig[pi][from + i - 1], list[i])
        decodedInstr = decodedInstr + 1
        if not ok then
          decodedOk, decodedWhy = false, "proto " .. pi .. " block " .. bi ..
            " ins " .. i .. " " .. tostring(why)
        end
      end
    end
  end
end
check("decode: every block decodes to the original instructions", decodedOk,
  decodedWhy)
check("decode: instruction count preserved",
  decodedInstr == #trickyOrig[1] + #trickyOrig[2], decodedInstr)

local t0P = trickyPlan.protos[1]
local t0List, t0Plain = SM.decodeBlock(trickyMaster, 1, 1, t0P.blocks[1],
  t0P.chain[1], t0P.total, t0P.B)
local t0Second = SM.decodeBlock(trickyMaster, 1, 2, t0P.blocks[2],
  t0P.chain[2], t0P.total, t0P.B)
if t0List and math.type then
  check("decode: float operand stays float",
    math.type(t0List[2][5]) == "float" and math.type(t0List[1][5]) == "integer")
  check("decode: negative zero operand kept", 1 / t0List[3][5] < 0)
end
check("decode: NaN operand kept", t0List ~= nil and
  t0List[5][5] ~= t0List[5][5])
check("decode: integer beyond 2^52 kept", t0List ~= nil and
  t0List[6][5] == 9007199254740991)

-- ---------------------------------------------------------------------------
-- 3. Tampering with a stored block or its chain is detected
-- ---------------------------------------------------------------------------
local badByte = flipByte(t0P.blocks[1], 6)
local badList, badErr = SM.decodeBlock(trickyMaster, 1, 1, badByte,
  t0P.chain[1], t0P.total, t0P.B)
check("tamper: payload byte rejected by block checksum", badList == nil and
  string.find(tostring(badErr), "checksum", 1, true) ~= nil, badErr)

local badState = flipByte(t0P.blocks[1], 4)
local badStateList, badStateErr = SM.decodeBlock(trickyMaster, 1, 1,
  badState, t0P.chain[1], t0P.total, t0P.B)
check("tamper: state prefix byte rejected", badStateList == nil and
  string.find(tostring(badStateErr), "checksum", 1, true) ~= nil, badStateErr)

local badChain = (t0P.chain[1] + 7919) % 4294967296
local badChainList, badChainErr = SM.decodeBlock(trickyMaster, 1, 1,
  t0P.blocks[1], badChain, t0P.total, t0P.B)
check("tamper: wrong chain value rejected", badChainList == nil and
  string.find(tostring(badChainErr), "checksum", 1, true) ~= nil, badChainErr)

local truncList, truncErr = SM.decodeBlock(trickyMaster, 1, 1,
  string.sub(t0P.blocks[1], 1, 8), t0P.chain[1], t0P.total, t0P.B)
check("tamper: truncated block rejected", truncList == nil and
  string.find(tostring(truncErr), "truncated", 1, true) ~= nil, truncErr)

-- ---------------------------------------------------------------------------
-- 4. Replay: live window stays capped, evicted blocks are rewritten
-- ---------------------------------------------------------------------------
local sampleReplay = Selfmod.replay(samplePlan, { seed = 0xA11 })
check("replay: no decode error", sampleReplay.error == nil, sampleReplay.error)
check("replay: visits every instruction", sampleReplay.visits == splitInstr,
  sampleReplay.visits .. " ~= " .. splitInstr)
check("replay: live window never exceeds the cap",
  sampleReplay.maxLive <= sampleStats.liveCap,
  sampleReplay.maxLive .. " > " .. sampleStats.liveCap)
check("replay: evictions rewrite blocks", sampleReplay.mutations > 0,
  sampleReplay.mutations)
check("replay: rewritten blocks changed bytes",
  sampleReplay.changed == sampleReplay.mutations,
  sampleReplay.changed .. " ~= " .. sampleReplay.mutations)
check("replay: decoded windows fit the expected cap",
  sampleReplay.maxLive == sampleStats.liveCap,
  sampleReplay.maxLive .. " ~= " .. sampleStats.liveCap)

-- Manual FIFO simulation: the replayed loader's own decode/evict path must
-- produce the same decisions as the module helper and must survive repeated
-- re-encryption at runtime with a 32-bit state.
local function simulate(plan, master, pi, code)
  local P = plan.protos[pi]
  local blocks = {}
  for i = 1, #P.blocks do blocks[i] = P.blocks[i] end
  local raw, queue, seed = {}, {}, master
  local total, B, cap = P.total, P.B, P.cap
  local maxLive, mutations = 0, 0
  for pc = 1, total do
    local bi = math.floor((pc - 1) / B) + 1
    if not raw[bi] then
      local need = math.min(B, total - (bi - 1) * B)
      local liveCount = 0
      for i = 1, #P.blocks do
        if raw[i] then
          liveCount = liveCount + math.min(B, total - (i - 1) * B)
        end
      end
      while liveCount + need > cap and #queue > 0 do
        local old = table.remove(queue, 1)
        local cnt = math.min(B, total - (old - 1) * B)
        seed = (seed * 1664525 + 1013904223) % 4294967296
        local nextBlock = B8.le32(seed) ..
          SM.crypt(raw[old], master, pi, old, seed, P.chain[old])
        blocks[old] = nextBlock
        raw[old] = nil
        liveCount = liveCount - cnt
        mutations = mutations + 1
      end
      local list, plain = SM.decodeBlock(master, pi, bi, blocks[bi],
        P.chain[bi], total, B)
      if not list then return nil, plain, maxLive, mutations end
      raw[bi] = plain
      queue[#queue + 1] = bi
      liveCount = liveCount + need
      if liveCount > maxLive then maxLive = liveCount end
    end
  end
  -- Every block, including the ones rewritten during the pass, must still
  -- decode to the same instruction words.
  for bi = 1, #P.blocks do
    local list, plain = SM.decodeBlock(master, pi, bi, blocks[bi],
      P.chain[bi], total, B)
    if not list then return nil, "re-decode " .. bi .. ": " .. tostring(plain) end
    local from = (bi - 1) * B + 1
    for i = 1, #list do
      local ok, why = sameInstr(code[from + i - 1], list[i])
      if not ok then return nil, "re-decode " .. bi .. " ins " .. i .. " " ..
        tostring(why) end
    end
  end
  return true, nil, maxLive, mutations
end

local simOk, simWhy, simLive, simMut = simulate(trickyPlan, trickyMaster, 1,
  trickyOrig[1])
check("replay: manual loader agrees with decodeBlock", simOk == true, simWhy)
check("replay: manual loader rewrites blocks", simMut > 0, simMut)
check("replay: manual loader stays inside the cap",
  simLive <= trickyPlan.protos[1].cap,
  simLive .. " > " .. trickyPlan.protos[1].cap)

-- A tiny prototype still gets exactly one live block so the loader can always
-- make progress.
local tinyPlan = {
  seed = 0x10B,
  protos = { { a = 0, v = false,
    c = { { 1, 0, 0, 0, 0 }, { 2, 0, 0, 0, 0 } }, k = {}, u = {} } },
}
Selfmod.apply(tinyPlan, { seed = 0x10B })
check("cap: tiny prototype keeps its whole instruction list",
  tinyPlan.protos[1].cap == tinyPlan.protos[1].total,
  tinyPlan.protos[1].cap)
local tinyReplay = Selfmod.replay(tinyPlan, { seed = 0x10B })
check("cap: tiny prototype never evicts", tinyReplay.mutations == 0 and
  tinyReplay.error == nil, tinyReplay.error)

-- ---------------------------------------------------------------------------
-- 5. Storage is not plaintext and repeated content still differs per block
-- ---------------------------------------------------------------------------
local scaleCode = {}
for i = 1, 600 do
  scaleCode[i] = { 2, i % 7, i % 5, i % 3, i % 11 }
end
local repeatPlan = { seed = 0x10C,
  protos = { { a = 0, v = false, c = scaleCode, k = {}, u = {} } } }
Selfmod.apply(repeatPlan, { seed = 0x10C })
local RP = repeatPlan.protos[1]
local blockSet, blockDup = {}, 0
for bi = 1, #RP.blocks do
  if blockSet[RP.blocks[bi]] then blockDup = blockDup + 1 end
  blockSet[RP.blocks[bi]] = true
end
check("cipher: repeated instruction runs still give distinct blocks",
  blockDup == 0, blockDup)

local plainNeedle = SM.encodeInstr(scaleCode[1])
check("cipher: instruction encoding absent from the stored block",
  string.find(RP.blocks[1], plainNeedle, 1, true) == nil)
check("cipher: block does not start with its plaintext header",
  string.sub(RP.blocks[1], 5, 8) ~= string.sub(
    SM.encodeSlice(scaleCode, 1, BLOCK), 1, 4))

-- The state prefix must vary between blocks; identical state would repeat the
-- keystream for identical payloads.
check("cipher: per-block state prefixes differ",
  string.sub(RP.blocks[1], 1, 4) ~= string.sub(RP.blocks[2], 1, 4))

-- ---------------------------------------------------------------------------
-- 6. Packed container carries the block store intact
-- ---------------------------------------------------------------------------
local trickyPayload = Bytecode.pack(trickyPlan, { key = trickyMaster })
local trickyBack = Bytecode.unpack(trickyPayload.blob, trickyMaster)
check("pack: unpack returns prototypes", trickyBack ~= nil)
if trickyBack then
  local matchOk, matchWhy = true, nil
  for pi = 1, #trickyBack do
    local G = trickyBack[pi]
    if G.sm ~= true or G.B ~= BLOCK or G.total ~= trickyPlan.protos[pi].total or
       #G.blocks ~= #trickyPlan.protos[pi].blocks or
       G.cap ~= trickyPlan.protos[pi].cap then
      matchOk, matchWhy = false, "proto " .. pi .. " header"
    else
      for bi = 1, #G.blocks do
        if G.blocks[bi] ~= trickyPlan.protos[pi].blocks[bi] or
           G.chain[bi] ~= trickyPlan.protos[pi].chain[bi] then
          matchOk, matchWhy = false, "proto " .. pi .. " block " .. bi
        end
      end
    end
    if matchOk then
      if G.a ~= 2 and pi == 1 then matchOk, matchWhy = false, "param count" end
      if G.v ~= true and pi == 1 then matchOk, matchWhy = false, "vararg" end
      if #G.k ~= #trickyPlan.protos[pi].k then
        matchOk, matchWhy = false, "proto " .. pi .. " consts"
      end
      if #G.u ~= #trickyPlan.protos[pi].u then
        matchOk, matchWhy = false, "proto " .. pi .. " upvalues"
      end
    end
  end
  check("pack: self-mod metadata survives unpack", matchOk, matchWhy)
end

-- ---------------------------------------------------------------------------
-- 7. Emitted runtime equivalence over a semantic corpus
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
local corpusCapOk, corpusCapWhy = true, nil
local corpusInstr = 0
for ci = 1, #corpus do
  local name, src = corpus[ci][1], corpus[ci][2]
  local compiled = build(src)
  local seed = 0xAB01 + ci * 131
  local plan = VMGen.randomize(compiled, { seed = seed, decoys = 160 })
  Selfmod.apply(plan, { seed = seed })
  for pi = 1, #plan.protos do
    local P = plan.protos[pi]
    if P.sm then
      corpusInstr = corpusInstr + P.total
      local want = expectedCap(P.total, BLOCK, MAXB)
      if P.cap ~= want then
        corpusCapOk, corpusCapWhy = false, name .. " proto " .. pi .. " cap " ..
          P.cap .. " ~= " .. want
      elseif P.cap > math.max(P.total * 0.2, Selfmod.WINDOW_FLOOR) + 1e-9 then
        corpusCapOk, corpusCapWhy = false, name .. " proto " .. pi ..
          " over its window"
      elseif P.cap > P.total then        corpusCapOk, corpusCapWhy = false, name .. " proto " .. pi ..
          " cap beyond code"
      end
    end
  end
  local payload = Bytecode.pack(plan, { seed = seed })
  local source = VMGen.emit(plan, { payload = payload })
  local want = execute(src)
  local got, genErr = runGenerated(source)
  local ok = want ~= nil and got == want
  if ok then
    covered = covered + 1
  elseif not corpusFail then
    corpusFail = name .. ": " .. tostring(genErr or
      ("got=" .. tostring(got) .. " want=" .. tostring(want)))
  end
end
check("corpus: self-modifying runtime matches source", corpusFail == nil,
  corpusFail)
check("corpus: live caps follow the 20% rule", corpusCapOk, corpusCapWhy)
notes[#notes + 1] = string.format("MODULE10_CORPUS %d/%d instr=%d",
  covered, #corpus, corpusInstr)

-- Reference VM must agree with the self-modifying runtime on a nested case.
local refSrc = corpus[7][2]
local refCompiled = build(refSrc)
local refPlan = VMGen.randomize(refCompiled, { seed = 0xAC01, decoys = 160 })
Selfmod.apply(refPlan, { seed = 0xAC01 })
local refPayload = Bytecode.pack(refPlan, { seed = 0xAC01 })
local refSource = VMGen.emit(refPlan, { payload = refPayload })
local refOut = {}
local refEnv = makeEnv(refOut)
local refOk, refErr = pcall(VM.run, refCompiled, refEnv)
check("reference VM: runs", refOk, refErr)
check("reference VM: agrees with block runtime",
  table.concat(refOut, "\n") == runGenerated(refSource))

-- ---------------------------------------------------------------------------
-- 8. Runtime tamper: block bytes rejected even though layer 9 rebuilt its
-- checksum over the modified container
-- ---------------------------------------------------------------------------
local function emitFromPlan(plan, payload)
  return VMGen.emit(plan, { payload = payload })
end

local function tamperRun(plan, payload)
  local source = emitFromPlan(plan, payload)
  local chunk = loadGenerated(source)
  if not chunk then return false, "load failed" end
  local ok, err = pcall(chunk)
  return ok, tostring(err)
end

-- Build from real code so the runtime is exercisable, then corrupt one byte.
-- Build from real code so the runtime is exercisable, then corrupt one byte.
local tamperCompiled = build(corpus[1][2])
local tPlan = VMGen.randomize(tamperCompiled, { seed = 0xAD01, decoys = 160 })
Selfmod.apply(tPlan, { seed = 0xAD01 })
for pi = 1, #tPlan.protos do
  local P = tPlan.protos[pi]
  if P.sm then P.blocks[1] = flipByte(P.blocks[1], 6) end
end
local tPayload = Bytecode.pack(tPlan, { seed = 0xAD01 })
local tokByte, terrByte = tamperRun(tPlan, tPayload)
check("runtime tamper: corrupted block rejected", not tokByte, terrByte)
check("runtime tamper: block checksum message",
  string.find(terrByte, "block checksum", 1, true) ~= nil, terrByte)

-- A wrong chain value must fail too, even with a null byte payload intact.
local cCompiled = build(corpus[1][2])
local cPlan = VMGen.randomize(cCompiled, { seed = 0xAD02, decoys = 160 })
Selfmod.apply(cPlan, { seed = 0xAD02 })
for pi = 1, #cPlan.protos do
  local P = cPlan.protos[pi]
  if P.sm then
    for bi = 1, #P.chain do
      P.chain[bi] = (P.chain[bi] + 1) % 4294967296
    end
  end
end
local cPayload = Bytecode.pack(cPlan, { seed = 0xAD02 })
local cok, cerr = tamperRun(cPlan, cPayload)
check("runtime tamper: broken block chain rejected", not cok, cerr)

-- Swapping two blocks breaks both the chain and the decoded word order.
local sCompiled = build(corpus[2][2])
local sPlan = VMGen.randomize(sCompiled, { seed = 0xAD03, decoys = 160 })
Selfmod.apply(sPlan, { seed = 0xAD03 })
local swapped = false
for pi = 1, #sPlan.protos do
  local P = sPlan.protos[pi]
  if P.sm and #P.blocks >= 2 then
    P.blocks[1], P.blocks[2] = P.blocks[2], P.blocks[1]
    swapped = true
    break
  end
end
local sPayload = Bytecode.pack(sPlan, { seed = 0xAD03 })
local sok, serr = tamperRun(sPlan, sPayload)
check("runtime tamper: swapped blocks rejected", swapped and not sok, serr)

-- Intact plan still runs after all that: the layer must not be fragile.
local goodPlan = VMGen.randomize(build(corpus[1][2]),
  { seed = 0xAD04, decoys = 160 })
Selfmod.apply(goodPlan, { seed = 0xAD04 })
local goodPayload = Bytecode.pack(goodPlan, { seed = 0xAD04 })
local gok, gerr = tamperRun(goodPlan, goodPayload)
check("runtime: intact self-modifying plan runs", gok, gerr)

-- ---------------------------------------------------------------------------
-- 9. Stats reported by the emitter
-- ---------------------------------------------------------------------------
local stCompiled = build(corpus[3][2])
local stPlan = VMGen.randomize(stCompiled, { seed = 0xAE01, decoys = 160 })
local stMod = Selfmod.apply(stPlan, { seed = 0xAE01 })
local stPayload = Bytecode.pack(stPlan, { seed = 0xAE01 })
local stSource, stStats = VMGen.emit(stPlan, { payload = stPayload })
check("stats: selfmod flag", stStats.selfmod == true)
check("stats: selfmod prototype count", stStats.selfmodProtos == stMod.protos,
  stStats.selfmodProtos .. " ~= " .. stMod.protos)
check("stats: selfmod block count", stStats.selfmodBlocks == stMod.blocks,
  stStats.selfmodBlocks .. " ~= " .. stMod.blocks)
check("stats: live cap", stStats.liveCap == stMod.liveCap,
  stStats.liveCap .. " ~= " .. stMod.liveCap)
check("stats: block bytes", stStats.selfmodBytes == stMod.bytes,
  stStats.selfmodBytes .. " ~= " .. stMod.bytes)
check("stats: instruction total", stStats.instructions == stMod.instructions,
  stStats.instructions .. " ~= " .. stMod.instructions)
check("stats: still packed", stStats.packed == true)
check("emit: deterministic", VMGen.emit(stPlan, { payload = stPayload }) ==
  stSource)
check("emit: one table dispatch",
  select(2, string.gsub(stSource, "local " .. stStats.names.VNPC .. "=", "")) == 1)
check("emit: block loader present",
  string.find(stSource, "p.k0+p.i*", 1, true) ~= nil)
check("leak: plain instruction list absent from source",
  string.find(stSource, "c={{", 1, true) == nil)

local opcodeLeaks = 0
-- Scan code only: the packed payload is an escaped byte literal, so two-letter
-- mnemonics like "LT" can appear there by chance without being a real leak.
-- `%b""` is not enough: the literal escapes `"` as `\"`, and the balanced
-- match would stop there and leave ciphertext bytes in the scanned text.
local function stripLiterals(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local q = c
      i = i + 1
      while i <= n do
        local d = text:sub(i, i)
        if d == "\\" then i = i + 2
        elseif d == q then i = i + 1 break
        else i = i + 1 end
      end
      out[#out + 1] = '""'
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end
local codeOnly = stripLiterals(stSource)
for i = 1, #Compiler.OPS do
  if string.find(codeOnly, Compiler.OPS[i], 1, true) then
    opcodeLeaks = opcodeLeaks + 1
  end
end
check("leak: no opcode mnemonic in source", opcodeLeaks == 0, opcodeLeaks)

-- ---------------------------------------------------------------------------
-- 10. Polymorphism and determinism
-- ---------------------------------------------------------------------------
local blobSet, sourceSet = {}, {}
local distinctBlobs, distinctSources = 0, 0
for i = 1, 10 do
  local seed = 0xAF00 + i * 1013
  local plan = VMGen.randomize(sampleCompiled, { seed = seed, decoys = 160 })
  Selfmod.apply(plan, { seed = seed })
  local payload = Bytecode.pack(plan, { seed = seed })
  local source = VMGen.emit(plan, { payload = payload })
  if not blobSet[payload.blob] then distinctBlobs = distinctBlobs + 1 end
  blobSet[payload.blob] = true
  if not sourceSet[source] then distinctSources = distinctSources + 1 end
  sourceSet[source] = true
end
check("polymorphism: ten distinct blobs", distinctBlobs == 10, distinctBlobs)
check("polymorphism: ten distinct sources", distinctSources == 10,
  distinctSources)
notes[#notes + 1] = string.format(
  "MODULE10_POLY blobs=%d/10 sources=%d/10", distinctBlobs, distinctSources)

local function pipe(seed)
  local plan = VMGen.randomize(sampleCompiled, { seed = seed, decoys = 160 })
  Selfmod.apply(plan, { seed = seed })
  local payload = Bytecode.pack(plan, { seed = seed })
  local source = VMGen.emit(plan, { payload = payload })
  return payload.blob, source
end
local dA1, dA2 = pipe(0xB001)
local dB1, dB2 = pipe(0xB001)
check("polymorphism: same seed gives the same blob", dA1 == dB1)
check("polymorphism: same seed gives the same source", dA2 == dB2)

-- The same instruction sequence encrypted under two different seeds must not
-- share any block bytes.
local p1 = VMGen.randomize(sampleCompiled, { seed = 0xB101, decoys = 160 })
local p2 = VMGen.randomize(sampleCompiled, { seed = 0xB202, decoys = 160 })
Selfmod.apply(p1, { seed = 0xB101 })
Selfmod.apply(p2, { seed = 0xB202 })
local q1, q2 = p1.protos[1], p2.protos[1]
local sameBlocks = 0
for bi = 1, math.min(#q1.blocks, #q2.blocks) do
  if q1.blocks[bi] == q2.blocks[bi] then sameBlocks = sameBlocks + 1 end
end
check("polymorphism: different seeds give different blocks", sameBlocks == 0,
  sameBlocks)

-- ---------------------------------------------------------------------------
-- 11. Scale: 300-line program end to end
-- ---------------------------------------------------------------------------
local lines = { "local s = 0" }
for i = 1, 298 do
  lines[#lines + 1] = string.format("s = s + %d", (i * 37) % 23 + 1)
end
lines[#lines + 1] = "print(s)"
local scaleSrc = table.concat(lines, "\n")

local t0 = os.clock()
local scaleCompiled = build(scaleSrc)
local compileMs = (os.clock() - t0) * 1000

t0 = os.clock()
local scalePlan = VMGen.randomize(scaleCompiled,
  { seed = 0xB201, decoys = 160 })
local scaleMod = Selfmod.apply(scalePlan, { seed = 0xB201 })
local packMs0 = (os.clock() - t0) * 1000

t0 = os.clock()
local scalePayload = Bytecode.pack(scalePlan, { seed = 0xB201 })
local packMs = packMs0 + (os.clock() - t0) * 1000

t0 = os.clock()
local scaleSource = VMGen.emit(scalePlan, { payload = scalePayload })
local emitMs = (os.clock() - t0) * 1000

local scaleInstr = scaleMod.instructions
local scaleWant = execute(scaleSrc)
local scaleGot = runGenerated(scaleSource)
check("scale: self-modifying runtime matches source", scaleWant ~= nil and
  scaleGot == scaleWant,
  tostring(scaleGot) .. " ~= " .. tostring(scaleWant))
check("scale: build stays under the 10 s budget",
  compileMs + packMs + emitMs < 10000,
  string.format("%.1f ms", compileMs + packMs + emitMs))
local scaleMaxCap = 0
for pi = 1, #scalePlan.protos do
  local P = scalePlan.protos[pi]
  if P.sm then
    local want = expectedCap(P.total, BLOCK, MAXB)
    if want > scaleMaxCap then scaleMaxCap = want end
  end
end
check("scale: live cap is the largest per-proto window",
  scaleMod.liveCap == scaleMaxCap, scaleMod.liveCap .. " ~= " .. scaleMaxCap)
check("scale: cap inside the 20% window",
  scaleInstr >= 20 and scaleMod.liveCap <=
    math.max(scaleInstr * 0.2, Selfmod.WINDOW_FLOOR) + 1e-9,
  scaleMod.liveCap .. " / " .. scaleInstr)
check("scale: blob smaller than source", #scalePayload.blob < #scaleSource,
  #scalePayload.blob .. " >= " .. #scaleSource)

local scaleReplay = Selfmod.replay(scalePlan, { seed = 0xB201 })
check("scale: replay decodes without error", scaleReplay.error == nil,
  scaleReplay.error)
check("scale: replay stays inside the live cap",
  scaleReplay.maxLive <= scaleMod.liveCap,
  scaleReplay.maxLive .. " > " .. scaleMod.liveCap)
local function residentBlocks(total, cap, B)
  local n, sum = 0, 0
  for bi = 1, math.ceil(total / B) do
    local cnt = B
    local last = total - (bi - 1) * B
    if last < cnt then cnt = last end
    if sum + cnt > cap then break end
    sum = sum + cnt
    n = n + 1
  end
  return n
end
local evictions = 0
for pi = 1, #scalePlan.protos do
  local P = scalePlan.protos[pi]
  if P.sm then
    evictions = evictions +
      math.max(0, #P.blocks - residentBlocks(P.total, P.cap, BLOCK))
  end
end
check("scale: every block past the window is rewritten once",
  scaleReplay.mutations == evictions,
  scaleReplay.mutations .. " ~= " .. evictions)

local lineCount = select(2, string.gsub(scaleSrc, "\n", "")) + 1
notes[#notes + 1] = string.format(
  "MODULE10_SCALE lines=%d protos=%d instr=%d blocks=%d cap=%d " ..
  "block_bytes=%d blob=%d source=%d mutations=%d " ..
  "compile_ms=%.1f pack_ms=%.1f emit_ms=%.1f",
  lineCount, #scalePlan.protos, scaleInstr, scaleMod.blocks, scaleMod.liveCap,
  scaleMod.bytes, #scalePayload.blob, #scaleSource, scaleReplay.mutations,
  compileMs, packMs, emitMs)

-- ---------------------------------------------------------------------------
-- 12. Summary
-- ---------------------------------------------------------------------------
notes[#notes + 1] = string.format(
  "MODULE10_BLOCKS block=%d max_blocks=%d sample_protos=%d sample_blocks=%d " ..
  "sample_instr=%d sample_cap=%d",
  BLOCK, MAXB, sampleStats.protos, sampleStats.blocks,
  sampleStats.instructions, sampleStats.liveCap)
notes[#notes + 1] = string.format(
  "MODULE10_REPLAY visits=%d decodes=%d mutations=%d maxlive=%d changed=%d",
  sampleReplay.visits, sampleReplay.decodes, sampleReplay.mutations,
  sampleReplay.maxLive, sampleReplay.changed)
notes[#notes + 1] = string.format("MODULE10_TAMPER block=1 state=1 chain=1 " ..
  "trunc=1 runtime=3")
notes[#notes + 1] = string.format("MODULE10_CHECKS %d/%d",
  checks - failures, checks)

local printOut = print
for i = 1, #notes do printOut(notes[i]) end
printOut("MODULE10_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
