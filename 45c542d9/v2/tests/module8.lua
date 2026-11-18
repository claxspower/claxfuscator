-- module8.lua -- acceptance tests for layer 8 (randomized opcodes + O(1)
-- handler-table dispatch runtime).
--
-- All six opcode encodings must preserve the compiler ISA across every host.
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

local function errorText(list)
  local parts = {}
  for i = 1, #(list or {}) do
    local e = list[i]
    parts[i] = tostring(e.line) .. ":" .. tostring(e.col) .. " " .. tostring(e.msg)
  end
  return table.concat(parts, " | ")
end

local function build(src, opts)
  opts = opts or {}
  local ast, errors = parse(src)
  if not ast then return nil, nil, errors end
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  if not opts.raw then
    Consts.run(ast, { seed = 0x0C057A })
    Flatten.run(ast, { seed = 3 })
    Opaque.run(ast, { seed = 5, prob = 0.6 })
    Strings.run(ast, { seed = 0x5CE41D })
  end
  local compiled = Compiler.compile(ast, {})
  return compiled, result, errors
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

local function execute(src, ...)
  local out = {}
  local env = makeEnv(out)
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(src, "@program")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@program", "t", env)
  end
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk, ...)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function loadGenerated(src, env)
  env.__sourceLoads = 0
  env.load = function()
    env.__sourceLoads = env.__sourceLoads + 1
    error("generated runtime called a source loader")
  end
  env.loadstring = env.load
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(src, "@vm")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = loadChunk(src, "@vm", "t", env)
  end
  return chunk, err
end

local function runGenerated(src, ...)
  local out = {}
  local env = makeEnv(out)
  local chunk, err = loadGenerated(src, env)
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk, ...)
  if env.__sourceLoads ~= 0 then return nil, "runtime attempted source evaluation" end
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function runVm(compiled, ...)
  local out = {}
  local env = makeEnv(out)
  local ok, err = pcall(VM.run, compiled, env, ...)
  if not ok then return nil, tostring(err) end
  return table.concat(out, "\n")
end

local function emitPlan(plan)
  return VMGen.emit(plan)
end

-- ---------------------------------------------------------------- utilities
local function clonePlan(plan)
  local protos = {}
  for i = 1, #plan.protos do
    local P = plan.protos[i]
    local c = {}
    for j = 1, #P.c do
      local I = P.c[j]
      c[j] = { I[1], I[2], I[3], I[4], I[5] }
    end
    local k = {}
    for j = 1, #P.k do k[j] = P.k[j] end
    local u = {}
    for j = 1, #P.u do u[j] = { P.u[j][1], P.u[j][2] } end
    protos[i] = { c = c, k = k, u = u, a = P.a, v = P.v }
  end
  return {
    seed = plan.seed,
    decoyCount = plan.decoyCount,
    opnum = plan.opnum,
    opkeys = plan.opkeys,
    layouts = plan.layouts,
    operandMasks = plan.operandMasks,
    keyMul = plan.keyMul,
    keyBias = plan.keyBias,
    decoys = plan.decoys,
    protos = protos,
    instructions = plan.instructions,
    sourceInstructions = plan.sourceInstructions,
  }
end

local function ins(op, a, b, c, d)
  return { op = op, a = a or 0, b = b or 0, c = c or 0, d = d or 0 }
end

local function rawCompiled(code, opts)
  opts = opts or {}
  return {
    strings = {},
    protos = { {
      code = code,
      k = opts.k or {},
      updesc = opts.updesc or {},
      params = opts.params or 0,
      vararg = opts.vararg or false,
      maxstack = opts.maxstack or 16,
    } },
  }
end

