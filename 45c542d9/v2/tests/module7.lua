-- module7.lua -- acceptance tests for the register bytecode compiler (layer 7).
--
-- Pipeline under test: parse -> analyze/rename -> consts -> flatten -> opaque
-- -> strings -> compiler. The compiled program is executed by tests/vmref.lua,
-- a reference interpreter for the layer 7 ISA, on all five hosts and compared
-- with the source program. Syntax a host cannot parse (Luau `continue` and
-- `if` expressions, Lua 5.3 operators, Lua 5.2+ `goto`) is compared with a
-- hand-computed expected string instead of a native run.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Consts = require("src.consts")
local Flatten = require("src.flatten")
local Opaque = require("src.opaque")
local Strings = require("src.strings")
local Compiler = require("src.compiler")
local VM = require("tests.vmref")

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

local unpackValues = table.unpack or unpack

local function pack(...)
  return { n = select("#", ...), ... }
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

local HOST = _VERSION
local hasBitwise = HOST == "Lua 5.3" or HOST == "Lua 5.4"
local hasGoto = HOST ~= "Lua 5.1"

-- ---------------------------------------------------------------- execution
local loadChunk = loadstring or load

local function execute(src)
  local out = {}
  local env = setmetatable({}, { __index = _G })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(src, "@program")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@program", "t", env)
  end
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function runVm(compiled, env)
  local out = {}
  env = env or setmetatable({}, { __index = _G })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(VM.run, compiled, env)
  if not ok then return nil, tostring(err) end
  return table.concat(out, "\n")
end

-- --------------------------------------------------------------- pipelines
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

local coverage = {}

local function cover(compiled)
  for op in pairs(compiled.stats.used) do coverage[op] = true end
end

