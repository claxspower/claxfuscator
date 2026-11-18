-- module4.lua -- acceptance tests for MBA opaque predicates (layer 4).
--
-- Layers 1-3 are exercised in front of layer 4 so the tests cover the real
-- pipeline order: parse -> analyze/rename -> flatten -> opaque.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Flatten = require("src.flatten")
local Opaque = require("src.opaque")
local Emit = require("tests.emit")

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

local function errorText(result)
  local parts = {}
  for i = 1, #result.errors do
    local e = result.errors[i]
    parts[i] = e.line .. ":" .. e.col .. " " .. e.msg
  end
  return table.concat(parts, " | ")
end

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

-- Evaluate a single expression in a private scope. `setup` declares the
-- variables the expression refers to.
local function evalExpr(node, setup)
  local src = (setup or "") .. "\nreturn " .. Emit.expr(node)
  local chunk, err = loadChunk(src, "@expr")
  if not chunk then return nil, tostring(err) end
  local ok, value = pcall(chunk)
  if not ok then return nil, tostring(value) end
  return value
end

local function truthy(v)
  return v ~= nil and v ~= false
end

local function contains(where, pred)
  local hit = false
  Ast.walk(where, function(n)
    if pred(n) then hit = true end
  end)
  return hit
end

local function isPredicateName(name)
  return type(name) == "string" and
    name:match("^_0x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function countConditions(root)
  local total = 0
  Ast.walk(root, function(n)
    local t = n.type
    if t == "If" or t == "IfExpression" then
      total = total + #(n.branches or {})
    elseif t == "While" or t == "Repeat" then
      total = total + 1
    end
  end)
  return total
end

-- Full pipeline. `renamed` is the layer-2 text, `flat` adds layer 3 and
-- `text` adds layer 4.
local function pipeline(src, opts)
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local renamed = Emit.source(ast)
  local flattenStats = Flatten.run(ast, { seed = 0xBEEF })
  local flat = Emit.source(ast)
  local opaqueStats = Opaque.run(ast, opts or { seed = 0xC0FFEE })
  local text = Emit.source(ast)
  return ast, result, renamed, flat, flattenStats, opaqueStats, text
end

-- Every stage must agree with the untouched source.
local function checkProgram(name, src, expected)
  local original, originalErr = execute(src)
  check(name .. ": original executes", original ~= nil, originalErr)
  if expected ~= nil then
    check(name .. ": original output", original == expected, original)
  end

  local ast, result, renamed, flat, _, stats, text = pipeline(src)
  check(name .. ": analyze clean", #result.errors == 0, errorText(result))

  local renamedOut, renamedErr = execute(renamed)
  check(name .. ": renamed output", renamedOut == original, renamedErr or renamedOut)

  local flatOut, flatErr = execute(flat)
  check(name .. ": flattened output", flatOut == original, flatErr or flatOut)

  local out, outErr = execute(text)
  check(name .. ": opaque output", out == original, outErr or out)
  if expected ~= nil then
    check(name .. ": opaque expected", out == expected, out)
  end

  local violations = Ast.validate(ast)
  check(name .. ": opaque AST valid", #violations == 0, violations[1])
  return ast, stats, text
end

-- ---------------------------------------------------------------------------
-- 1. Template truth table
-- ---------------------------------------------------------------------------
-- The identities are pure integer arithmetic; they must hold for negative and
-- positive `v` on every host (Lua's % is a floor modulus, so parity is stable).
local VALUES = { -999, -100, -7, -3, -2, -1, 0, 1, 2, 3, 4, 5, 99, 999 }

do
  for i = 1, #Opaque.TRUE_TEMPLATES do
    local tpl = Opaque.TRUE_TEMPLATES[i]
    local bad
    for k = 1, #VALUES do
      local value = VALUES[k]
      local node = tpl.build("v", 1, 1)
      local got, err = evalExpr(node, "local v = " .. value)
      if err or not truthy(got) then
        bad = "v=" .. value .. " -> " .. tostring(got) .. " " .. tostring(err or "")
        break
      end
    end
    check("template-true " .. tpl.id, bad == nil, bad)
  end

  for i = 1, #Opaque.FALSE_TEMPLATES do
    local tpl = Opaque.FALSE_TEMPLATES[i]
    local bad
    for k = 1, #VALUES do
      local value = VALUES[k]
      local node = tpl.build("v", 1, 1)
      local got, err = evalExpr(node, "local v = " .. value)
      if err or truthy(got) then
        bad = "v=" .. value .. " -> " .. tostring(got) .. " " .. tostring(err or "")
        break
      end
    end
    check("template-false " .. tpl.id, bad == nil, bad)
  end

  check("template-true count", #Opaque.TRUE_TEMPLATES >= 11, #Opaque.TRUE_TEMPLATES)
  check("template-false count", #Opaque.FALSE_TEMPLATES >= 10, #Opaque.FALSE_TEMPLATES)
  check("wrapper count", #Opaque.WRAPPERS >= 7, #Opaque.WRAPPERS)
end

-- ---------------------------------------------------------------------------
-- 2. Wrappers preserve truthiness, including non-boolean truthy values
-- ---------------------------------------------------------------------------
-- In Lua only nil and false are falsy; 0 and "" are truthy and must stay so.
local C_VALUES = {
  { lit = "nil", want = false },
  { lit = "false", want = false },
  { lit = "true", want = true },
  { lit = "0", want = true },
  { lit = '""', want = true },
  { lit = '"x"', want = true },
  { lit = "{}", want = true },
  { lit = "5", want = true },
  { lit = "0/0 ~= 0", want = true }, -- NaN is truthy in Lua
}

do
  local tplTrue = Opaque.TRUE_TEMPLATES[2]
  local tplFalse = Opaque.FALSE_TEMPLATES[3]
  for w = 1, #Opaque.WRAPPERS do
    local wrapper = Opaque.WRAPPERS[w]
    local bad
    for k = 1, #C_VALUES do
      local case = C_VALUES[k]
      local T = tplTrue.build("v", 1, 1)
      local F = tplFalse.build("v", 1, 1)
      local body = wrapper.build({ type = "Name", value = "c", line = 1, col = 1, children = {} }, T, F, 1, 1)
      local got, err = evalExpr(body, "local v = -7\nlocal c = " .. case.lit)
      if err or truthy(got) ~= case.want then
        bad = case.lit .. " -> " .. tostring(got) .. " " .. tostring(err or "")
        break
      end
    end
    check("wrapper-truthiness " .. wrapper.id, bad == nil, bad)
  end
end

-- ---------------------------------------------------------------------------
-- 3. Semantics corpus through layers 1-4
-- ---------------------------------------------------------------------------
checkProgram("if-elseif-else", [[
local function pick(a, b)
  local r
  if a > b then
    r = a
  elseif a < b then
    r = b
  else
    r = 0
  end
  return r
end
print(pick(3, 5), pick(5, 3), pick(2, 2))
]], "5\t5\t0")

checkProgram("nested-diamond", [[
local function f(a, b)
  local r = 0
  if a then
    if b then
      r = 1
    else
      r = 2
    end
  else
    r = 3
  end
  return r
end
print(f(true, true), f(true, false), f(false, true))
]], "1\t2\t3")

checkProgram("truthiness-matrix", [[
local function t(x)
  if x then return 1 end
  return 0
end
print(t(nil), t(false), t(true), t(0), t(""), t("x"), t({}))
]], "0\t0\t1\t1\t1\t1\t1")

checkProgram("condition-order", [[
local log = {}
local function mark(x)
  log[#log + 1] = tostring(x)
  return x
end
local function f()
  if mark(false) then return 1
  elseif mark(nil) then return 2
  elseif mark(true) then return 3
  else return 4 end
end
print(f(), table.concat(log, ","))
]], "3\tfalse,nil,true")

checkProgram("single-evaluation", [[
local hits = 0
local function bump(v)
  hits = hits + 1
  return v
end
local function f()
  if bump(nil) then return 1
  elseif bump(0) then return 2
  elseif bump(false) then return 3
  elseif bump("") then return 4
  else return 5 end
end
print(f(), hits)
]], "2\t2")

checkProgram("short-circuit", [[
local n = 0
local function hit(v)
  n = n + 1
  return v
end
local function f(a)
  if a and hit(true) then return n end
  return -1
end
print(f(false), n, f(true), n)
]], "-1\t0\t1\t1")

checkProgram("while-condition-once", [[
local n = 0
local function tick()
  n = n + 1
  return n < 4
end
while tick() do
end
print(n)
]], "4")

checkProgram("while-break", [[
local sum = 0
local i = 0
while true do
  i = i + 1
  if i > 4 then break end
  sum = sum + i
end
print(i, sum)
]], "5\t10")

checkProgram("repeat-until", [[
local n = 0
local last = 0
repeat
  n = n + 1
  local step = n * 2
  if step > 2 then
    last = step
  end
until step >= 4
print(n, last)
]], "2\t4")

checkProgram("numeric-for", [[
local sum = 0
for i = 10, 1, -2 do
  local half = i / 2
  if half > 2 then
    sum = sum + i
  end
end
print(sum)
]], "24")

checkProgram("generic-for", [[
local total = 0
local t = { a = 1, b = 2, c = 3 }
for k, v in pairs(t) do
  if v > 1 then
    total = total + v
  end
end
print(total)
]], "5")

checkProgram("closure-in-branch", [[
local function make(n)
  local f
  if n > 0 then
    local step = n
    f = function() return step * 2 end
  else
    f = function() return 0 end
  end
  return f()
end
print(make(3), make(0))
]], "6\t0")

checkProgram("early-return", [[
local function f(n)
  if n < 0 then return -1 end
  if n == 0 then return 0 end
  return n
end
print(f(-5), f(0), f(5))
]], "-1\t0\t5")

checkProgram("vararg", [[
local function f(...)
  local n = select("#", ...)
  if n > 0 then
    return ...
  end
  return nil
end
print(f(7, 8))
]], "7\t8")

checkProgram("method-self", [[
local obj = { val = 9 }
function obj:get(flag)
  if flag then
    return self.val
  end
  return 0
end
print(obj:get(true), obj:get(false))
]], "9\t0")

checkProgram("chunk-level", [[
local a = 2
local b = 3
if a < b then
  print("lt")
else
  print("ge")
end
]], "lt")

checkProgram("do-block", [[
local function f(c)
  local r = 0
  do
    local a = 1
    local b = 2
    r = a + b
  end
  if c then
    r = r + 1
  end
  return r
end
print(f(true), f(false))
]], "4\t3")

checkProgram("and-or-conditions", [[
local function f(a, b)
  local r = 0
  if a and b then
    r = 1
  elseif a or b then
    r = 2
  else
    r = 3
  end
  return r
end
print(f(1, 1), f(1, nil), f(nil, nil))
]], "1\t2\t3")

checkProgram("nested-functions", [[
local function outer(n)
  local total = 0
  local function inner(x)
    if x > 0 then
      return x
    end
    return 0
  end
  if n then
    total = inner(n)
  end
  return total
end
print(outer(4), outer(-1))
]], "4\t0")

checkProgram("function-inside-condition", [[
local function f(x)
  if (function() return x end)() > 2 then
    return "big"
  end
  return "small"
end
print(f(3), f(1))
]], "big\tsmall")

-- ---------------------------------------------------------------------------
-- 4. Generated structure: one predicate local per owner
-- ---------------------------------------------------------------------------
do
  local src = [[
local function f(a, b)
  if a > b then return a end
  return b
end
local function g(x)
  while x < 3 do x = x + 1 end
  return x
end
print(f(1, 3), g(0))
]]
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local before = {
    If = #Ast.find(ast, "If"),
    While = #Ast.find(ast, "While"),
    Number = #Ast.find(ast, "Number"),
    Call = #Ast.find(ast, "Call"),
  }
  local expectedConditions = countConditions(ast)

  local stats = Opaque.run(ast, { seed = 7 })
  local text = Emit.source(ast)

  check("structure: all conditions wrapped", stats.conditions == expectedConditions,
    stats.conditions .. " ~= " .. expectedConditions)
  check("structure: two predicates per condition", stats.predicates == stats.conditions * 2,
    stats.predicates)
  check("structure: one owner per function", stats.owners == 2, stats.owners)
  check("structure: one variable per owner", stats.variables == 2, stats.variables)
  check("structure: declarations recorded", #stats.decls == 2, #stats.decls)
  check("structure: names unique", stats.decls[1].name ~= stats.decls[2].name)
  check("structure: name pattern", isPredicateName(stats.decls[1].name) and
    isPredicateName(stats.decls[2].name), stats.decls[1].name .. " / " .. tostring(stats.decls[2] and stats.decls[2].name))
  check("structure: predicates are integers", math.floor(stats.decls[1].value) == stats.decls[1].value,
    stats.decls[1].value)

  check("structure: no extra If", #Ast.find(ast, "If") == before.If, #Ast.find(ast, "If"))
  check("structure: no extra While", #Ast.find(ast, "While") == before.While, #Ast.find(ast, "While"))
  check("structure: no extra Call", #Ast.find(ast, "Call") == before.Call, #Ast.find(ast, "Call"))
  check("structure: numbers added", #Ast.find(ast, "Number") > before.Number, #Ast.find(ast, "Number"))

  local functions = Ast.find(ast, "Function")
  check("structure: two function bodies", #functions == 2, #functions)
  for i = 1, #functions do
    local first = functions[i].children[1]
    check("structure: decl is first statement " .. i,
      first ~= nil and first.type == "Local" and #first.names == 1 and isPredicateName(first.names[1]),
      first and first.type .. " " .. tostring(first.names and first.names[1]))
    check("structure: decl has a literal " .. i,
      first ~= nil and first.children[1] ~= nil and first.children[1].type == "Number",
      first and first.children[1] and first.children[1].type)
  end

  -- The chunk itself has no conditions, so it must not get a local.
  check("structure: chunk untouched", ast.children[1].type ~= "Local", ast.children[1].type)
  check("structure: declarations are per owner", stats.decls[1].conditions + stats.decls[2].conditions ==
    stats.conditions)
  check("structure: AST valid", #Ast.validate(ast) == 0, Ast.validate(ast)[1])
  check("structure: output", execute(text) == "3\t3", execute(text))

  local distinct = {}
  for _, name in ipairs({ stats.decls[1].name, stats.decls[2].name }) do
    distinct[name] = true
  end
  local n = 0
  for _ in pairs(distinct) do n = n + 1 end
  check("structure: distinct names counted", n == 2, n)
end

-- ---------------------------------------------------------------------------
-- 5. Chunk-level owner and IfExpression support
-- ---------------------------------------------------------------------------
do
  local ast = parse("if true then\n  print(1)\nend")
  local stats = Opaque.run(ast, { seed = 3 })
  local decl = ast.children[1]
  check("chunk: condition wrapped", stats.conditions == 1, stats.conditions)
  check("chunk: decl first", decl.type == "Local" and isPredicateName(decl.names[1]), decl.type)
  check("chunk: decl carries value", decl.children[1] and decl.children[1].type == "Number")
  check("chunk: output", execute(Emit.source(ast)) == "1", execute(Emit.source(ast)))
  check("chunk: AST valid", #Ast.validate(ast) == 0)
end

do
  local ast = parse([[
local a = 5
local x = if a > 3 then 1 else 2
print(x)
]])
  local stats = Opaque.run(ast, { seed = 11 })
  local expr = Ast.find(ast, "IfExpression")[1]
  check("if-expression: found", expr ~= nil)
  check("if-expression: condition wrapped", stats.conditions == 1, stats.conditions)
  local cond = expr and expr.children[expr.branches[1].cond]
  check("if-expression: wrapper installed", cond ~= nil and cond.type ~= "Name",
    cond and cond.type)
  check("if-expression: original condition kept",
    cond ~= nil and contains(cond, function(n) return n.type == "Name" and n.value == "a" end))
  check("if-expression: branch value untouched",
    expr ~= nil and expr.children[expr.branches[1].value].type == "Number")
  check("if-expression: AST valid", #Ast.validate(ast) == 0, Ast.validate(ast)[1])
end

-- ---------------------------------------------------------------------------
-- 6. Skip rules
-- ---------------------------------------------------------------------------
do
  local src = [[
local function f(a)
  if a then return 1 end
  return 0
end
print(f(true))
]]
  local ast = parse(src)
  local before = Emit.source(ast)
  local stats = Opaque.run(ast, { enabled = false })
  check("skip-disabled: no conditions", stats.conditions == 0, stats.conditions)
  check("skip-disabled: reason", stats.skipped.disabled == 1, stats.skipped.disabled)
  check("skip-disabled: text untouched", Emit.source(ast) == before)
end

do
  local src = [[
local function f(a)
  if a then return 1 end
  return 0
end
print(f(true))
]]
  local ast = parse(src)
  local before = Emit.source(ast)
  local stats = Opaque.run(ast, { maxLocals = 0 })
  check("skip-locals: no conditions", stats.conditions == 0, stats.conditions)
  check("skip-locals: reason", stats.skipped.locals >= 1, stats.skipped.locals)
  check("skip-locals: text untouched", Emit.source(ast) == before)
  check("skip-locals: program still runs", execute(Emit.source(ast)) == "1")
end

do
  local src = [[
local function f(a, b)
  while a < b do
    a = a + 1
  end
  if a then return 1 end
  return 0
end
print(f(1, 3))
]]
  local ast = parse(src)
  local before = Emit.source(ast)
  local stats = Opaque.run(ast, { prob = 0 })
  check("skip-prob: no conditions", stats.conditions == 0, stats.conditions)
  check("skip-prob: reason", stats.skipped.prob == 2, stats.skipped.prob)
  check("skip-prob: text untouched", Emit.source(ast) == before)
end

do
  local ast = parse("print(1)")
  local before = Emit.source(ast)
  local stats = Opaque.run(ast, { seed = 3 })
  check("no-conditions: nothing to do", stats.conditions == 0 and stats.owners == 0,
    stats.conditions)
  check("no-conditions: text untouched", Emit.source(ast) == before)
end

do
  local stats = Opaque.run(nil, { seed = 3 })
  check("invalid: rejected", stats.conditions == 0 and stats.skipped.disabled == 1,
    stats.skipped.disabled)
end

-- ---------------------------------------------------------------------------
-- 7. Determinism and polymorphism
-- ---------------------------------------------------------------------------
do
  local src = [[
local function classify(n)
  if n < 0 then return "neg" end
  if n == 0 then return "zero" end
  return "pos"
end
print(classify(-1), classify(0), classify(1))
]]
  local function variant(seed)
    local ast = parse(src)
    local result = Scope.analyze(ast, { seed = 0x1234 })
    Scope.apply(result)
    local stats = Opaque.run(ast, { seed = seed })
    return Emit.source(ast), stats
  end

  local a, sa = variant(7)
  local b = variant(7)
  check("determinism: same seed reproduces", a == b)
  check("determinism: different seed diverges", a ~= variant(8))
  check("determinism: condition count stable", sa.conditions == select(2, variant(99)).conditions)

  local seen, unique, names = {}, true, {}
  for seed = 1, 10 do
    local text, stats = variant(seed)
    if seen[text] then unique = false end
    seen[text] = true
    if names[stats.decls[1].name] then unique = false end
    names[stats.decls[1].name] = true
    local out = execute(text)
    if out ~= "neg\tzero\tpos" then
      check("determinism: seed " .. seed .. " output", false, out)
    end
  end

  check("determinism: ten seeds, ten outputs", unique)
  local nameCount = 0
  for _ in pairs(names) do nameCount = nameCount + 1 end
  check("determinism: ten distinct variables", nameCount == 10, nameCount)
  check("determinism: output preserved", execute(a) == "neg\tzero\tpos", execute(a))
  notes[#notes + 1] = "MODULE4_POLY 10/10"
end

-- ---------------------------------------------------------------------------
-- 8. Template and wrapper coverage grows with the seed space
-- ---------------------------------------------------------------------------
do
  local src = [[
local function f(a, b, c)
  if a then return 1 end
  if b then return 2 end
  if c then return 3 end
  return 0
end
print(f(false, false, true))
]]
  local templates, wrappers = {}, {}
  for seed = 1, 12 do
    local ast = parse(src)
    local stats = Opaque.run(ast, { seed = seed })
    for id in pairs(stats.templates) do templates[id] = true end
    for id in pairs(stats.wrappers) do wrappers[id] = true end
  end
  local templateCount, wrapperCount = 0, 0
  for _ in pairs(templates) do templateCount = templateCount + 1 end
  for _ in pairs(wrappers) do wrapperCount = wrapperCount + 1 end
  check("coverage: many templates appear", templateCount >= 8, templateCount)
  check("coverage: many wrappers appear", wrapperCount >= 4, wrapperCount)
end

-- ---------------------------------------------------------------------------
-- 9. Scale: 150 branches through layers 2-4
-- ---------------------------------------------------------------------------
do
  local lines = { "local function big(n)", "  local acc = 0" }
  for i = 1, 150 do
    lines[#lines + 1] = string.format("  if n > %d then acc = acc + %d end", i, i)
  end
  lines[#lines + 1] = "  return acc"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = "print(big(537))"
  local src = table.concat(lines, "\n")

  local started = os.clock()
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local flattenStats = Flatten.run(ast, { seed = 5 })
  local expectedConditions = countConditions(ast)
  local ifBefore = #Ast.find(ast, "If")
  local stats = Opaque.run(ast, { seed = 5 })
  local text = Emit.source(ast)
  local elapsed = os.clock() - started

  check("scale: analyze clean", #result.errors == 0, errorText(result))
  check("scale: flattened", flattenStats.flattened == 1, flattenStats.flattened)
  check("scale: all conditions wrapped", stats.conditions == expectedConditions,
    stats.conditions .. " ~= " .. expectedConditions)
  check("scale: more conditions than states", stats.conditions > flattenStats.states,
    stats.conditions)
  check("scale: no extra If", #Ast.find(ast, "If") == ifBefore, #Ast.find(ast, "If"))
  check("scale: AST valid", #Ast.validate(ast) == 0, Ast.validate(ast)[1])
  local out, err = execute(text)
  check("scale: output", out == "11325", err or out)
  check("scale: under five seconds", elapsed < 5, elapsed)
  notes[#notes + 1] = string.format("MODULE4_SCALE branches=150 conditions=%d ms=%.1f",
    stats.conditions, elapsed * 1000)
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

for i = 1, #notes do emit(notes[i]) end
emit(string.format("MODULE4_CHECKS %d/%d", checks - failures, checks))
emit("MODULE4_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
