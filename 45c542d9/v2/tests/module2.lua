-- module2.lua -- acceptance tests for scope analysis + renaming (layer 2).
-- Run from the v2 directory or with package.path pointing at v2 and v2/src.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
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

local function compile(src, opts)
  local ast = parse(src)
  return ast, Scope.analyze(ast, opts or { seed = 0xA11CE })
end

local function applyTo(src, opts)
  local ast, result = compile(src, opts)
  Scope.apply(result)
  return Emit.source(ast), result, ast
end

local function bindingsNamed(result, name)
  local out = {}
  for i = 1, #result.bindings do
    if result.bindings[i].name == name then out[#out + 1] = result.bindings[i] end
  end
  return out
end

local function functionNamed(result, name)
  for i = 2, #result.functions do
    if result.functions[i].node.name == name then return result.functions[i] end
  end
  return nil
end

local function hasUpvalue(fn, id)
  return fn ~= nil and fn.upvalueSet[id] == true
end

local function errorText(result)
  local parts = {}
  for i = 1, #result.errors do
    local e = result.errors[i]
    parts[i] = e.line .. ":" .. e.col .. " " .. e.msg
  end
  return table.concat(parts, " | ")
end

local function newNames(result)
  local out = {}
  for i = 1, #result.bindings do out[#out + 1] = result.bindings[i].newName end
  return out
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

-- Runs the source, then the printed AST, then the renamed AST; all three must
-- print the same thing.
local function checkProgram(name, src, expected)
  local original, originalErr = execute(src)
  check(name .. ": original executes", original ~= nil, originalErr)
  if expected ~= nil then
    check(name .. ": original output", original == expected, original)
  end

  local fresh = parse(src)
  local printed = Emit.source(fresh)
  local printedOut, printedErr = execute(printed)
  check(name .. ": emitter round-trip", printedOut == original, printedErr or printedOut)

  local ast, result = compile(src)
  check(name .. ": analyze clean", #result.errors == 0, errorText(result))
  Scope.apply(result)
  local renamed = Emit.source(ast)
  local renamedOut, renamedErr = execute(renamed)
  check(name .. ": renamed output", renamedOut == original, renamedErr or renamedOut)
  local violations = Ast.validate(ast)
  check(name .. ": renamed AST valid", #violations == 0, violations[1])
  return ast, result, renamed
end

-- ---------------------------------------------------------------------------
-- 1. Basic renaming + global policy
-- ---------------------------------------------------------------------------
do
  local src = "local alpha = 1\nlocal beta = 2\nprint(alpha + beta)"
  local ast, result = compile(src, { seed = 1 })
  check("basic: no diagnostics", #result.errors == 0, errorText(result))
  check("basic: two locals recorded", result.stats.locals == 2, result.stats.locals)
  check("basic: one distinct global", result.stats.globals == 1, result.stats.globals)
  check("basic: print counted as global", result.globals["print"] == 1)
  check("basic: renamed count", result.stats.renamed == 2, result.stats.renamed)

  local alpha = bindingsNamed(result, "alpha")[1]
  local beta = bindingsNamed(result, "beta")[1]
  check("basic: alpha is a local binding", alpha and alpha.kind == "local")
  check("basic: names match _0x + 8 hex",
    alpha and alpha.newName:match("^_0x%x%x%x%x%x%x%x%x$") ~= nil, alpha and alpha.newName)
  check("basic: names are distinct", alpha and alpha.newName ~= beta.newName)

  local localRefs, globalRefs = 0, 0
  for _, node in ipairs(Ast.find(ast, "Name")) do
    if node.refKind == "local" then localRefs = localRefs + 1 end
    if node.refKind == "global" then globalRefs = globalRefs + 1 end
  end
  check("basic: two local refs", localRefs == 2, localRefs)
  check("basic: one global ref", globalRefs == 1, globalRefs)

  Scope.apply(result)
  local text = Emit.source(ast)
  check("basic: original locals erased", text:find("alpha", 1, true) == nil and
    text:find("beta", 1, true) == nil, text)
  check("basic: global print preserved", text:find("print", 1, true) ~= nil, text)
  check("basic: renamed AST valid", #Ast.validate(ast) == 0)
end

-- ---------------------------------------------------------------------------
-- 2. Shadowing
-- ---------------------------------------------------------------------------
do
  local src = [[
local x = 1
do
  local x = 2
  print(x)
end
print(x)
]]
  local ast, result = compile(src)
  local xs = bindingsNamed(result, "x")
  check("shadow: two bindings", #xs == 2, #xs)
  check("shadow: distinct names", xs[1].newName ~= xs[2].newName)
  check("shadow: distinct scopes", xs[1].scopeId ~= xs[2].scopeId)
  local refs = {}
  for _, node in ipairs(Ast.find(ast, "Name")) do
    if node.value == "x" then refs[#refs + 1] = node end
  end
  check("shadow: two references", #refs == 2, #refs)
  check("shadow: inner reference binds inner local", refs[1] and refs[1].bindingId == xs[2].id,
    refs[1] and refs[1].bindingId)
  check("shadow: outer reference binds outer local", refs[2] and refs[2].bindingId == xs[1].id,
    refs[2] and refs[2].bindingId)
  check("shadow: both are plain locals",
    refs[1].refKind == "local" and refs[2].refKind == "local")
  check("shadow: no captured bindings", result.stats.captured == 0, result.stats.captured)
end

-- ---------------------------------------------------------------------------
-- 3. Initializer runs before the declaration
-- ---------------------------------------------------------------------------
do
  local src = [[
local x = 10
do
  local x = x + 1
  print(x)
end
]]
  local ast, result = compile(src)
  local xs = bindingsNamed(result, "x")
  local initializer
  for _, node in ipairs(Ast.find(ast, "Name")) do
    if node.value == "x" then initializer = node break end
  end
  check("init: initializer resolves to outer binding", initializer and
    initializer.bindingId == xs[1].id, initializer and initializer.bindingId)
  checkProgram("init", src, "11")
end

-- ---------------------------------------------------------------------------
-- 4. Upvalues and transitive capture
-- ---------------------------------------------------------------------------
do
  local src = [[
local a = 1
local function outer()
  local b = 2
  local function inner()
    return a + b
  end
  return inner()
end
print(outer())
]]
  local ast, result = compile(src)
  local a = bindingsNamed(result, "a")[1]
  local b = bindingsNamed(result, "b")[1]
  local outer = functionNamed(result, "outer")
  local inner = functionNamed(result, "inner")
  check("upvalue: outer found", outer ~= nil)
  check("upvalue: inner found", inner ~= nil)
  check("upvalue: a captured", a.captured)
  check("upvalue: b captured", b.captured)
  check("upvalue: inner captures a", hasUpvalue(inner, a.id))
  check("upvalue: inner captures b", hasUpvalue(inner, b.id))
  check("upvalue: outer captures a transitively", hasUpvalue(outer, a.id))
  check("upvalue: outer does not capture its own b", not hasUpvalue(outer, b.id))
  check("upvalue: pair count", result.stats.upvalues == 3, result.stats.upvalues)
  local byId = {}
  for i = 1, #inner.upvalues do byId[inner.upvalues[i]] = true end
  check("upvalue: list matches set",
    byId[a.id] == true and byId[b.id] == true and #inner.upvalues == 2, #inner.upvalues)
  check("upvalue: intermediate function recorded", #outer.upvalues == 1, #outer.upvalues)
end

-- ---------------------------------------------------------------------------
-- 5. Parameters, method self, varargs
-- ---------------------------------------------------------------------------
do
  local src = [[
local t = {}
function t:add(v)
  self.sum = (self.sum or 0) + v
  return self.sum
end
local function f(p, q, ...)
  return p + q, select("#", ...)
end
t:add(5)
print(f(1, 2, 3, 4))
]]
  local ast, result = compile(src)
  check("params: four params recorded", result.stats.params == 4, result.stats.params)
  local selfBindings = bindingsNamed(result, "self")
  check("params: self is a param binding", #selfBindings == 1 and
    selfBindings[1].kind == "param")
  check("params: self renamed", selfBindings[1].newName ~= "self")
  local refs = 0
  for _, node in ipairs(Ast.find(ast, "Name")) do
    if node.value == "self" then
      refs = refs + 1
      check("params: self ref is local", node.refKind == "local")
    end
  end
  check("params: three self references", refs == 3, refs)
  local _, _, text = checkProgram("params", src, "3\t2")
  check("params: field names untouched", text:find(".sum", 1, true) ~= nil and
    text:find(":add(", 1, true) ~= nil, text)
end

-- ---------------------------------------------------------------------------
-- 6. Loop variables, numeric/generic loops, while
-- ---------------------------------------------------------------------------
do
  local src = [[
local sum = 0
for i = 1, 5 do sum = sum + i end
for k, v in ipairs({10, 20}) do sum = sum + v end
local j = 0
repeat
  local step = 1
  j = j + step
until j >= 3
while j > 0 do j = j - 1 end
print(sum, j)
]]
  local ast, result = compile(src)
  check("loops: loop variable counted", result.stats.loops == 3, result.stats.loops)
  local i = bindingsNamed(result, "i")[1]
  check("loops: i scoped inside loop", i ~= nil and i.scopeId ~= 1)
  check("loops: k and v are loop bindings",
    #bindingsNamed(result, "k") == 1 and bindingsNamed(result, "k")[1].kind == "loop" and
    #bindingsNamed(result, "v") == 1 and bindingsNamed(result, "v")[1].kind == "loop")
  checkProgram("loops", src, "45\t0")
end

-- ---------------------------------------------------------------------------
-- 7. repeat/until sees body locals
-- ---------------------------------------------------------------------------
do
  local src = [[
local n = 0
repeat
  local done = n >= 2
  n = n + 1
until done
print(n)
]]
  local ast, result = compile(src)
  local done = bindingsNamed(result, "done")[1]
  local untilRef
  for _, node in ipairs(Ast.find(ast, "Name")) do
    if node.value == "done" then untilRef = node break end
  end
  check("repeat: condition resolves body local", untilRef and untilRef.bindingId == done.id)
  check("repeat: referenced as a local", untilRef and untilRef.refKind == "local")
  check("repeat: not a global", untilRef and result.globals["done"] == nil)
  checkProgram("repeat", src, "3")
end

-- ---------------------------------------------------------------------------
-- 8. Labels and goto
-- ---------------------------------------------------------------------------
do
  local src = [[
local i = 0
::top::
i = i + 1
if i < 3 then goto top end
print(i)
]]
  local ast, result = compile(src)
  check("label: one label binding", result.stats.labels == 1, result.stats.labels)
  local label = bindingsNamed(result, "top")[1]
  check("label: kind is label", label and label.kind == "label")
  local gotoNode = Ast.find(ast, "Goto")[1]
  check("label: goto bound to label", gotoNode and gotoNode.bindingId == label.id)
  check("label: label renamed", label.newName:match("^_0x%x+$") ~= nil, label.newName)
  Scope.apply(result)
  local text = Emit.source(ast)
  check("label: emitted pair matches",
    text:find("::" .. label.newName .. "::", 1, true) ~= nil and
    text:find("goto " .. label.newName, 1, true) ~= nil, text)
  if _VERSION ~= "Lua 5.1" then
    checkProgram("goto", src, "3")
    checkProgram("goto-outward", [[
do
  goto skip
end
::skip::
print("ok")
]], "ok")
    checkProgram("goto-from-loop", [[
local seen = 0
for i = 1, 5 do
  if i == 3 then goto done end
  seen = seen + 1
end
::done::
print(seen)
]], "2")
  end
end

-- ---------------------------------------------------------------------------
-- 9. Scope errors are reported, never thrown
-- ---------------------------------------------------------------------------
do
  local function errorsOf(src)
    local ok, astOrErr = pcall(parse, src)
    if not ok then return nil, "parser crashed: " .. tostring(astOrErr) end
    local result = Scope.analyze(astOrErr, { seed = 3 })
    return result.errors
  end

  local ok, errs = pcall(errorsOf, "break")
  check("errors: break outside loop reported", ok and errs and #errs == 1,
    ok and errorText({ errors = errs }))
  check("errors: break has position", errs and errs[1] and errs[1].line > 0 and errs[1].col > 0)

  local ok2, errs2 = pcall(errorsOf, "continue")
  check("errors: continue outside loop reported", ok2 and errs2 and #errs2 == 1)

  local ok3, errs3 = pcall(errorsOf, "goto nowhere")
  check("errors: missing goto label reported", ok3 and errs3 and #errs3 == 1 and
    errs3[1].msg:find("no visible label") ~= nil, ok3 and errorText({ errors = errs3 }))
  check("errors: goto keeps the label name", errs3 and errs3[1] and
    errs3[1].msg:find("nowhere", 1, true) ~= nil)

  local _, errs4 = pcall(errorsOf, "::a::\n::a::")
  check("errors: duplicate label reported", errs4 and #errs4 == 1 and
    errs4[1].msg:find("duplicate") ~= nil)

  local _, errs5 = pcall(errorsOf, [[
while true do
  local f = function() break end
end
]])
  check("errors: break inside nested function reported", errs5 and #errs5 == 1)

  local _, errs6 = pcall(errorsOf, [[
::here::
local function f() goto here end
]])
  check("errors: goto cannot cross a function boundary", errs6 and #errs6 == 1)

  local _, errs7 = pcall(errorsOf, [[
do
  ::inner::
end
goto inner
]])
  check("errors: label not visible outside its block", errs7 and #errs7 == 1)

  local _, errs8 = pcall(errorsOf, [[
::again::
do
  ::again::
end
]])
  check("errors: same label in nested block is legal", errs8 and #errs8 == 0,
    errs8 and errorText({ errors = errs8 }))
end

-- ---------------------------------------------------------------------------
-- 10. Reserved names and globals
-- ---------------------------------------------------------------------------
do
  local src = [[
local _ENV = _ENV
local _G = _G
local print = print
print(_G)
]]
  local ast, result = compile(src)
  local envBinding = bindingsNamed(result, "_ENV")[1]
  local gBinding = bindingsNamed(result, "_G")[1]
  local printBinding = bindingsNamed(result, "print")[1]
  check("reserved: _ENV binding reserved", envBinding and envBinding.reserved)
  check("reserved: _G binding reserved", gBinding and gBinding.reserved)
  check("reserved: _ENV keeps its name", envBinding and envBinding.newName == "_ENV")
  check("reserved: _G keeps its name", gBinding and gBinding.newName == "_G")
  check("reserved: local print still renamed", printBinding and not printBinding.reserved and
    printBinding.newName ~= "print")
  check("reserved: reserved binding count", result.stats.reservedBindings == 2,
    result.stats.reservedBindings)
  Scope.apply(result)
  local text = Emit.source(ast)
  check("reserved: emitted _ENV declaration intact",
    text:find("local _ENV", 1, true) ~= nil, text)
  check("reserved: global print read intact", text:find("= print", 1, true) ~= nil, text)
end

do
  local src = [[
local s = string.rep("a", 2)
local t = table.concat({"x"}, ",")
local m = math.floor(2.5)
print(s, t, m)
]]
  local ast, result = compile(src)
  check("globals: string/table/math tracked",
    result.globals["string"] == 1 and result.globals["table"] == 1 and
    result.globals["math"] == 1)
  check("globals: field names never become bindings",
    #bindingsNamed(result, "rep") == 0 and #bindingsNamed(result, "concat") == 0 and
    #bindingsNamed(result, "floor") == 0)
  local text = Emit.source(ast)
  check("globals: library names untouched",
    text:find("string.rep", 1, true) ~= nil and text:find("table.concat", 1, true) ~= nil and
    text:find("math.floor", 1, true) ~= nil, text)
end

do
  local src = [[
counter = 0
counter = counter + 1
print(counter)
]]
  local _, result = compile(src)
  check("globals: assignment target stays global", result.globals["counter"] == 4,
    result.globals["counter"])
  local renamed = applyTo(src)
  check("globals: global assignment untouched", renamed:find("counter", 1, true) ~= nil)
  local out = execute(renamed)
  check("globals: program still runs", out == "1", out)
end

-- ---------------------------------------------------------------------------
-- 11. Determinism and polymorphism
-- ---------------------------------------------------------------------------
do
  local src = "local apple = 1\nlocal banana = 2\nprint(apple + banana)"
  local function variant(seed)
    local ast = parse(src)
    local result = Scope.analyze(ast, { seed = seed })
    Scope.apply(result)
    return Emit.source(ast)
  end
  check("determinism: same seed reproduces", variant(7) == variant(7))
  check("determinism: different seed diverges", variant(7) ~= variant(8))
  local seen, unique = {}, true
  for seed = 1, 10 do
    local text = variant(seed)
    if seen[text] then unique = false end
    seen[text] = true
  end
  check("determinism: ten seeds, ten outputs", unique)
  notes[#notes + 1] = "MODULE2_POLY 10/10"
end

-- ---------------------------------------------------------------------------
-- 12. Uniqueness under load
-- ---------------------------------------------------------------------------
do
  local lines = {}
  local names = {}
  for i = 1, 60 do
    lines[i] = "local item" .. i .. " = " .. i
    names[i] = "item" .. i
  end
  lines[#lines + 1] = "print(" .. table.concat(names, " + ") .. ")"
  local src = table.concat(lines, "\n")

  local ast, result = compile(src, { seed = 99 })
  check("bulk: 60 bindings", result.stats.locals == 60, result.stats.locals)
  local seen, duplicate = {}, nil
  for i = 1, #result.bindings do
    local name = result.bindings[i].newName
    if seen[name] then duplicate = name end
    seen[name] = true
    if not name:match("^_0x%x%x%x%x%x%x%x%x$") then duplicate = name end
  end
  check("bulk: all names unique and well formed", duplicate == nil, duplicate)
  check("bulk: no generator collisions", result.stats.collisions == 0,
    result.stats.collisions)

  Scope.apply(result)
  local text = Emit.source(ast)
  local leaked = nil
  for i = 1, 60 do
    if text:find("item" .. i, 1, true) then leaked = "item" .. i end
  end
  check("bulk: no original identifier survives", leaked == nil, leaked)
  local out = execute(text)
  check("bulk: renamed program output", out == "1830", out)
end

-- ---------------------------------------------------------------------------
-- 13. Original names are erased, globals are not
-- ---------------------------------------------------------------------------
do
  local src = [[
local zebra = 1
local quartz = 2
local function mango()
  return zebra + quartz
end
print(mango())
]]
  local _, result = compile(src)
  check("erasure: analyze clean", #result.errors == 0, errorText(result))
  local text
  text, result = applyTo(src)
  check("erasure: local names gone",
    text:find("zebra", 1, true) == nil and text:find("quartz", 1, true) == nil and
    text:find("mango", 1, true) == nil, text)
  check("erasure: global print kept", text:find("print", 1, true) ~= nil)
  local out = execute(text)
  check("erasure: program still prints", out == "3", out)
end

-- ---------------------------------------------------------------------------
-- 14. AST integrity after apply
-- ---------------------------------------------------------------------------
do
  local src = [[
local function build(n)
  local acc = {}
  for i = 1, n do
    acc[i] = function() return i * 2 end
  end
  return acc
end
local list = build(3)
print(list[1](), list[2](), list[3]())
]]
  local ast, result = compile(src)
  local before = Ast.count(ast).nodes
  Scope.apply(result)
  local after = Ast.count(ast).nodes
  check("integrity: node count stable", before == after, before .. " -> " .. after)
  check("integrity: AST still valid", #Ast.validate(ast) == 0)
  local dangling, badKind = nil, nil
  local validKinds = { ["local"] = true, ["upvalue"] = true, ["global"] = true }
  Ast.walk(ast, function(node)
    if node.type == "Name" and node.refKind then
      if not validKinds[node.refKind] then badKind = node.refKind end
      if node.refKind == "global" then
        if node.bindingId then dangling = "global with binding" end
      elseif not result.bindings[node.bindingId or 0] then
        dangling = "missing binding " .. tostring(node.bindingId)
      end
    end
  end)
  check("integrity: every annotation resolves", dangling == nil, dangling)
  check("integrity: refKind values valid", badKind == nil, badKind)
  local out = execute(Emit.source(ast))
  check("integrity: closure-in-loop program output", out == "2\t4\t6", out)
end

-- ---------------------------------------------------------------------------
-- 15. Luau-only syntax: analysis works, emitted source has no placeholders
-- ---------------------------------------------------------------------------
do
  local src = [[
local acc = 1
local t = { n = 2 }
local k = "n"
t[k] += 3
acc += 4
local function tag(level: number): string
  if level > 2 then
    return `high:{level}`
  end
  return "low"
end
print(acc, t.n, tag(3))
]]
  local ast, result = compile(src)
  check("luau: analyze clean", #result.errors == 0, errorText(result))
  check("luau: compound locals renamed", #bindingsNamed(result, "_0x$t1") == 1)
  Scope.apply(result)
  local text = Emit.source(ast)
  check("luau: no parser placeholder names", text:find("$", 1, true) == nil, text)
  check("luau: interpolated string remains", text:find("high:", 1, true) ~= nil, text)
  check("luau: AST valid", #Ast.validate(ast) == 0)
end

-- ---------------------------------------------------------------------------
-- 16. Semantics corpus
-- ---------------------------------------------------------------------------
checkProgram("corpus-arithmetic", [[
local a = 2
do
  local a = a * 3
  print(a)
end
print(a)
]], "6\n2")

checkProgram("corpus-factorial", [[
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(5))
]], "120")

checkProgram("corpus-nested-capture", [[
local a = 1
local function l1()
  local b = 2
  local function l2()
    local c = 3
    local function l3()
      return a + b + c
    end
    return l3()
  end
  return l2()
end
print(l1())
]], "6")

checkProgram("corpus-counter", [[
local n = 0
local function inc()
  n = n + 1
  return n
end
inc()
inc()
print(n)
]], "2")

checkProgram("corpus-mutual", [[
local g
local function f(n)
  if n == 0 then return 0 end
  return g(n - 1) + 1
end
function g(n)
  if n == 0 then return 0 end
  return f(n - 1) + 1
end
print(f(4), g(4))
]], "4\t4")

checkProgram("corpus-tables", [[
local t = { x = 1, ["y"] = 2, 3 }
local k = "x"
print(t[k], t.y, t[1])
]], "1\t2\t3")

checkProgram("corpus-precedence", [[
local a, b, c = 2, 3, 4
local function n(v) return string.format("%.14g", v) end
print(n(a ^ b ^ 2), n((a ^ b) ^ 2), n(-a ^ 2), n((-a) ^ 2), -a .. b .. c,
  a + b * c, (a + b) * c, not a == b)
print(a < b and b <= c or b ~= c)
]], "512\t64\t-4\t4\t-234\t14\t20\tfalse\ntrue")

checkProgram("corpus-scope-mix", [[
local total = 0
local items = { 4, 5, 6 }
for index, value in ipairs(items) do
  local double = value * 2
  total = total + double
end
local function report(label)
  local suffix = "!"
  return label .. suffix .. total
end
print(report("sum"))
]], "sum!30")

checkProgram("corpus-multivalue", [[
local function two()
  return 1, 2
end
local a, b = two()
a, b = b, a
print(a, b)
]], "2\t1")

checkProgram("corpus-shadow-print", [[
local print = print
print("local")
]], "local")

checkProgram("corpus-block-capture", [[
local f
do
  local secret = 7
  f = function() return secret end
end
print(f())
]], "7")

checkProgram("corpus-upvalue-write", [[
local x = 1
local function bump()
  x = x + 1
end
bump()
bump()
print(x)
]], "3")

checkProgram("corpus-shadow-captures", [[
local x = 1
local get1 = function() return x end
local x = 2
local get2 = function() return x end
print(get1(), get2())
]], "1\t2")

checkProgram("corpus-step-loop", [[
local n = 0
for i = 10, 1, -3 do
  n = n + i
end
print(n)
]], "22")

checkProgram("corpus-branches", [[
local function classify(n)
  if n < 0 then
    local tag = "neg"
    return tag
  elseif n == 0 then
    local tag = "zero"
    return tag
  else
    local tag = "pos"
    return tag
  end
end
print(classify(-5), classify(0), classify(9))
]], "neg\tzero\tpos")

checkProgram("corpus-break-in-branch", [[
local i = 0
while true do
  i = i + 1
  if i >= 3 then break end
end
print(i)
]], "3")

-- ---------------------------------------------------------------------------
-- 17. _ENV preservation (Lua 5.2+)
-- ---------------------------------------------------------------------------
if _VERSION ~= "Lua 5.1" then
  local src = [[
local _ENV = { print = print, value = 42 }
print(value)
]]
  local renamed, result = applyTo(src)
  check("_ENV: binding preserved", bindingsNamed(result, "_ENV")[1].newName == "_ENV")
  check("_ENV: declaration preserved", renamed:find("local _ENV", 1, true) ~= nil, renamed)
  local originalOut = execute(src)
  local renamedOut = execute(renamed)
  check("_ENV: sandbox still works", originalOut == "42" and renamedOut == "42",
    tostring(originalOut) .. " / " .. tostring(renamedOut))
end

-- ---------------------------------------------------------------------------
-- 17. Scale: 1000+ line input stays fast and clean
-- ---------------------------------------------------------------------------
do
  local lines = {}
  for block = 1, 250 do
    lines[#lines + 1] = "do"
    for k = 1, 4 do
      lines[#lines + 1] = "  local a" .. k .. " = " .. (block + k)
    end
    lines[#lines + 1] = "  total = (total or 0) + a1 + a2 + a3 + a4"
    lines[#lines + 1] = "end"
  end
  local src = table.concat(lines, "\n")
  local lineCount = #lines

  local ast = parse(src)
  local started = os.clock()
  local result = Scope.analyze(ast, { seed = 5 })
  Scope.apply(result)
  local text = Emit.source(ast)
  local elapsed = os.clock() - started

  check("scale: no diagnostics", #result.errors == 0, errorText(result))
  check("scale: all bindings found", result.stats.bindings == 1000, result.stats.bindings)
  check("scale: bindings renamed", result.stats.renamed == 1000, result.stats.renamed)
  check("scale: under three seconds", elapsed < 3, elapsed)
  check("scale: AST valid", #Ast.validate(ast) == 0)
  check("scale: source has no leftovers", text:find("local a%d") == nil)
  notes[#notes + 1] = string.format("MODULE2_SCALE lines=%d bindings=%d ms=%.1f",
    lineCount, result.stats.bindings, elapsed * 1000)
end

-- ---------------------------------------------------------------------------
-- 18. Empty and comment-only inputs
-- ---------------------------------------------------------------------------
do
  local ast, result = compile("-- nothing here\n")
  check("empty: one function", result.stats.functions == 1, result.stats.functions)
  check("empty: no bindings", result.stats.bindings == 0, result.stats.bindings)
  check("empty: no errors", #result.errors == 0)
  check("empty: emitted blank", Emit.source(ast):match("^%s*$") ~= nil)
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
emit(string.format("MODULE2_CHECKS %d/%d", checks - failures, checks))
emit("MODULE2_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