local function runCase(name, src, opts)
  opts = opts or {}
  local compiled, result, perrors = build(src, opts)
  check(name .. ": parse clean", #perrors == 0, errorText(perrors))
  check(name .. ": analyze clean", result ~= nil and #result.errors == 0,
    result and errorText(result.errors))
  check(name .. ": compile clean",
    compiled ~= nil and #compiled.errors == 0,
    compiled and errorText(compiled.errors))
  if not compiled or #compiled.errors > 0 then return end

  local problems = Compiler.validate(compiled)
  check(name .. ": bytecode valid", #problems == 0, problems[1])
  cover(compiled)

  local expected = opts.expected
  if expected == nil then
    local native, nerr = execute(src)
    check(name .. ": source runnable", native ~= nil, nerr)
    expected = native
  end

  local vmOut, verr = runVm(compiled)
  check(name .. ": output", expected ~= nil and vmOut == expected,
    verr or ("vm=" .. tostring(vmOut) .. " want=" .. tostring(expected)))

  if opts.native and opts.expected ~= nil then
    local native = execute(src)
    check(name .. ": native agrees", native == opts.expected,
      "native=" .. tostring(native) .. " want=" .. tostring(opts.expected))
  end
  return compiled
end

-- ---------------------------------------------------------------------------
-- 1. Opcode catalog and handler completeness
-- ---------------------------------------------------------------------------
do
  local ops = Compiler.OPS
  check("catalog: exactly 80 opcodes", #ops == 80, #ops)
  check("catalog: OPCOUNT matches", Compiler.OPCOUNT == 80, Compiler.OPCOUNT)

  local seen, dup = {}, nil
  for i = 1, #ops do
    if seen[ops[i]] then dup = ops[i] end
    seen[ops[i]] = true
    if type(ops[i]) ~= "string" or not ops[i]:match("^[A-Z]+$") then
      dup = dup or tostring(ops[i])
    end
  end
  check("catalog: unique upper-case names", dup == nil, dup)

  local missing, extra = {}, {}
  local handlerCount = 0
  for i = 1, #ops do
    if not VM.implemented[ops[i]] then missing[#missing + 1] = ops[i] end
  end
  for name in pairs(VM.implemented) do
    handlerCount = handlerCount + 1
    if not seen[name] then extra[#extra + 1] = name end
  end
  check("handlers: every opcode implemented", #missing == 0,
    table.concat(missing, " "))
  check("handlers: no unknown handlers", #extra == 0,
    table.concat(extra, " "))
  check("handlers: count matches catalog", handlerCount == 80, handlerCount)
end

-- ---------------------------------------------------------------------------
-- 2. Direct handler tests for opcodes the compiler does not emit
-- ---------------------------------------------------------------------------
do
  local function ins(op, a, b, c, d)
    return { op = op, a = a or 0, b = b or 0, c = c or 0, d = d or 0 }
  end
  local function proto(code, opts)
    opts = opts or {}
    return {
      code = code, k = opts.k or {}, updesc = opts.updesc or {},
      params = opts.params or 0, vararg = opts.vararg or false,
      maxstack = opts.maxstack or 8,
    }
  end
  local function tryProto(p, env, ...)
    local args = pack(...)
    local ok, res = pcall(function()
      return pack(VM.run({ protos = { p } }, env, unpackValues(args, 1, args.n)))
    end)
    return ok, res
  end

  local ok, res = tryProto(proto({
    ins("LOADINT", 1, 0, 0, 5), ins("NOP"), ins("RETURN", 1, 1),
  }))
  check("handler NOP", ok and res.n == 1 and res[1] == 5, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADINT", 1, 0, 0, 5), ins("CLOSE", 1), ins("RETURN", 1, 1),
  }))
  check("handler CLOSE", ok and res.n == 1 and res[1] == 5, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADBOOL", 1, 1), ins("BOOL", 1, 1, 1), ins("RETURN", 1, 1),
  }))
  check("handler BOOL invert", ok and res.n == 1 and res[1] == false, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADBOOL", 1, 0), ins("BOOL", 1, 1, 0), ins("RETURN", 1, 1),
  }))
  check("handler BOOL truth", ok and res.n == 1 and res[1] == false, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADBOOL", 1, 1), ins("TEST", 1, 1),
    ins("LOADINT", 2, 0, 0, 99), ins("LOADINT", 2, 0, 0, 7),
    ins("RETURN", 2, 1),
  }))
  check("handler TEST skip", ok and res[1] == 7, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADBOOL", 1, 1), ins("TEST", 0, 1),
    ins("LOADINT", 2, 0, 0, 99), ins("RETURN", 2, 1),
  }))
  check("handler TEST fallthrough", ok and res[1] == 99, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADBOOL", 1, 1), ins("LOADNIL", 3), ins("TESTSET", 1, 1, 3),
    ins("LOADINT", 3, 0, 0, 42), ins("RETURN", 3, 1),
  }))
  check("handler TESTSET", ok and res[1] == true, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADNIL", 1), ins("TESTNIL", 0, 1),
    ins("LOADINT", 2, 0, 0, 42), ins("LOADINT", 2, 0, 0, 7),
    ins("RETURN", 2, 1),
  }))
  check("handler TESTNIL", ok and res[1] == 7, tostring(res))

  ok, res = tryProto(proto({
    ins("LOADINT", 1, 0, 0, 1), ins("LOADINT", 2, 0, 0, 2),
    ins("SETTOP", 2), ins("RETURN", 1, -1),
  }))
  check("handler SETTOP", ok and res.n == 1 and res[1] == 1, tostring(res))

  ok, res = tryProto(proto({
    ins("VARARG", 1, -1), ins("RETURN", 1, -1),
  }, { vararg = true }), nil, 5, 6, 7)
  check("handler VARARG multi", ok and res.n == 3 and res[1] == 5 and
    res[2] == 6 and res[3] == 7, tostring(res))

  ok, res = tryProto(proto({ ins("WAT") }))
  check("handler unknown opcode errors", not ok and
    tostring(res):find("unknown opcode", 1, true) ~= nil, tostring(res))

  local okRun, errRun = pcall(VM.run, { protos = {} }, {})
  check("handler empty program errors", not okRun and
    tostring(errRun):find("no prototypes", 1, true) ~= nil, tostring(errRun))
end