local function expectRaw(name, compiled, expected, ...)
  local src, stats = VMGen.generate(compiled, { seed = 0x8A00, decoys = 160 })
  check(name .. ": source emitted", type(src) == "string" and #src > 0)
  if type(src) ~= "string" then return end
  check(name .. ": stats", stats.instructions == #compiled.protos[1].code,
    stats.instructions)
  local got, err = runGenerated(src, ...)
  check(name .. ": generated output", got == expected,
    err or ("got=" .. tostring(got) .. " want=" .. tostring(expected)))
  local ref, rerr = runVm(compiled, ...)
  check(name .. ": reference agrees", ref == expected,
    rerr or ("ref=" .. tostring(ref) .. " want=" .. tostring(expected)))
end

-- ---------------------------------------------------------------------------
-- 1. Opcode space, key assignment and plan encoding
-- ---------------------------------------------------------------------------
local function sortedKeys(set)
  local list = {}
  for key in pairs(set) do list[#list + 1] = key end
  table.sort(list)
  return list
end

do
  check("catalog: 80 real opcodes", VMGen.OPCODES == 80, VMGen.OPCODES)
  check("catalog: default decoys 448", VMGen.DEFAULT_DECOYS == 448,
    VMGen.DEFAULT_DECOYS)
  check("catalog: key range 65535", VMGen.KEY_RANGE == 65535, VMGen.KEY_RANGE)
  check("catalog: max decoys 1024", VMGen.MAX_DECOYS == 1024, VMGen.MAX_DECOYS)
  check("catalog: twenty-four encodings", VMGen.ENCODINGS_PER_OPCODE == 24,
    VMGen.ENCODINGS_PER_OPCODE)
  local realKeys = #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE

  local src = "local a, b = 2, 3 print(a + b)"
  local compiled = build(src)
  local plan = VMGen.randomize(compiled, { seed = 0x8D01, decoys = 160 })

  local realSet, decoySet, allSet = {}, {}, {}
  local realCount, decoyCount, dup = 0, 0, nil
  local layoutSet = {}
  for i = 1, #Compiler.OPS do
    local name = Compiler.OPS[i]
    local keys = plan.opkeys[name]
    check("plan: encodings " .. name,
      #keys == VMGen.ENCODINGS_PER_OPCODE and keys[1] == plan.opnum[name])
    local ownLayouts, ownMasks = {}, {}
    for j = 1, #keys do
      local key = keys[j]
      local layout, mask = plan.layouts[key], plan.operandMasks[key]
      local signature = table.concat(layout, ",")
      -- Only six legal slot layouts exist (the immediate is pinned to slot
      -- 5), so the first six encodings must be distinct and the rest repeat.
      if j <= 6 then
        check("plan: distinct alias layout " .. name .. j,
          not ownLayouts[signature])
      end
      ownLayouts[signature] = true
      local maskSignature = table.concat(mask.signs, ",") .. ":" .. table.concat(mask.biases, ",")
      check("plan: distinct alias mask " .. name .. j, not ownMasks[maskSignature])
      ownMasks[maskSignature] = true
      for slot = 1, 3 do
        check("plan: sign " .. name .. j .. slot,
          mask.signs[slot] == 1 or mask.signs[slot] == -1)
        check("plan: bias " .. name .. j .. slot,
          mask.biases[slot] >= 1 and mask.biases[slot] <= 4095 and mask.biases[slot] % 1 == 0)
      end
      local slots = { layout[1], layout[2], layout[3] }
      table.sort(slots)
      check("plan: operand permutation " .. name .. j,
        table.concat(slots, ",") == "2,3,4")
      layoutSet[signature] = true
      realCount = realCount + 1
      if type(key) ~= "number" or key < 1 or key > VMGen.KEY_RANGE then dup = "real key" end
      if realSet[key] then dup = dup or ("duplicate real key " .. tostring(key)) end
      if allSet[key] then dup = dup or ("real/decoy collision " .. tostring(key)) end
      realSet[key] = true
      allSet[key] = true
    end
  end
  local layoutCount = 0
  for _ in pairs(layoutSet) do layoutCount = layoutCount + 1 end
  check("plan: all six layouts", layoutCount == 6, layoutCount)
  for i = 1, #plan.decoys do
    local key = plan.decoys[i]
    decoyCount = decoyCount + 1
    if type(key) ~= "number" or key < 1 or key > VMGen.KEY_RANGE then dup = "decoy key" end
    if decoySet[key] then dup = dup or ("duplicate decoy key " .. tostring(key)) end
    if allSet[key] then dup = dup or ("decoy collision " .. tostring(key)) end
    decoySet[key] = true
    allSet[key] = true
  end
  local total = 0
  for _ in pairs(allSet) do total = total + 1 end

  check("plan: real keys",
    realCount == realKeys, realCount)
  check("plan: 160 decoy keys", decoyCount == 160, decoyCount)
  check("plan: distinct keys", total == realKeys + decoyCount, total)
  check("plan: decoy ratio >= 2x logical opcodes", decoyCount >= 2 * #Compiler.OPS,
    decoyCount .. "/" .. #Compiler.OPS)
  check("plan: keys disjoint and in range", dup == nil, dup)
  check("plan: sparse key space", VMGen.KEY_RANGE - total == 65535 - total)
  local largest = 0
  for key in pairs(allSet) do if key > largest then largest = key end end
  check("plan: wide keys used", largest > 32768, largest)

  -- Every instruction word carries a real key and preserves the other fields.
  local encodedMismatch
  for pi = 1, #plan.protos do
    local P, Q = plan.protos[pi], compiled.protos[pi]
    if #P.c ~= #Q.code then encodedMismatch = "code length " .. pi end
    for j = 1, #P.c do
      local I, J = P.c[j], Q.code[j]
      local keys, layout, mask = plan.opkeys[J.op], plan.layouts[I[1]], plan.operandMasks[I[1]]
      local valid = false
      for k = 1, #keys do if I[1] == keys[k] then valid = true end end
      if not valid then encodedMismatch = "key " .. pi .. "@" .. j end
      if decoySet[I[1]] then encodedMismatch = "decoy emitted " .. pi .. "@" .. j end
      if (I[layout[1]] - mask.biases[1]) * mask.signs[1] ~= (J.a or 0) or
         (I[layout[2]] - mask.biases[2]) * mask.signs[2] ~= (J.b or 0) or
         (I[layout[3]] - mask.biases[3]) * mask.signs[3] ~= (J.c or 0) or I[5] ~= (J.d or 0) then
        encodedMismatch = "operand " .. pi .. "@" .. j
      end
    end
    if #P.k ~= #Q.k then encodedMismatch = "constant count " .. pi end
    if P.a ~= (Q.params or 0) then encodedMismatch = "params " .. pi end
    if P.v ~= (Q.vararg and true or false) then encodedMismatch = "vararg " .. pi end
  end
  check("plan: encoding preserves instructions", encodedMismatch == nil,
    encodedMismatch)
  check("plan: instruction count", plan.instructions == compiled.stats.instructions,
    plan.instructions)

  -- Seeding and clamping.
  local again = VMGen.randomize(compiled, { seed = 0x8D01, decoys = 160 })
  local same, why = true, nil
  for i = 1, #Compiler.OPS do
    local name = Compiler.OPS[i]
    if table.concat(plan.opkeys[name], ",") ~= table.concat(again.opkeys[name], ",") then
      same, why = false, name
    end
    for j = 1, #plan.opkeys[name] do
      local key = plan.opkeys[name][j]
      if table.concat(plan.layouts[key], ",") ~= table.concat(again.layouts[key], ",") then
        same, why = false, name .. " layout"
      end
      local first, second = plan.operandMasks[key], again.operandMasks[key]
      if table.concat(first.signs, ",") ~= table.concat(second.signs, ",") or
         table.concat(first.biases, ",") ~= table.concat(second.biases, ",") then
        same, why = false, name .. " mask"
      end
    end
  end
  check("plan: same seed same map", same, why)
  check("plan: same seed same decoys",
    table.concat(sortedKeys(decoySet), ",") ==
    table.concat(sortedKeys((function()
      local s = {}
      for i = 1, #again.decoys do s[again.decoys[i]] = true end
      return s
    end)()), ","))

  local zero = VMGen.randomize(compiled, { seed = 1, decoys = 0 })
  check("plan: zero decoys", #zero.decoys == 0 and zero.decoyCount == 0,
    #zero.decoys)
  local neg = VMGen.randomize(compiled, { seed = 1, decoys = -9 })
  check("plan: negative decoys clamped", #neg.decoys == 0, #neg.decoys)
  local big = VMGen.randomize(compiled, { seed = 1, decoys = 5000 })
  check("plan: decoys clamped to max", #big.decoys == VMGen.MAX_DECOYS,
    #big.decoys)

  local ok, err = pcall(VMGen.randomize, nil, {})
  check("plan: rejects missing program", not ok and tostring(err):find("vmgen", 1, true),
    tostring(err))
end

-- Public compiler/opcode boundaries must reject before encoding or emitting.
do
  local compiled = build("print(select('#', ...), ...)", { raw = true })
  local function rejects(name, value, opts, diagnostic)
    for _, entry in ipairs({ "randomize", "generate" }) do
      local ok, err = pcall(VMGen[entry], value, opts)
      check("boundary: " .. entry .. " " .. name, not ok and
        type(err) == "string" and err:find(diagnostic, 1, true) ~= nil, err)
    end
  end
  rejects("missing program", nil, {}, "vmgen: validation failed")
  rejects("malformed prototypes", { protos = { false } }, {}, "validation failed")
  rejects("missing header", { protos = { { code = {}, k = {} } } }, {}, "validation failed")
  rejects("sparse code", rawCompiled({ [2] = ins("RETURN", 0, 0) }), {}, "validation failed")
  rejects("missing K operand", rawCompiled({ ins("ADDK", 1, 2, 0, 1) }), {},
    "validation failed: proto 1@1: constant index")
  rejects("fractional register", rawCompiled({ ins("MOVE", 1.5, 1) }), {},
    "validation failed")
  rejects("out-of-frame register", rawCompiled({ ins("MOVE", 17, 1) }), {},
    "validation failed")
  rejects("non-vararg", rawCompiled({ ins("VARARG", 1, -1) }), {},
    "validation failed")
  rejects("implicit jump exit", rawCompiled({ ins("JMP", 0, 0, 0, 0) }), {},
    "validation failed")
  local invalid = rawCompiled({ ins("RETURN", 0, 0) })
  invalid.errors = { { msg = "compiler failed" } }
  rejects("compiler errors on valid structure", invalid, {}, "compiled errors")
  local ast = parse("local x = 1")
  ast.children[#ast.children + 1] = { type = "Bogus", children = {} }
  rejects("actual compiler failure", Compiler.compile(ast), {}, "compiled errors")

  for _, value in ipairs({ true, false, {}, "nonsense", math.huge, -math.huge, 0/0,
      "1e9999" }) do
    rejects("invalid seed " .. tostring(value), compiled, { seed = value }, "invalid seed")
    rejects("invalid decoys " .. tostring(value), compiled, { decoys = value }, "invalid decoys")
  end
  for _, value in ipairs({ false, true, 1, "options" }) do
    rejects("invalid options", compiled, value, "options must be a plain table")
  end
  for _, pair in ipairs({ { "17", 17 }, { "17.9", 17 }, { 17.9, 17 },
      { -1, 4294967295 }, { -0.25, 4294967295 }, { 4294967313, 17 } }) do
    local opts = { seed = pair[1], decoys = "3.9" }
    local ok, plan = pcall(VMGen.randomize, compiled, opts)
    check("boundary: canonical seed " .. tostring(pair[1]), ok and
      plan.seed == pair[2] and type(plan.seed) == "number" and plan.decoyCount == 3,
      ok and plan.seed or plan)
    check("boundary: options not mutated", opts.seed == pair[1] and opts.decoys == "3.9")
    local gok, source = pcall(VMGen.generate, compiled, opts)
    local canonical = VMGen.generate(compiled, { seed = pair[2], decoys = 3 })
    check("boundary: equivalent seeds identical " .. tostring(pair[1]),
      gok and source == canonical, not gok and source or nil)
    if gok then
      local out, err = runGenerated(source, nil, false, 7, nil)
      check("boundary: canonical seed preserves nil arity", out == "4\tnil\tfalse\t7\tnil", err or out)
    end
  end
  local default = VMGen.randomize(compiled)
  check("boundary: default canonical seed", default.seed == VMGen.DEFAULT_SEED)
  local huge = VMGen.randomize(compiled, { seed = 1e100, decoys = 1e100 })
  check("boundary: huge finite options normalized", huge.seed >= 0 and
    huge.seed < 4294967296 and huge.seed == math.floor(huge.seed) and
    huge.decoyCount == VMGen.MAX_DECOYS)
end

local Bytecode = require("src.bytecode")
local Selfmod = require("src.selfmod")

do
  -- Exercise every alias with legal ISA operands, including opcodes the
  -- compiler does not emit. The sampled body is dead, not exempt from checks.
  local fixtures, numeric = {}, {}
  local function fixture(names, a, b, c, d)
    for name in names:gmatch("%S+") do fixtures[name] = { a, b, c or 0, d or 0 } end
  end
  fixture("MOVE GETCELL SETCELL UNM NOT LEN BNOT", 3, 5)
  fixture("LOADNIL NEWTABLE", 3, 0)
  fixture("LOADBOOL", 3, 1)
  fixture("LOADK GETGLOBAL SETGLOBAL", 3, 0, 0, 1)
  fixture("GETFIELD SETFIELD SELF", 3, 5, 0, 1)
  fixture("ADDK SUBK MULK DIVK MODK POWK IDIVK EQK NEK LTK LEK", 3, 5, 0, 1)
  fixture("LOADINT", 3, 0)
  fixture("ADDI SUBI MULI DIVI MODI GETIDXI SETIDXI", 3, 5)
  for name in ("LOADINT ADDI SUBI MULI DIVI MODI GETIDXI SETIDXI"):gmatch("%S+") do
    numeric[name] = true
  end
  fixture("LOADNILN", 3, 0, 0, 4)
  fixture("GETUPVAL SETUPVAL", 3, 1)
  fixture("NEWCELL", 3, 0)
  fixture("GETTABLE SETTABLE ADD SUB MUL DIV MOD POW IDIV CONCAT " ..
    "BAND BOR BXOR SHL SHR EQ NE LT LE GT GE", 3, 5, 7)
  fixture("BOOL", 3, 5, 1)
  fixture("TEST", 1, 5)
  fixture("TESTSET", 1, 5, 7)
  fixture("TESTNIL", 0, 5)
  fixture("JMP", 0, 0, 0, -1)
  fixture("JMPF JMPT FORPREP FORLOOP TFORLOOP", 3, 0, 0, -1)
  fixture("TFORCALL", 3, 4)
  fixture("SETLIST", 3, 1, 5, -1)
  fixture("CLOSE NOP", 0, 0)
  fixture("SETTOP", 17, 0)
  fixture("CALL", 3, -1, -1, 9)
  fixture("TAILCALL RETURN VARARG", 3, -1)
  fixture("CLOSURE", 3, 3)

  local code = { ins("RETURN", 0, 0) }
  local negativeZero = -1 / math.huge
  local values = { negativeZero, 0.25, -0.75, 4294967296.5 }
  for i = 1, #Compiler.OPS do
    local name = Compiler.OPS[i]
    local f = assert(fixtures[name], "missing legal fixture: " .. name)
    for j = 1, 128 do
      code[#code + 1] = ins(name, f[1], f[2], f[3],
        numeric[name] and values[j % #values + 1] or f[4])
    end
  end
  code[#code + 1] = ins("RETURN", 0, 0)
  local compiled = rawCompiled({ ins("NEWCELL", 1, 0),
    ins("CLOSURE", 2, 2), ins("RETURN", 0, 0) })
  compiled.protos[2] = rawCompiled(code,
    { k = { 7 }, updesc = { { 1, 1 } }, vararg = true }).protos[1]
  compiled.protos[3] = rawCompiled({ ins("RETURN", 0, 0) },
    { updesc = { { 0, 1 } } }).protos[1]
  local problems = Compiler.validate(compiled)
  check("aliases: per-opcode fixtures validate", #problems == 0, problems[1])
  local plan = VMGen.randomize(compiled, { seed = 761, decoys = 0 })
  local again = VMGen.randomize(compiled, { seed = 761, decoys = 0 })
  local seen, signs, preserved, stable = {}, {}, true, true
  for i = 1, #code do
    local J = code[i]
    local word = plan.protos[2].c[i]
    local layout, mask = plan.layouts[word[1]], plan.operandMasks[word[1]]
    local operands = { J.a, J.b, J.c }
    seen[word[1]] = J.op
    for slot = 1, 3 do
      signs[mask.signs[slot]] = true
      if (word[layout[slot]] - mask.biases[slot]) * mask.signs[slot] ~= operands[slot] then
        preserved = false
      end
    end
    if word[5] ~= J.d or (J.d == 0 and 1 / word[5] ~= 1 / J.d) then preserved = false end
    for j = 1, 5 do
      if word[j] ~= again.protos[2].c[i][j] then stable = false end
    end
  end
  -- Instruction words must land inside their own opcode's key set, and every
  -- opcode must spread over the full encoding set. With 128 draws over 14 keys
  -- a couple of keys can stay unsampled, so the spread check allows two.
  local owned, keysDistinct, perOpcode = {}, true, true
  for _, name in ipairs(Compiler.OPS) do
    local keys = plan.opkeys[name]
    if #keys ~= VMGen.ENCODINGS_PER_OPCODE then perOpcode = false end
    for i = 1, #keys do
      if owned[keys[i]] then keysDistinct = false end
      owned[keys[i]] = name
    end
  end
  check("aliases: every opcode owns its encodings", perOpcode and keysDistinct)
  local counts, foreign = {}, false
  for key, name in pairs(seen) do
    if owned[key] ~= name then
      foreign = true
    else
      counts[name] = (counts[name] or 0) + 1
    end
  end
  local minSeen, spread = math.huge, true
  for _, name in ipairs(Compiler.OPS) do
    local c = counts[name] or 0
    if c < minSeen then minSeen = c end
    if c < VMGen.ENCODINGS_PER_OPCODE - 2 or c > VMGen.ENCODINGS_PER_OPCODE then
      spread = false
    end
  end
  check("aliases: every opcode spreads over its encodings",
    spread and not foreign, minSeen)
  check("aliases: both operand signs selected", signs[1] and signs[-1])
  check("aliases: signed operands and numeric d preserved", preserved)
  check("aliases: deterministic masked instruction encoding", stable)

  local src = [[
local function make(n)
  return function(...) n=n+select("#",...) return n,... end
end
local f=make(3)
local t={value=7}
function t:read(x) return self.value+x end
local mt={__add=function(a,b) return "A"..a.v..":"..b.v end}
local u=setmetatable({v="left"},mt)
local v=setmetatable({v="right"},mt)
for i=1,4 do
  if i~=2 then
    print(t:read(i), f(nil,false,i), u+v)
  end
end
]]
  local compiled = build(src, { raw = true })
  local expected = execute(src)
  for seed = 1, 6 do
    local base = VMGen.randomize(compiled, { seed = seed, decoys = 0 })
    for variant = 1, VMGen.ENCODINGS_PER_OPCODE do
      local remapped = clonePlan(base)
      for pi = 1, #compiled.protos do
        for i = 1, #compiled.protos[pi].code do
          local I = compiled.protos[pi].code[i]
          local key = base.opkeys[I.op][variant]
          local layout, mask = base.layouts[key], base.operandMasks[key]
          local word = { key, 0, 0, 0, I.d or 0 }
          local operands = { I.a or 0, I.b or 0, I.c or 0 }
          for slot = 1, 3 do
            word[layout[slot]] = operands[slot] * mask.signs[slot] + mask.biases[slot]
          end
          remapped.protos[pi].c[i] = word
        end
      end
      local got, err = runGenerated(emitPlan(remapped))
      check("aliases: forced encoding " .. seed .. "/" .. variant,
        got == expected, err or got)
      if seed == 1 then
        local packed = Bytecode.pack(clonePlan(remapped), { seed = seed })
        local packedOut, packedErr = runGenerated(VMGen.emit(remapped, { payload = packed }))
        check("aliases: packed forced encoding " .. variant,
          packedOut == expected, packedErr or packedOut)
        local live = clonePlan(remapped)
        Selfmod.apply(live, { seed = seed })
        local payload = Bytecode.pack(live, { seed = seed })
        local liveOut, liveErr = runGenerated(VMGen.emit(live, { payload = payload }))
        check("aliases: selfmod forced encoding " .. variant,
          liveOut == expected, liveErr or liveOut)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- 2. Emitted source shape: O(1) dispatch, 480 handlers, no linear chain
-- ---------------------------------------------------------------------------
local function countPlain(text, needle)
  local count = 0
  local from = 1
  while true do
    local at = text:find(needle, from, true)
    if not at then return count end
    count = count + 1
    from = at + #needle
  end
end

-- Operator and keyword scans must ignore string literals: the encoded
-- constant blob is data, and printable ciphertext bytes routinely contain
-- `&`, `|` and `//`.
local function codeOnly(text)
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

do
  local src = [[
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local c = counter(1)
print(c(2), c(3), "alpha")
]]
  local compiled = build(src)
  local source, stats = VMGen.generate(compiled, { seed = 0x8D02, decoys = 160 })

  check("source: bytes statistic", stats.bytes == #source + 1, stats.bytes)
  check("source: 80 opcodes statistic", stats.opcodes == 80, stats.opcodes)
  check("source: alias statistic",
    stats.aliases == #Compiler.OPS * (VMGen.ENCODINGS_PER_OPCODE - 1),
    stats.aliases)
  check("source: real encodings",
    #stats.realKeys == #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE,
    #stats.realKeys)
  check("source: 160 decoys statistic", stats.decoys == 160, stats.decoys)
  check("source: key statistic",
    stats.keys == #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE + 160, stats.keys)
  local code = codeOnly(source)
  check("source: no elseif chain", code:find("elseif", 1, true) == nil)
  check("source: no goto", code:find("goto", 1, true) == nil)
  check("source: no labels", code:find("::", 1, true) == nil)
  check("source: no integer division", code:find("//", 1, true) == nil)
  check("source: no bitwise and", code:find("&", 1, true) == nil)
  check("source: no bitwise or", code:find("|", 1, true) == nil)
  check("source: no shifts", code:find("<<", 1, true) == nil and
    code:find(">>", 1, true) == nil)
  check("source: no require", code:find("require", 1, true) == nil)

  -- Handler parameters, decoded operands and frame fields are renamed per
  -- build, and the six parameter names are also permuted per build, so the
  -- expected signature is read from the first emitted handler and then used to
  -- count every other handler.
  local n = stats.names
  local sigOpen = source:find("]=function(", 1, true)
  check("source: handler signature present", sigOpen ~= nil)
  local sigStart = (sigOpen or 1) + #"]=function"
  local sigStop = source:find(")", sigStart, true) or sigStart
  local sig = source:sub(sigStart, sigStop)
  local opnames = n.A .. "," .. n.B .. "," .. n.C .. "," .. n.D
  local handlerCount = 0
  local handlerKeys = {}
  local handlerDup = nil
  for key in source:gmatch("%[(%d+)%]=function") do
    handlerCount = handlerCount + 1
    if handlerKeys[key] then handlerDup = key end
    handlerKeys[key] = true
  end
  local wantHandlers = #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE + 160
  check("source: handler definitions", handlerCount == wantHandlers, handlerCount)
  check("source: handler keys unique", handlerDup == nil, handlerDup)

  local kMul, kBias = stats.keyMul or 1, stats.keyBias or 0
  local slots = stats.slots
  local function tableKey(key) return slots and slots[key] or key * kMul + kBias end
  local wanted = {}
  for i = 1, #stats.realKeys do
    local key = stats.realKeys[i]
    wanted[tableKey(key)] = true
    local layout, mask = stats.layouts[key], stats.operandMasks[key]
    local operands = {}
    for slot = 1, 4 do
      local value = n.VI .. "[" .. layout[slot] .. "]"
      local bias = mask.biases[slot]
      if bias == 0 then
        if mask.signs[slot] ~= 1 then value = "0-" .. value end
      elseif mask.signs[slot] == 1 then
        value = value .. "-" .. bias
      else
        value = bias .. "-" .. value
      end
      operands[slot] = value
    end
    local header = "[" .. tableKey(key) .. "]=function" .. sig ..
      " local " .. opnames .. "=" .. table.concat(operands, ",")
    check("source: key-specific masked layout " .. key,
      source:find(header, 1, true) ~= nil)
  end
  for i = 1, #stats.decoyKeys do
    wanted[tableKey(stats.decoyKeys[i])] = true
  end
  local mismatch
  for key in pairs(wanted) do
    if not handlerKeys[tostring(key)] then mismatch = "missing " .. key end
  end
  for key in pairs(handlerKeys) do
    if not wanted[tonumber(key)] then mismatch = mismatch or ("extra " .. key) end
  end
  check("source: handler keys match plan", mismatch == nil, mismatch)
  local function handlerBody(key)
    local start = source:find("[" .. tableKey(key) .. "]=function", 1, true)
    local stop = source:find(" end ", start, true)
    return source:sub(start, stop + 4)
  end
  local addVariants = {}
  for _, key in ipairs(stats.opkeys.ADD) do addVariants[handlerBody(key)] = true end
  local addCount = 0
  for _ in pairs(addVariants) do addCount = addCount + 1 end
  check("source: distinct ADD alias bodies", addCount >= 3, addCount)

  local signatures = countPlain(source, "]=" .. "function" .. sig)
  check("source: handler signatures", signatures == wantHandlers, signatures)
  local lookups = countPlain(source, "local " .. n.VNPC .. "=")
  check("source: single table-lookup dispatcher", lookups == 1, lookups)

  local firstHandler = source:find("=function" .. sig, 1, true)
  local declF = source:find("local " .. stats.names.X .. "," .. stats.names.F,
    1, true)
  check("source: closure factory is an upvalue", declF ~= nil and
    firstHandler ~= nil and declF < firstHandler,
    tostring(declF) .. " vs " .. tostring(firstHandler))

  local lastHandler = nil
  local from = 1
  while true do
    local at = source:find("=function" .. sig, from, true)
    if not at then break end
    lastHandler = at
    from = at + 1
  end
  local entry = source:find("local " .. stats.names.W .. "=" .. stats.names.F,
    1, true)
  check("source: handlers installed before entry", lastHandler ~= nil and
    entry ~= nil and lastHandler < entry,
    tostring(lastHandler) .. " vs " .. tostring(entry))

  -- Layer 2 renamed locals and layer 6 encrypted literals: nothing from the
  -- source program may survive as text.
  check("source: no source identifier", source:find("counter", 1, true) == nil)
  check("source: no plaintext literal", source:find("alpha", 1, true) == nil)
  check("source: no plaintext print index", source:find("%[\"print\"%]") == nil)

  -- Determinism and polymorphism of the emitted file.
  local sameSource = VMGen.generate(compiled, { seed = 0x8D02, decoys = 160 })
  check("source: same seed identical", sameSource == source)
  local other = VMGen.generate(compiled, { seed = 0x8D03, decoys = 160 })
  check("source: new seed differs", other ~= source)

  local outputs = {}
  for i = 1, 10 do
    local s = VMGen.generate(compiled, { seed = 0x8E00 + i * 7919, decoys = 160 })
    outputs[s] = (outputs[s] or 0) + 1
  end
  local distinct = 0
  for _ in pairs(outputs) do distinct = distinct + 1 end
  check("source: 10/10 distinct builds", distinct == 10, distinct)

  notes[#notes + 1] = string.format(
    "MODULE8_SOURCE bytes=%d handlers=%d dispatch=1 real=80 aliases=%d decoy=160",
    stats.bytes, handlerCount, #Compiler.OPS * (VMGen.ENCODINGS_PER_OPCODE - 1))
end

-- ---------------------------------------------------------------------------
-- 3. Raw ISA programs through the generated runtime
-- ---------------------------------------------------------------------------
do
  local simple = rawCompiled({
    ins("LOADINT", 1, 0, 0, 42),
    ins("NOP"),
    ins("CLOSE", 0),
    ins("LOADNILN", 2, 0, 0, 2),
    ins("SETTOP", 4),
    ins("GETGLOBAL", 4, 0, 0, 1),
    ins("MOVE", 5, 1),
    ins("CALL", 4, 1, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw nop/close/loadint", simple, "42")

  local bools = rawCompiled({
    ins("LOADINT", 1, 0, 0, 0),
    ins("BOOL", 2, 1, 0, 0),
    ins("BOOL", 3, 1, 1, 0),
    ins("LOADNIL", 4),
    ins("BOOL", 5, 4, 0, 0),
    ins("BOOL", 6, 4, 1, 0),
    ins("GETGLOBAL", 7, 0, 0, 1),
    ins("MOVE", 8, 2), ins("MOVE", 9, 3), ins("MOVE", 10, 5),
    ins("MOVE", 11, 6), ins("MOVE", 12, 1),
    ins("CALL", 7, 5, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw bool truthiness", bools, "true\tfalse\tfalse\ttrue\t0")

  local skips = rawCompiled({
    ins("LOADINT", 1, 0, 0, 1),
    ins("TEST", 1, 1),
    ins("LOADINT", 2, 0, 0, 99),
    ins("TEST", 0, 1),
    ins("LOADINT", 3, 0, 0, 7),
    ins("LOADNIL", 4),
    ins("TESTNIL", 0, 4),
    ins("LOADINT", 5, 0, 0, 88),
    ins("TESTSET", 0, 3, 6),
    ins("LOADINT", 7, 0, 0, 5),
    ins("GETGLOBAL", 8, 0, 0, 1),
    ins("MOVE", 9, 1), ins("MOVE", 10, 2), ins("MOVE", 11, 3),
    ins("MOVE", 12, 4), ins("MOVE", 13, 5), ins("MOVE", 14, 6),
    ins("MOVE", 15, 7),
    ins("CALL", 8, 7, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw test skip", skips, "1\tnil\t7\tnil\tnil\tnil\t5")

  local bits = rawCompiled({
    ins("LOADINT", 1, 0, 0, 5),
    ins("LOADINT", 2, 0, 0, 3),
    ins("BAND", 3, 1, 2),
    ins("BOR", 4, 1, 2),
    ins("BXOR", 5, 1, 2),
    ins("BNOT", 6, 1),
    ins("SHL", 7, 1, 2),
    ins("SHR", 8, 1, 2),
    ins("GETGLOBAL", 9, 0, 0, 1),
    ins("MOVE", 10, 3), ins("MOVE", 11, 4), ins("MOVE", 12, 5),
    ins("MOVE", 13, 6), ins("MOVE", 14, 7), ins("MOVE", 15, 8),
    ins("CALL", 9, 6, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw bitwise helpers", bits, "1\t7\t6\t-6\t40\t0")

  local varAll = rawCompiled({
    ins("VARARG", 2, -1, 0, 0),
    ins("GETGLOBAL", 1, 0, 0, 1),
    ins("CALL", 1, -1, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" }, params = 1, vararg = true })
  expectRaw("raw vararg all", varAll, "8\t9", 7, 8, 9)

  local varOne = rawCompiled({
    ins("VARARG", 2, 1, 0, 0),
    ins("GETGLOBAL", 1, 0, 0, 1),
    ins("CALL", 1, 1, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" }, params = 1, vararg = true })
  expectRaw("raw vararg fixed", varOne, "8", 7, 8, 9)

  local list = rawCompiled({
    ins("NEWTABLE", 1),
    ins("LOADINT", 2, 0, 0, 10),
    ins("LOADINT", 3, 0, 0, 20),
    ins("SETTOP", 4),
    ins("SETLIST", 1, 1, 2, -1),
    ins("GETIDXI", 4, 1, 0, 1),
    ins("GETIDXI", 5, 1, 0, 2),
    ins("GETGLOBAL", 6, 0, 0, 1),
    ins("MOVE", 7, 4),
    ins("MOVE", 8, 5),
    ins("CALL", 6, 2, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw setlist top", list, "10\t20")

  local cells = rawCompiled({
    ins("NEWCELL", 1, 0),
    ins("LOADINT", 2, 0, 0, 5),
    ins("SETCELL", 1, 2),
    ins("GETCELL", 3, 1),
    ins("GETGLOBAL", 4, 0, 0, 1),
    ins("MOVE", 5, 3),
    ins("CALL", 4, 1, 0, 0),
    ins("RETURN", 0, 0),
  }, { k = { "print" } })
  expectRaw("raw cells", cells, "5")
end

-- Full-width bit semantics are compared to host operators, not the 53-bit
-- reference VM. Native syntax stays inside test strings for 5.1/5.2 portability.
do
  if math.tointeger and math.maxinteger and math.maxinteger > 2147483647 then
    local specs = {
      {"BAND", "a&b", "__band"}, {"BOR", "a|b", "__bor"},
      {"BXOR", "a~b", "__bxor"}, {"BNOT", "~a", "__bnot"},
      {"SHL", "a<<b", "__shl"}, {"SHR", "a>>b", "__shr"},
    }
    local values = {
      0, 1, 2, 3, -1, -2, -3, math.maxinteger, math.mininteger,
      math.maxinteger-1, math.mininteger+1,
      2147483647, 2147483648, 4294967295, 4294967296, 4294967297,
      -2147483648, -4294967295, -4294967296, -4294967297,
      9007199254740991, 9007199254740992, 9007199254740993,
      -9007199254740993, 1152921504606846976,
      0x12345678*4294967296+0x9abcdef0,
    }
    local shifts = {math.mininteger, math.mininteger+1, math.maxinteger,
      math.maxinteger-1, -1000, 1000}
    for i = -65, 65 do shifts[#shifts+1] = i end
    local invalid = {1.5, -1.5, math.huge, -math.huge, 0/0,
      9223372036854775808.0, "1.5", "not a number", false, {}, function() end}
    local conversions = {1.0, -1.0, "3", "0x10", "9223372036854775807"}
    local seed = 731
    local function random32()
      seed = seed*48271%2147483647
      local high = seed%65536
      seed = seed*48271%2147483647
      return high*65536+seed%65536
    end
    for _, spec in ipairs(specs) do
      local op, expression, event = spec[1], spec[2], spec[3]
      local nativeChunk, nativeErr = loadChunk("return function(a,b) return " ..
        expression .. " end")
      check("integer bits: native reference " .. op, nativeChunk ~= nil, nativeErr)
      local compiled = rawCompiled({ins(op, 3, 1, 2), ins("RETURN", 3, 1)},
        {params = 2})
      compiled.protos[2] = compiled.protos[1]
      compiled.protos[1] = rawCompiled({ins("CLOSURE", 1, 2),
        ins("RETURN", 1, 1)}).protos[1]
      local source = VMGen.generate(compiled, {seed = 0x8B64, decoys = 0})
      local env = makeEnv({})
      local chunk, err = loadGenerated(source, env)
      check("integer bits: generated parses " .. op, chunk ~= nil, err)
      if chunk and nativeChunk then
        local reference, generated = nativeChunk(), chunk()
        local function compare(label, a, b)
          local ok, want = pcall(reference, a, b)
          local gok, got = pcall(generated, a, b)
          check("integer bits: " .. op .. " " .. label,
            ok == gok and (not ok or got == want),
            "native=" .. tostring(want) .. " generated=" .. tostring(got))
          if ok and type(want) == "number" then
            check("integer bits: integer result " .. op .. " " .. label,
              math.type(got) == math.type(want), math.type(got))
          end
        end
        for i, a in ipairs(values) do
          if op == "BNOT" then
            compare("unary " .. i, a)
          else
            local seconds = (op == "SHL" or op == "SHR") and shifts or values
            for j, b in ipairs(seconds) do compare(i .. "/" .. j, a, b) end
          end
        end
        for i = 1, 256 do
          local a = random32()*4294967296+random32()
          local b = random32()*4294967296+random32()
          if op == "SHL" or op == "SHR" then b = (i%129)-64 end
          compare("random " .. i, a, b)
        end
        if op == "SHR" then compare("-1 >> 1", -1, 1) end
        if op == "SHL" then compare("1 << 60", 1, 60) end
        for i, a in ipairs(invalid) do
          compare("invalid lhs " .. i, a, 1)
          if op ~= "BNOT" then compare("invalid rhs " .. i, 1, a) end
          if op == "SHL" or op == "SHR" then
            compare("invalid lhs with oversized shift " .. i, a, math.mininteger)
          end
        end
        compare("nil lhs", nil, 1)
        if op ~= "BNOT" then compare("nil rhs", 1, nil) end
        for i, a in ipairs(conversions) do
          compare("conversion lhs " .. i, a, 1)
          if op ~= "BNOT" then compare("conversion rhs " .. i, 1, a) end
        end

        -- Lookup is raw, left-before-right, with original operand identities.
        -- Unary metamethods receive the operand twice, as native Lua does.
        local token, left, right = {}, {}, {}
        local function method(expectedA, expectedB, result)
          return function(a, b)
            assert(a == expectedA and b == expectedB, "metamethod operands changed")
            return result, "discarded second return"
          end
        end
        local rhs = op == "BNOT" and left or right
        setmetatable(left, {[event] = method(left, rhs, token)})
        setmetatable(right, {[event] = method(left, right, false)})
        compare("left metamethod", left, right)
        check("integer bits: one metamethod return " .. op,
          select("#", generated(left, right)) == 1)
        if op ~= "BNOT" then
          compare("right metamethod", 1, setmetatable(right,
            {[event] = method(1, right, token)}))
          setmetatable(left, {[event] = false})
          compare("false left metamethod does not fall through", left, right)
        end
        local mt = setmetatable({}, {__index = function() error("nonraw lookup") end})
        setmetatable(left, mt)
        compare("raw metamethod lookup", left, 1)
        mt[event] = method(left, op == "BNOT" and left or 1, nil)
        compare("nil metamethod result", left, 1)
        mt[event] = setmetatable({}, {__call = function(_, a, b)
          return method(left, op == "BNOT" and left or 1, token)(a, b)
        end})
        compare("callable metamethod", left, 1)
        if op ~= "BNOT" then
          mt[event] = method(left, -1, token)
          compare("metamethod negative rhs", left, -1)
          mt[event] = method(left, 1.5, token)
          compare("metamethod fractional rhs", left, 1.5)
        end
        mt[event] = method(left, op == "BNOT" and left or 1, token)
        mt.__metatable = "locked"
        compare("protected metatable", left, 1)
        mt.__metatable = {}
        compare("table-protected metatable", left, 1)
        check("integer bits: no runtime evaluation " .. op, env.__sourceLoads == 0)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- 4. Decoy keys are inert when executed
-- ---------------------------------------------------------------------------
do
  local function reject() error("unexpected decoy side effect") end
  local mt = { __eq = reject, __lt = reject, __le = reject, __add = reject }
  local object, other = setmetatable({}, mt), setmetatable({}, mt)
  local cases = { {}, { false, "text", 9 }, { object, other, object },
    { 0 / 0, 0 / 0, false } }
  for i = 1, #VMGen.DECOYS do
    local chunk, err = loadChunk("return function(R,K,U,S,pc) " ..
      "local a,b,c,d=1,2,3,1 " .. VMGen.DECOYS[i] .. " end")
    check("decoy catalog: parses " .. i, chunk ~= nil, err)
    if chunk then
      local handler = chunk()
      for j = 1, #cases do
        local values = cases[j]
        local state = { top = 11 }
        local proxy = setmetatable({}, { __index = state, __newindex = reject })
        local regs = setmetatable({}, { __index = values, __newindex = reject })
        local ok, nextpc = pcall(handler, regs, { other }, {}, proxy, 20)
        check("decoy catalog: inert " .. i .. "/" .. j,
          ok and nextpc == 21 and state.top == 11, nextpc)
      end
    end
  end
end

do
  local src = [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
print(fact(6))
]]
  local compiled = build(src)
  local expected = execute(src)
  local plan = VMGen.randomize(compiled, { seed = 0x8DEC, decoys = 160 })
  check("decoys: program runnable", expected == "720", expected)

  for round = 1, 3 do
    local copy = clonePlan(plan)
    for j = 1, 3 do
      local key = plan.decoys[(round - 1) * 3 + j]
      table.insert(copy.protos[1].c, 1, { key, 200 + j, 7, 9, 3 })
    end
    local generated, stats = emitPlan(copy)
    check("decoys round " .. round .. ": instructions counted",
      stats.instructions == plan.instructions + 3,
      stats.instructions .. " vs " .. (plan.instructions + 3))
    local out, err = runGenerated(generated)
    check("decoys round " .. round .. ": output", out == expected,
      err or ("got=" .. tostring(out) .. " want=" .. tostring(expected)))
  end

  -- A tail of decoys after the final instruction is unreachable but must not
  -- disturb the emitted file or its statistics.
  local loopSrc = [[
local s = 0
for i = 1, 5 do s = s + i end
print(s)
]]
  local loopCompiled = build(loopSrc)
  local loopPlan = VMGen.randomize(loopCompiled, { seed = 0x8DEF, decoys = 160 })
  local loopCopy = clonePlan(loopPlan)
  for j = 1, 8 do
    local key = loopPlan.decoys[8 + j]
    table.insert(loopCopy.protos[#loopCopy.protos].c, { key, 50, 1, 2, 3 })
  end
  local loopOut, loopErr = runGenerated((emitPlan(loopCopy)))
  check("decoys: tail output", loopOut == execute(loopSrc),
    loopErr or tostring(loopOut))

  -- With zero decoys the runtime still works and has no decoy keys.
  local bare = VMGen.generate(compiled, { seed = 0x8DEE, decoys = 0 })
  local bareOut, bareErr = runGenerated(bare)
  check("decoys: zero-decoy build runs", bareOut == expected, bareErr)
  local bareKeys = 0
  for _ in bare:gmatch("%[(%d+)%]=function") do
    bareKeys = bareKeys + 1
  end
  check("decoys: zero-decoy handler count",
    bareKeys == #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE, bareKeys)
end

-- ---------------------------------------------------------------------------
-- 5. Semantic corpus: source == reference VM == generated runtime
-- ---------------------------------------------------------------------------
local corpus = {
  { "arith", [[
local function f(a, b) return a * b + a - b / 2 end
print(f(3, 4), f(-2, 5), 2 ^ 10, 7 % 3, -7 % 3, 1 / 4)
]] },
  { "strings", [[
local s = "ab" .. 1 .. "-" .. 2.5
print(s, #s, ("abc"):upper(), string.rep("xy", 3))
]] },
  { "tables", [[
local t = {10, 20, 30, x = "hi"}
t[4] = 40
t.y = "bye"
print(#t, t[1] + t[2] + t[3] + t[4], t.x, t.y)
]] },
  { "table multi constructor", [[
local function three() return 1, 2, 3 end
local t = {0, three()}
print(#t, t[1], t[2], t[3], t[4])
]] },
  { "table computed keys", [[
local k = "z"
local t = {[k] = 5, [1 + 1] = 7}
print(t.z, t[2], t[k])
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
  { "upvalue write", [[
local x = 1
local function bump() x = x + 1 return x end
print(bump(), bump(), x)
]] },
  { "loop capture", [[
local t = {}
for i = 1, 3 do t[i] = function() return i * 10 end end
print(t[1](), t[2](), t[3]())
]] },
  { "numeric for step break", [[
local s = 0
for i = 10, 1, -3 do
  s = s + i
  if i == 4 then break end
end
print(s)
]] },
  { "numeric for float step", [[
local s = 0
for i = 1, 5 do s = s + i end
for i = 1, 2, 0.5 do s = s + i end
print(s)
]] },
  { "while repeat", [[
local i = 0
while i < 5 do i = i + 1 end
local j = 0
repeat j = j + 2 until j >= 7
print(i, j)
]] },
  { "generic for", [[
local t = {4, 5, 6}
local s = 0
for i, v in ipairs(t) do s = s + i * v end
local h = {a = 1, b = 2, c = 3}
local hsum = 0
for _, v in pairs(h) do hsum = hsum + v end
print(s, hsum)
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
  { "method", [[
local acc = {v = 0}
function acc:add(d) self.v = self.v + d return self end
acc:add(5):add(7)
print(acc.v)
]] },
  { "multi assign", [[
local a, b, c = 1, 2
a, b = b, a
local function two() return 8, 9 end
local x, y, z = two()
print(a, b, c, x, y, z)
]] },
  { "paren truncation", [[
local function f() return 1, 2, 3 end
print((f()))
print(f(), 10)
print(10, f())
]] },
  { "comparisons", [[
print(1 < 2, 2 <= 2, 3 > 1, 3 >= 4, "a" < "b", 1 == 1.0, nil == false)
print(false and 1, true or 2, nil or 3, 0 and 4, not nil, not 0)
]] },
  { "constant operands", [[
local x = 10
print(x + 0.5, x - 0.25, x * 1.5, x / 0.5, x % 2.5, 4 ^ 0.5,
      x + 3, x - 3, x * 3, x / 4, x % 3,
      x == 10.5, x ~= 10.5, x < 10.5, x <= 10.5)
]] },
  { "unary", [[
local a = -5
print(-a, #"hello", not a)
]] },
  { "and or values", [[
local f = false or "fallback"
local g = 1 and 2
print(f, g)
]] },
  { "do scope", [[
local x = 1
do local x = 2 print(x) end
print(x)
]] },
  { "if elseif", [[
local function grade(n)
  if n >= 90 then return "A"
  elseif n >= 80 then return "B"
  elseif n >= 70 then return "C"
  else return "F" end
end
print(grade(95), grade(85), grade(72), grade(10))
]] },
  { "string methods", [[
print(("abc"):sub(2), ("a,b,c"):find(",", 1, true), ("abc"):len())
]] },
  { "global write", [[
gvar = 7
local function bump() gvar = gvar + 1 end
bump()
print(gvar)
]] },
  { "nil padding", [[
local a, b, c = 1
print(a, b, c)
]] },
  { "empty return", [[
local function f() end
print(f(), select("#", f()))
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
  { "sibling closures", [[
local v = 0
local function inc() v = v + 1 end
local function get() return v end
inc() inc()
print(get(), v)
]] },
}

do
  local covered = 0
  for i = 1, #corpus do
    local name, src = corpus[i][1], corpus[i][2]
    local compiled, result, perrors = build(src)
    check(name .. ": pipeline clean", compiled ~= nil and #perrors == 0 and
      result ~= nil and #result.errors == 0,
      errorText(perrors) .. (result and errorText(result.errors) or ""))
    if compiled and #perrors == 0 then
      local problems = Compiler.validate(compiled)
      check(name .. ": bytecode valid", #problems == 0, problems[1])

      local expected = execute(src)
      check(name .. ": source runnable", expected ~= nil, expected)

      local ref, rerr = runVm(compiled)
      check(name .. ": reference VM", ref == expected,
        rerr or ("ref=" .. tostring(ref)))

      local generated = VMGen.generate(compiled,
        { seed = 0x8D10 + i * 131, decoys = 160 })
      local out, err = runGenerated(generated)
      check(name .. ": generated runtime", out == expected,
        err or ("got=" .. tostring(out) .. " want=" .. tostring(expected)))
      covered = covered + 1
    end
  end
  notes[#notes + 1] = string.format("MODULE8_CORPUS %d/%d", covered, #corpus)
end

-- ---------------------------------------------------------------------------
-- 6. Global isolation and scale
-- ---------------------------------------------------------------------------
do
  local src = "claxProbe8 = 7 print(claxProbe8)"
  local compiled = build(src)
  local generated = VMGen.generate(compiled, { seed = 0x8D77, decoys = 160 })
  local out, err = runGenerated(generated)
  check("isolation: output", out == "7", err or tostring(out))
  check("isolation: host globals untouched", rawget(_G, "claxProbe8") == nil)
end

do
  local blocks = 120
  local lines = { "local s = 0", "local t = {}" }
  for i = 1, blocks do
    lines[#lines + 1] = "s = s + " .. i
    lines[#lines + 1] = "t[" .. i .. "] = s % 97"
    lines[#lines + 1] = "if s > 1000 then s = s - 3 end"
  end
  lines[#lines + 1] =
    "local function total(n) local r = 0 for i = 1, n do r = r + t[i] end return r end"
  lines[#lines + 1] = "print(s, total(" .. blocks .. "), #t)"
  local big = table.concat(lines, "\n")
  local lineCount = 1
  for _ in big:gmatch("\n") do lineCount = lineCount + 1 end

  local expected = execute(big)

  local started = os.clock()
  local compiled, result, perrors = build(big)
  local builtMs = (os.clock() - started) * 1000

  check("scale: pipeline clean", compiled ~= nil and #perrors == 0 and
    result ~= nil and #result.errors == 0, errorText(perrors))

  if compiled and #perrors == 0 then
    started = os.clock()
    local generated, stats = VMGen.generate(compiled,
      { seed = 0x8D88, decoys = 160 })
    local genMs = (os.clock() - started) * 1000
    local out, err = runGenerated(generated)
    check("scale: output", expected ~= nil and out == expected,
      err or ("got=" .. tostring(out) .. " want=" .. tostring(expected)))
    check("scale: build under ten seconds", (builtMs + genMs) < 10000,
      builtMs + genMs)
    check("scale: generation deterministic",
      VMGen.generate(compiled, { seed = 0x8D88, decoys = 160 }) == generated)
    check("scale: instructions", stats.instructions ==
      compiled.stats.instructions, stats.instructions)
    notes[#notes + 1] = string.format(
      "MODULE8_SCALE lines=%d protos=%d instr=%d bytes=%d build_ms=%.1f gen_ms=%.1f",
      lineCount, stats.protos, stats.instructions, stats.bytes, builtMs, genMs)
  end
end

-- ---------------------------------------------------------------------------
-- 7. Performance sample (reported, not asserted: the 3x budget is measured on
--    the layer 7-12 artifact at M12)
-- ---------------------------------------------------------------------------
do
  local src = [[
local function work(n)
  local s = 0
  for i = 1, n do
    if i % 3 == 0 then s = s + i else s = s - 1 end
  end
  return s
end
print(work(10000))
]]
  local compiled = build(src)
  local generated = VMGen.generate(compiled, { seed = 0x8D99, decoys = 160 })
  local expected = execute(src)
  local vmOut, vmErr = runGenerated(generated)
  check("perf: output", vmOut == expected, vmErr or tostring(vmOut))

  local nativeRuns = 20
  local t0 = os.clock()
  for _ = 1, nativeRuns do execute(src) end
  local nativeTime = os.clock() - t0
  t0 = os.clock()
  runGenerated(generated)
  local vmTime = os.clock() - t0
  local ratio = 0
  if nativeTime > 0 then
    ratio = vmTime / (nativeTime / nativeRuns)
  end
  notes[#notes + 1] = string.format(
    "MODULE8_PERF native_ms=%.2f vm_ms=%.2f ratio=%.1fx runs=%d",
    nativeTime * 1000 / nativeRuns, vmTime * 1000, ratio, nativeRuns)
end

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------
local function emit(line)
  if __out then
    __out[#__out + 1] = line
  else
    io.write(line .. "\n")
  end
end

local mod8Decoys = 160
local mod8Total = #Compiler.OPS * VMGen.ENCODINGS_PER_OPCODE + mod8Decoys
notes[#notes + 1] = string.format(
  "MODULE8_KEYS real=%d aliases=%d decoy=%d total=%d unused=%d",
  #Compiler.OPS, #Compiler.OPS * (VMGen.ENCODINGS_PER_OPCODE - 1), mod8Decoys,
  mod8Total, VMGen.KEY_RANGE - mod8Total)
notes[#notes + 1] = string.format("MODULE8_CHECKS %d/%d",
  checks - failures, checks)
for i = 1, #notes do emit(notes[i]) end
emit("MODULE8_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