-- ---------------------------------------------------------------------------
-- 3. Structural validation and compile-error reporting
-- ---------------------------------------------------------------------------
do
  local function ins(op, a, b, c, d)
    return { op = op, a = a or 0, b = b or 0, c = c or 0, d = d or 0 }
  end
  local function problems(protos)
    return #Compiler.validate({ protos = protos })
  end

  check("validate: no prototypes", problems({}) > 0)
  check("validate: constant index",
    problems({ { code = { ins("LOADK", 1, 0, 0, 9) }, k = {},
      updesc = {}, maxstack = 1 } }) > 0)
  check("validate: jump range",
    problems({ { code = { ins("JMP", 0, 0, 0, 99) }, k = {},
      updesc = {}, maxstack = 1 } }) > 0)
  check("validate: unknown opcode",
    problems({ { code = { ins("WAT") }, k = {}, updesc = {}, maxstack = 1 } }) > 0)
  check("validate: prototype index",
    problems({ { code = { ins("CLOSURE", 1, 3) }, k = {},
      updesc = {}, maxstack = 1 } }) > 0)
  check("validate: maxstack",
    problems({ { code = {}, k = {}, updesc = {}, maxstack = 0 } }) > 0)

  local function specimen(code)
    return { protos = { { code = code or { ins("RETURN", 0, 0) },
      k = { 7 }, updesc = {}, maxstack = 8, params = 0, vararg = true } } }
  end
  local function validates(name, value, expected, diagnostic)
    local ok, list = pcall(Compiler.validate, value)
    local safe = ok and type(list) == "table" and #list <= 40
    if safe then
      for i = 1, #list do if type(list[i]) ~= "string" then safe = false end end
    end
    local text = safe and table.concat(list, " | ") or tostring(list)
    check("validate: " .. name, safe and ((#list == 0) == expected) and
      (not diagnostic or text:find(diagnostic, 1, true) ~= nil), text)
  end
  validates("nil program is total", nil, false, "compiled program")
  for _, value in ipairs({ false, 1, "program", function() end, {} }) do
    validates("malformed program " .. type(value), value, false)
  end
  local hostile = setmetatable({}, {
    __index = function() error("unexpected indexing") end,
    __len = function() error("unexpected length") end,
    __pairs = function() error("unexpected iteration") end,
    __tostring = function() error("unexpected formatting") end,
  })
  validates("metatable is not executed", hostile, false)
  local shapes = {
    { "missing protos", function(p) p.protos = nil end },
    { "non-table protos", function(p) p.protos = 1 end },
    { "sparse protos", function(p) p.protos[3] = p.protos[1] end },
    { "non-table proto", function(p) p.protos[1] = false end },
    { "missing code", function(p) p.protos[1].code = nil end },
    { "non-table code", function(p) p.protos[1].code = "code" end },
    { "empty code", function(p) p.protos[1].code = {} end },
    { "sparse code", function(p) p.protos[1].code[3] = ins("NOP") end },
    { "non-table instruction", function(p) p.protos[1].code[1] = false end },
    { "hostile instruction", function(p) p.protos[1].code[1] = hostile end },
    { "hostile opcode", function(p) p.protos[1].code[1].op = hostile end },
    { "missing constants", function(p) p.protos[1].k = nil end },
    { "sparse constants", function(p) p.protos[1].k[3] = 1 end },
    { "unsupported constant", function(p) p.protos[1].k[1] = {} end },
    { "missing updesc", function(p) p.protos[1].updesc = nil end },
    { "non-table updesc", function(p) p.protos[1].updesc = false end },
    { "missing maxstack", function(p) p.protos[1].maxstack = nil end },
    { "string maxstack", function(p) p.protos[1].maxstack = "8" end },
    { "fractional maxstack", function(p) p.protos[1].maxstack = 8.5 end },
    { "infinite maxstack", function(p) p.protos[1].maxstack = math.huge end },
    { "nan maxstack", function(p) p.protos[1].maxstack = 0/0 end },
    { "bad params", function(p) p.protos[1].params = "0" end },
    { "negative params", function(p) p.protos[1].params = -1 end },
    { "fractional params", function(p) p.protos[1].params = 0.5 end },
    { "params outside frame", function(p) p.protos[1].params = 9 end },
    { "bad vararg flag", function(p) p.protos[1].vararg = 1 end },
    { "compiled errors", function(p) p.errors = { { msg = "failed" } } end },
    { "malformed errors", function(p) p.errors = false end },
  }
  for _, case in ipairs(shapes) do
    local p = specimen()
    case[2](p)
    validates(case[1], p, false)
  end
  local malformed = {
    { "missing register", { op = "MOVE", b = 1 } },
    { "fractional register", ins("MOVE", 1.5, 1) },
    { "string register", ins("MOVE", "1", 1) },
    { "zero register", ins("MOVE", 1, 0) },
    { "negative register", ins("ADD", 1, 1, -1) },
    { "source outside frame", ins("MOVE", 1, 9) },
    { "destination outside frame", ins("LOADNIL", 9) },
    { "nan register", ins("MOVE", 0/0, 1) },
    { "infinite register", ins("MOVE", math.huge, 1) },
    { "nonnumeric unused operand", ins("NOP", 0, "ignored") },
    { "nil run window", ins("LOADNILN", 8, 0, 0, 2) },
    { "negative nil count", ins("LOADNILN", 1, 0, 0, -1) },
    { "self window", ins("SELF", 8, 1, 0, 1) },
    { "cell source", ins("NEWCELL", 1, 9) },
    { "negative cell source", ins("NEWCELL", 1, -1) },
    { "setlist window", ins("SETLIST", 1, 1, 8, 2) },
    { "setlist fractional count", ins("SETLIST", 1, 1, 2, 1.5) },
    { "call arguments", ins("CALL", 8, 1, 0, 0) },
    { "call results", ins("CALL", 1, 0, 2, 8) },
    { "call result default window", ins("CALL", 8, 0, 2, 0) },
    { "negative call destination", ins("CALL", 1, 0, 0, -1) },
    { "fractional call destination", ins("CALL", 1, 0, 1, 1.5) },
    { "bad argument sentinel", ins("CALL", 1, -2, 0, 0) },
    { "bad result sentinel", ins("CALL", 1, 0, -2, 0) },
    { "tailcall arguments", ins("TAILCALL", 8, 1) },
    { "return window", ins("RETURN", 8, 2) },
    { "zero open return base", ins("RETURN", 0, -1) },
    { "vararg window", ins("VARARG", 8, 2) },
    { "bad vararg sentinel", ins("VARARG", 1, -2) },
    { "top outside frame", ins("SETTOP", 10) },
    { "zero stack top", ins("SETTOP", 0) },
    { "forprep window", ins("FORPREP", 7, 0, 0, -1) },
    { "forloop window", ins("FORLOOP", 6, 0, 0, -1) },
    { "tforloop window", ins("TFORLOOP", 6, 0, 0, -1) },
    { "tforcall window", ins("TFORCALL", 5, 2) },
    { "tforcall negative count", ins("TFORCALL", 1, -1) },
    { "close outside frame", ins("CLOSE", 10) },
    { "bad boolean flag", ins("LOADBOOL", 1, 2) },
    { "bad test destination", ins("TESTSET", 0, 1, 9) },
    { "fractional jump", ins("JMP", 0, 0, 0, 0.5) },
    { "missing jump", { op = "JMP" } },
    { "nonfinite jump", ins("JMP", 0, 0, 0, math.huge) },
    { "fractional closure index", ins("CLOSURE", 1, 1.5) },
    { "upvalue index", ins("GETUPVAL", 1, 1) },
  }
  for _, case in ipairs(malformed) do
    validates(case[1], specimen({ case[2], ins("RETURN", 0, 0) }), false)
  end
  for _, name in ipairs({ "LOADK", "GETGLOBAL", "SETGLOBAL", "GETFIELD",
      "SETFIELD", "SELF", "ADDK", "SUBK", "MULK", "DIVK", "MODK",
      "POWK", "IDIVK", "EQK", "NEK", "LTK", "LEK" }) do
    for _, index in ipairs({ 0, -1, 1.5, 2, math.huge, 0/0 }) do
      validates(name .. " invalid constant " .. tostring(index),
        specimen({ ins(name, 1, 2, 0, index) }), false)
    end
  end
  for _, name in ipairs({ "JMP", "JMPF", "JMPT", "FORPREP", "FORLOOP", "TFORLOOP" }) do
    validates(name .. " one-past-code", specimen({ ins(name, 1, 0, 0, 0) }),
      false, "jump out of range")
    validates(name .. " target zero", specimen({ ins(name, 1, 0, 0, -2) }),
      false, "jump out of range")
    validates(name .. " current pc", specimen({ ins(name, 1, 0, 0, -1) }), true)
  end
  for _, name in ipairs({ "TEST", "TESTSET", "TESTNIL" }) do
    validates(name .. " skip past code", specimen({ ins(name, 0, 1, 2) }),
      false, "skip target")
  end
  local fixed = specimen({ ins("VARARG", 1, 1) })
  fixed.protos[1].vararg = false
  validates("vararg requires flag", fixed, false, "non-vararg")

  local function captured(desc)
    local p = specimen({ ins("NEWCELL", 8, 0), ins("CLOSURE", 1, 2), ins("RETURN", 0, 0) })
    p.protos[2] = specimen({ ins("GETUPVAL", 1, 1), ins("SETUPVAL", 1, 1),
      ins("CLOSURE", 2, 3), ins("RETURN", 0, 0) }).protos[1]
    p.protos[2].updesc = { desc }
    p.protos[3] = specimen({ ins("GETUPVAL", 1, 1), ins("RETURN", 0, 0) }).protos[1]
    p.protos[3].updesc = { { 0, 1 } }
    return p
  end
  validates("enclosing register and inherited upvalue", captured({ 1, 8 }), true)
  for _, desc in ipairs({ false, {}, { 1 }, { 2, 1 }, { 0, 0 }, { 1, 0 },
      { 1, -1 }, { 1, 1.5 }, { 0, 1.5 }, { 1, "1" }, { 1, math.huge },
      { 1, 9 }, { 0, 1 }, { 1, 1, 1 }, hostile }) do
    validates("malformed capture", captured(desc), false)
  end
  local inherited = captured({ 1, 8 })
  inherited.protos[3].updesc[1][2] = 2
  validates("inherited capture bound", inherited, false, "closure capture")
  local root = specimen()
  root.protos[1].updesc = { { 1, 1 } }
  validates("entry has no enclosing frame", root, false, "entry cannot capture")

  validates("legal empty and open windows", specimen({
    ins("NEWCELL", 1, 0), ins("CLOSE", 0), ins("CLOSE", 9), ins("SETTOP", 9),
    ins("LOADNILN", 9, 0, 0, 0), ins("SELF", 7, 1, 0, 1),
    ins("SETLIST", 1, -2, 8, 1), ins("SETLIST", 1, 1, 8, -1),
    ins("CALL", 8, 0, 1, 0), ins("CALL", 8, -1, -1, 1),
    ins("CALL", 8, 0, 0, 9), ins("TFORCALL", 6, 0),
    ins("VARARG", 8, -1), ins("VARARG", 9, 0), ins("RETURN", 9, 0),
    ins("RETURN", 8, -1), ins("RETURN", 0, 0),
  }), true)
  local literals = specimen({ ins("LOADINT", 1, 0, 0, -1/math.huge),
    ins("ADDI", 1, 1, 0, 0.25), ins("LOADK", 2, 0, 0, 2), ins("RETURN", 0, 0) })
  literals.protos[1].k = { false, math.huge, -math.huge, 0/0 }
  validates("numeric payloads are not register indices", literals, true)
  local many = {}
  for i = 1, 100 do many[i] = ins("MOVE", 0, 0) end
  validates("bounded diagnostics", specimen(many), false)

  for _, source in ipairs({ "", "if true then return 1 end",
      "if false then return 1 else return 2 end", "while false do break end",
      "repeat break until true", "goto done ::done::",
      "local function f() if true then return end end" }) do
    local p = build(source, { raw = true })
    validates("compiler terminal labels: " .. source, p, true)
    for _, proto in ipairs(p.protos) do
      check("compile: explicit final return", proto.code[#proto.code].op == "RETURN")
    end
  end

  local ast = parse("local x = 1 print(x)")
  ast.children[#ast.children + 1] =
    { type = "Bogus", line = 1, col = 1, children = {} }
  local ok, compiled = pcall(Compiler.compile, ast, {})
  check("compile error: reported not thrown",
    ok and compiled ~= nil and #compiled.errors == 1,
    ok and compiled and errorText(compiled.errors) or tostring(compiled))

  local flat = parse("local x = 1 print(x)")
  local fine = Compiler.compile(flat, {})
  check("validate: clean tree accepted", #Compiler.validate(fine) == 0)
  local a, b, c, d = fine.protos[1].code[1].a, fine.protos[1].code[1].b,
    fine.protos[1].code[1].c, fine.protos[1].code[1].d
  check("validate: instruction fields numeric", type(a) == "number" and
    type(b) == "number" and type(c) == "number" and type(d) == "number")
end

-- ---------------------------------------------------------------------------
-- 4. Semantic corpus through the full pipeline
-- ---------------------------------------------------------------------------
runCase("arith", [[
local function f(a, b) return a * b + a - b / 2 end
print(f(3, 4), f(-2, 5), 2 ^ 10, 7 % 3, -7 % 3, 1 / 4)
]])

runCase("strings", [[
local s = "ab" .. 1 .. "-" .. 2.5
print(s, #s, ("abc"):upper(), string.rep("xy", 3))
]])

runCase("tables", [[
local t = {10, 20, 30, x = "hi"}
t[4] = 40
t.y = "bye"
print(#t, t[1] + t[2] + t[3] + t[4], t.x, t.y)
]])

runCase("table multi constructor", [[
local function three() return 1, 2, 3 end
local t = {0, three()}
print(#t, t[1], t[2], t[3], t[4])
]])

runCase("table computed keys", [[
local k = "z"
local t = {[k] = 5, [1 + 1] = 7}
print(t.z, t[2], t[k])
]])

runCase("recursion", [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fact(7), fib(10))
]])

runCase("closures", [[
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local c = counter(10)
print(c(1), c(2), c(3))
]])

runCase("upvalue write", [[
local x = 1
local function bump() x = x + 1 return x end
print(bump(), bump(), x)
]])

runCase("loop capture", [[
local t = {}
for i = 1, 3 do t[i] = function() return i * 10 end end
print(t[1](), t[2](), t[3]())
]])

runCase("numeric for step break", [[
local s = 0
for i = 10, 1, -3 do
  s = s + i
  if i == 4 then break end
end
print(s)
]])

runCase("numeric for float step", [[
local s = 0
for i = 1, 5 do s = s + i end
for i = 1, 2, 0.5 do s = s + i end
print(s)
]])

runCase("while repeat", [[
local i = 0
while i < 5 do i = i + 1 end
local j = 0
repeat j = j + 2 until j >= 7
print(i, j)
]])

runCase("generic for", [[
local t = {4, 5, 6}
local s = 0
for i, v in ipairs(t) do s = s + i * v end
local h = {a = 1, b = 2, c = 3}
local hsum = 0
for _, v in pairs(h) do hsum = hsum + v end
print(s, hsum)
]])

runCase("varargs", [[
local function f(...) local n = select("#", ...) return n, ... end
print(f(1, nil, 3))
local function sum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s
end
print(sum(1, 2, 3, 4))
]])

runCase("method", [[
local acc = {v = 0}
function acc:add(d) self.v = self.v + d return self end
acc:add(5):add(7)
print(acc.v)
]])

runCase("multi assign", [[
local a, b, c = 1, 2
a, b = b, a
local function two() return 8, 9 end
local x, y, z = two()
print(a, b, c, x, y, z)
]])

runCase("paren truncation", [[
local function f() return 1, 2, 3 end
print((f()))
print(f(), 10)
print(10, f())
]])

runCase("comparisons", [[
print(1 < 2, 2 <= 2, 3 > 1, 3 >= 4, "a" < "b", 1 == 1.0, nil == false)
print(false and 1, true or 2, nil or 3, 0 and 4, not nil, not 0)
]])

runCase("constant operands", [[
local x = 10
print(x + 0.5, x - 0.25, x * 1.5, x / 0.5, x % 2.5, 4 ^ 0.5,
      x + 3, x - 3, x * 3, x / 4, x % 3,
      x == 10.5, x ~= 10.5, x < 10.5, x <= 10.5)
]])

runCase("unary", [[
local a = -5
print(-a, #"hello", not a)
]])

runCase("and or values", [[
local f = false or "fallback"
local g = 1 and 2
print(f, g)
]])

runCase("do scope", [[
local x = 1
do local x = 2 print(x) end
print(x)
]])

runCase("if elseif", [[
local function grade(n)
  if n >= 90 then return "A"
  elseif n >= 80 then return "B"
  elseif n >= 70 then return "C"
  else return "F" end
end
print(grade(95), grade(85), grade(72), grade(10))
]])

runCase("string methods", [[
print(("abc"):sub(2), ("a,b,c"):find(",", 1, true), ("abc"):len())
]])

runCase("global write", [[
gvar = 7
local function bump() gvar = gvar + 1 end
bump()
print(gvar)
]])

runCase("nil padding", [[
local a, b, c = 1
print(a, b, c)
]])

runCase("empty return", [[
local function f() end
print(f(), select("#", f()))
]])

runCase("nested upvalues", [[
local function outer(a)
  local b = a * 2
  local function middle(c)
    local function inner(d) return a + b + c + d end
    return inner(4)
  end
  return middle(3)
end
print(outer(1))
]])

runCase("sibling closures", [[
local v = 0
local function inc() v = v + 1 end
local function get() return v end
inc() inc()
print(get(), v)
]])

-- ---------------------------------------------------------------------------
-- 5. Compiler on the raw AST (no flatten/opaque/strings)
-- ---------------------------------------------------------------------------
runCase("raw arithmetic", [[
local s = 0
for i = 1, 6 do s = s + i * i end
if s > 90 then s = s - 1 end
print(s)
]], { raw = true })

runCase("raw closures", [[
local function mk(n)
  return function(d) n = n + d return n end
end
local a = mk(1)
print(a(2), a(3))
]], { raw = true })

runCase("raw method", [[
local t = {v = 2}
function t:add(x) self.v = self.v + x return self.v end
print(t:add(5), t.v)
]], { raw = true })

runCase("raw table multi", [[
local function f() return "x", "y" end
local t = {1, f()}
print(#t, t[1], t[2], t[3])
]], { raw = true })

runCase("raw multi return", [[
local function f() return 1, nil, 3 end
local a, b, c, d = f()
print(a, b, c, d)
]], { raw = true })

runCase("raw constant arithmetic", [[
local x = 8
print(x / 0.5, x ^ 0.5, x % 2.5, x + 0.5, x - 0.25, x * 1.5)
]], { raw = true })

runCase("raw integer division by constant", [[
local x = 10
print(string.format("%d %d", x // 2.5, x // 3))
]], { raw = true, expected = "4 3", native = hasBitwise })

runCase("raw continue", [[
local s = 0
for i = 1, 6 do
  if i % 2 == 0 then continue end
  s = s + i
end
print(s)
]], { raw = true, expected = "9", native = false })

runCase("raw if expression", [[
local function pick(a, b) return if a > b then a else b end
print(pick(3, 9), pick(9, 3))
]], { raw = true, expected = "9\t9", native = false })

-- ---------------------------------------------------------------------------
-- 6. Host-gated syntax
-- ---------------------------------------------------------------------------
runCase("bitwise", [[
print(5 & 3, 5 | 2, 5 ~ 1, ~0, 1 << 4, 256 >> 3, ~5)
]], { expected = "1\t7\t4\t-1\t16\t32\t-6", native = hasBitwise })

runCase("integer division", [[
print(string.format("%d %d %d %d", 7 // 2, -7 // 2, 7 // -2, -7 // -2))
print(7 % -3, -7 % 3)
]], { expected = "3 -4 -4 3\n-2\t2", native = hasBitwise })

runCase("integer division by constant", [[
local x = 10
print(string.format("%d %d %d", x // 2.5, x // 3, x // 0.5))
]], { expected = "4 3 20", native = hasBitwise })

runCase("goto", [[
local i = 0
::again::
i = i + 1
if i < 4 then goto again end
print(i)
]], { expected = "4", native = hasGoto })

runCase("continue for", [[
local s = 0
for i = 1, 6 do
  if i % 2 == 0 then continue end
  s = s + i
end
print(s)
]], { expected = "9", native = false })

runCase("continue while", [[
local i, n = 0, 0
while i < 6 do
  i = i + 1
  if i == 4 then continue end
  n = n + i
end
print(n)
]], { expected = "17", native = false })

runCase("continue repeat", [[
local i, s = 0, 0
repeat
  i = i + 1
  if i % 2 == 0 then continue end
  s = s + i
until i >= 5
print(s)
]], { expected = "9", native = false })

runCase("if expression", [[
local function pick(a, b) return if a > b then a else b end
print(pick(3, 9), pick(9, 3))
]], { expected = "9\t9", native = false })

-- ---------------------------------------------------------------------------
-- 7. String layer integration
-- ---------------------------------------------------------------------------
do
  local src = 'print("alpha", "beta", "gamma")'
  local compiled = build(src)
  check("strings: compile clean", compiled and #compiled.errors == 0,
    compiled and errorText(compiled.errors))

  local found = {}
  for pi = 1, #compiled.protos do
    local k = compiled.protos[pi].k
    for i = 1, #k do
      if type(k[i]) == "string" then
        if k[i]:find("alpha", 1, true) or k[i]:find("beta", 1, true) or
           k[i]:find("gamma", 1, true) then
          found[#found + 1] = k[i]
        end
      end
    end
  end
  check("strings: no plaintext constants", #found == 0, found[1])
  check("strings: decoder compiled", compiled.stats.protos >= 2,
    compiled.stats.protos)

  local out, err = runVm(compiled)
  check("strings: output", out == execute(src), err or tostring(out))
end

-- ---------------------------------------------------------------------------
-- 8. Determinism
-- ---------------------------------------------------------------------------
do
  local function sameCode(x, y)
    return x.op == y.op and x.a == y.a and x.b == y.b and
      x.c == y.c and x.d == y.d
  end
  local function sameCompiled(a, b)
    if #a.protos ~= #b.protos then return false, "proto count" end
    for i = 1, #a.protos do
      local P, Q = a.protos[i], b.protos[i]
      if #P.code ~= #Q.code then return false, "code length " .. i end
      if #P.k ~= #Q.k then return false, "constant count " .. i end
      if #P.updesc ~= #Q.updesc then return false, "updesc count " .. i end
      if P.params ~= Q.params or P.vararg ~= Q.vararg or
         P.maxstack ~= Q.maxstack then
        return false, "header " .. i
      end
      for j = 1, #P.code do
        if not sameCode(P.code[j], Q.code[j]) then
          return false, "instruction " .. i .. "@" .. j
        end
      end
      for j = 1, #P.k do
        if P.k[j] ~= Q.k[j] then return false, "constant " .. i .. "@" .. j end
      end
      for j = 1, #P.updesc do
        if P.updesc[j][1] ~= Q.updesc[j][1] or
           P.updesc[j][2] ~= Q.updesc[j][2] then
          return false, "updesc " .. i .. "@" .. j
        end
      end
    end
    return true
  end

  local src = [[
local function outer(a)
  local n = a
  return function(b) n = n + b return n end
end
local f = outer(1)
for i = 1, 4 do f(i) end
print(f(0))
]]
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  Consts.run(ast, { seed = 0x0C057A })
  Flatten.run(ast, { seed = 3 })
  Opaque.run(ast, { seed = 5, prob = 0.6 })
  Strings.run(ast, { seed = 0x5CE41D })

  local first = Compiler.compile(ast, {})
  local second = Compiler.compile(ast, {})
  local same, why = sameCompiled(first, second)
  check("determinism: recompile identical", same, why)
  check("determinism: same instruction count",
    first.stats.instructions == second.stats.instructions,
    first.stats.instructions .. " vs " .. second.stats.instructions)

  local a2 = build(src)
  local same2, why2 = sameCompiled(first, a2)
  check("determinism: fresh build identical", same2, why2)
end

-- ---------------------------------------------------------------------------
-- 9. Opcode coverage of the corpus
-- ---------------------------------------------------------------------------
do
  local count = 0
  for _ in pairs(coverage) do count = count + 1 end

  local emitted = {
    "MOVE", "LOADK", "LOADNIL", "LOADBOOL", "LOADINT", "LOADNILN",
    "GETUPVAL", "SETUPVAL", "NEWCELL", "GETCELL", "SETCELL",
    "GETGLOBAL", "SETGLOBAL", "NEWTABLE", "GETTABLE", "SETTABLE",
    "GETFIELD", "SETFIELD", "SELF", "SETLIST", "GETIDXI", "SETIDXI",
    "ADD", "SUB", "MUL", "DIV", "MOD", "POW", "IDIV", "UNM", "CONCAT",
    "BAND", "BOR", "BXOR", "BNOT", "SHL", "SHR", "LEN", "NOT",
    "EQ", "NE", "LT", "LE", "GT", "GE",
    "JMP", "JMPF", "JMPT", "FORPREP", "FORLOOP", "TFORCALL", "TFORLOOP",
    "CALL", "TAILCALL", "RETURN", "CLOSURE", "VARARG",
    "ADDK", "SUBK", "MULK", "DIVK", "MODK", "POWK", "IDIVK",
    "ADDI", "SUBI", "MULI", "DIVI", "MODI", "EQK", "NEK", "LTK", "LEK",
  }
  local missing = {}
  for i = 1, #emitted do
    if not coverage[emitted[i]] then missing[#missing + 1] = emitted[i] end
  end
  check("coverage: every emittable opcode exercised", #missing == 0,
    table.concat(missing, " "))
  check("coverage: at least 70 opcodes", count >= 70, count)

  local names = {}
  for name in pairs(coverage) do names[#names + 1] = name end
  table.sort(names)
  notes[#notes + 1] = string.format("MODULE7_OPS %d/%d [%s]",
    count, 80, table.concat(names, " "))
end

-- ---------------------------------------------------------------------------
-- 10. Scale and compile time
-- ---------------------------------------------------------------------------
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
  local src = table.concat(lines, "\n")
  local lineCount = 0
  for _ in src:gmatch("\n") do lineCount = lineCount + 1 end
  lineCount = lineCount + 1

  local expected = execute(src)

  local started = os.clock()
  local compiled, result, perrors = build(src)
  local elapsed = os.clock() - started

  check("scale: parse clean", #perrors == 0, errorText(perrors))
  check("scale: analyze clean", result ~= nil and #result.errors == 0,
    result and errorText(result.errors))
  check("scale: compile clean", compiled ~= nil and #compiled.errors == 0,
    compiled and errorText(compiled.errors))
  if compiled and #compiled.errors == 0 then
    local problems = Compiler.validate(compiled)
    check("scale: bytecode valid", #problems == 0, problems[1])
    local out, err = runVm(compiled)
    check("scale: output", expected ~= nil and out == expected,
      err or ("vm=" .. tostring(out) .. " want=" .. tostring(expected)))
    check("scale: under ten seconds", elapsed < 10, elapsed)
    cover(compiled)
    notes[#notes + 1] = string.format(
      "MODULE7_SCALE lines=%d protos=%d instr=%d k=%d cells=%d upvals=%d " ..
      "stack=%d ms=%.1f", lineCount, compiled.stats.protos,
      compiled.stats.instructions, compiled.stats.constants,
      compiled.stats.cells, compiled.stats.upvalues,
      compiled.stats.maxstack, elapsed * 1000)
  end
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

local total = 0
for _ in pairs(coverage) do total = total + 1 end
notes[#notes + 1] = string.format("MODULE7_COVERAGE %d/80", total)
notes[#notes + 1] = string.format("MODULE7_CHECKS %d/%d", checks - failures, checks)

for i = 1, #notes do emit(notes[i]) end
emit("MODULE7_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
