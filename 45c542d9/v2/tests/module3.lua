-- module3.lua -- acceptance tests for control-flow flattening (layer 3).
-- Run from the v2 directory or with package.path pointing at v2 and v2/src.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Flatten = require("src.flatten")
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

local function bindingsNamed(result, name)
  local out = {}
  for i = 1, #result.bindings do
    if result.bindings[i].name == name then out[#out + 1] = result.bindings[i] end
  end
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

local function runFlatten(src, opts)
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local renamed = Emit.source(ast)
  local stats = Flatten.run(ast, opts or { seed = 0xBEEF })
  return ast, stats, result, renamed, Emit.source(ast)
end

-- Original, scope-renamed and flattened programs must all agree.
local function checkProgram(name, src, expected)
  local original, originalErr = execute(src)
  check(name .. ": original executes", original ~= nil, originalErr)
  if expected ~= nil then
    check(name .. ": original output", original == expected, original)
  end

  local ast, stats, result, renamed, text = runFlatten(src)
  check(name .. ": analyze clean", #result.errors == 0, errorText(result))
  local renamedOut, renamedErr = execute(renamed)
  check(name .. ": renamed output", renamedOut == original, renamedErr or renamedOut)
  local out, outErr = execute(text)
  check(name .. ": flattened output", out == original, outErr or out)
  local violations = Ast.validate(ast)
  check(name .. ": flattened AST valid", #violations == 0, violations[1])
  return ast, stats, text
end

local function ceilLog2(n)
  local depth, span = 0, 1
  while span < n do
    span = span * 2
    depth = depth + 1
  end
  return depth
end

-- ---------------------------------------------------------------------------
-- 1. Semantics corpus: if/elseif/else, nested, returns
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

checkProgram("early-return", [[
local function f(n)
  local r = n
  if n < 0 then
    return -1
  end
  if n == 0 then
    return 0
  end
  return r
end
print(f(-5), f(0), f(5))
]], "-1\t0\t5")

checkProgram("empty-branches", [[
local function f(c)
  local r = 0
  if c then
  else
    r = 1
  end
  if not c then
    r = r + 1
  end
  return r
end
print(f(true), f(false))
]], "0\t2")

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

-- ---------------------------------------------------------------------------
-- 2. Locals: hoisting must preserve binding identity
-- ---------------------------------------------------------------------------
checkProgram("branch-local-scope", [[
local g = 7
local function f(c)
  if c then
    local v = 1
    print(v)
  end
  print(v)
end
f(true)
print(g)
]], "1\nnil\n7")

checkProgram("shadowing", [[
local v = 1
local function f()
  if v > 0 then
    local v = 2
    return v
  end
  return v
end
print(f())
]], "2")

checkProgram("initializer-sees-outer", [[
local x = 5
local function f()
  local x = x
  if x then
    return x
  end
  return -1
end
print(f())
]], "5")

checkProgram("do-block-hoist", [[
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

checkProgram("multi-return", [[
local function f(c)
  local a, b
  if c then
    a, b = 1, 2
  else
    a, b = 3, 4
  end
  return a, b
end
local x, y = f(true)
local z, w = f(false)
print(x, y, z, w)
]], "1\t2\t3\t4")

-- ---------------------------------------------------------------------------
-- 3. Closures and upvalues
-- ---------------------------------------------------------------------------
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

checkProgram("closure-write-upvalue", [[
local function counter(start)
  local n = start
  local bump
  if start then
    bump = function()
      n = n + 1
      return n
    end
  else
    bump = function() return n end
  end
  return bump(), bump()
end
print(counter(10))
]], "11\t12")

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

-- ---------------------------------------------------------------------------
-- 4. Loops: per-iteration locals, break/continue sentinels
-- ---------------------------------------------------------------------------
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

checkProgram("nested-loop-break", [[
local sum = 0
for i = 1, 5 do
  for j = 1, 5 do
    if j == 3 then break end
    sum = sum + 1
  end
end
print(sum)
]], "10")

checkProgram("closure-per-iteration", [[
local out = {}
for i = 1, 3 do
  local x = i * 10
  local y = x + 1
  if i > 0 then
    out[i] = function() return x end
  end
end
print(out[1](), out[2](), out[3]())
]], "10\t20\t30")

checkProgram("repeat-until-locals", [[
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

checkProgram("loop-inside-state", [[
local function f(n)
  local sum = 0
  for i = 1, n do
    sum = sum + i
  end
  if sum > 3 then
    sum = sum * 2
  end
  return sum
end
print(f(3), f(1))
]], "12\t1")

checkProgram("repeat-break", [[
local i = 0
repeat
  i = i + 1
  local done = i >= 3
  if done then break end
until false
print(i)
]], "3")

checkProgram("numeric-for-step", [[
local sum = 0
for i = 10, 1, -2 do
  local half = i / 2
  if half > 2 then
    sum = sum + i
  end
end
print(sum)
]], "24")

checkProgram("generic-for-pairs", [[
local total = 0
local t = { a = 1, b = 2, c = 3 }
for k, v in pairs(t) do
  local keep = v > 1
  if keep then
    total = total + v
  end
end
print(total)
]], "5")

checkProgram("for-return", [[
local function find(t, n)
  for i = 1, #t do
    local v = t[i]
    if v == n then
      return i
    end
  end
  return 0
end
print(find({"a", "b", "c"}, "b"), find({"a"}, "z"))
]], "2\t0")

-- ---------------------------------------------------------------------------
-- 5. Params, varargs, methods, chunk level
-- ---------------------------------------------------------------------------
checkProgram("vararg-return", [[
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

checkProgram("chunk-return", [[
local mode = "a"
if mode == "a" then
  print("A")
  return
end
print("B")
]], "A")

-- ---------------------------------------------------------------------------
-- 6. Structure of the generated machine
-- ---------------------------------------------------------------------------
do
  local src = [[
local function f(a, b)
  local s = a + b
  if s > 10 then
    s = s - 10
  elseif s < 0 then
    s = 0
  end
  return s
end
print(f(12, 5), f(1, 2), f(-5, 1))
]]
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local whileBefore = #Ast.find(ast, "While")
  local callBefore = #Ast.find(ast, "CallStatement")
  local returnBefore = #Ast.find(ast, "Return")

  local stats = Flatten.run(ast, { seed = 9 })
  local text = Emit.source(ast)

  check("structure: one machine", stats.flattened == 1, stats.flattened)
  check("structure: machine stats", stats.machines[1] ~= nil and stats.machines[1].states >= 4,
    stats.machines[1] and stats.machines[1].states)
  check("structure: state budget counted", stats.machines[1].states == stats.states,
    stats.states)
  check("structure: one hoisted local", stats.hoisted == 1, stats.hoisted)
  check("structure: while count", #Ast.find(ast, "While") == whileBefore + stats.flattened,
    #Ast.find(ast, "While"))
  check("structure: calls preserved", #Ast.find(ast, "CallStatement") == callBefore,
    #Ast.find(ast, "CallStatement"))
  check("structure: returns preserved", #Ast.find(ast, "Return") == returnBefore,
    #Ast.find(ast, "Return"))

  local machines = {}
  Ast.walk(ast, function(n)
    if n.type == "While" and n.children[1] and n.children[1].type == "Boolean" then
      machines[#machines + 1] = n
    end
  end)
  check("structure: machine loop found", #machines == 1, #machines)

  local sInfo = bindingsNamed(result, "s")[1]
  local fn = Ast.find(ast, "Function")[1]
  local prelude = fn.children[1]
  check("structure: prelude is local", prelude ~= nil and prelude.type == "Local")
  check("structure: hoisted name declared",
    prelude ~= nil and prelude.names[1] == sInfo.newName, prelude and prelude.names[1])
  check("structure: machine name pattern",
    stats.machines[1].name:match("^_0x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil,
    stats.machines[1].name)
  check("structure: machine name unique", stats.machines[1].name ~= sInfo.newName)

  local multi = 0
  Ast.walk(fn, function(n)
    if n.type == "If" and #(n.branches or {}) > 1 then multi = multi + 1 end
  end)
  check("structure: no multi-branch if left", multi == 0, multi)

  local bound = ceilLog2(stats.machines[1].states) + 1
  check("structure: router depth bounded", stats.machines[1].depth <= bound,
    stats.machines[1].depth .. " > " .. bound)

  local out = execute(text)
  check("structure: output", out == "7\t3\t0", out)
  check("structure: AST valid", #Ast.validate(ast) == 0)
  notes[#notes + 1] = string.format("MODULE3_MACHINE states=%d depth=%d hoisted=%d",
    stats.machines[1].states, stats.machines[1].depth, stats.hoisted)
end

-- ---------------------------------------------------------------------------
-- 7. Break / continue sentinels are visible in the output
-- ---------------------------------------------------------------------------
do
  local ast, stats, _, _, text = runFlatten([[
local i = 0
while i < 9 do
  i = i + 1
  if i == 3 then break end
end
print(i)
]])
  check("sentinel: loop body flattened", stats.flattened == 1, stats.flattened)
  check("sentinel: break transition emitted", text:find("== -1 then", 1, true) ~= nil)
  check("sentinel: program output", execute(text) == "3", execute(text))
  check("sentinel: AST valid", #Ast.validate(ast) == 0)

  local ast2, stats2, _, _, text2 = runFlatten([[
local i = 0
while i < 5 do
  i = i + 1
  local odd = i % 2
  if odd == 0 then
    continue
  end
end
print(i)
]])
  check("continue: loop body flattened", stats2.flattened == 1, stats2.flattened)
  check("continue: sentinel emitted", text2:find("== -2 then", 1, true) ~= nil)
  check("continue: source still has continue", text2:find("continue", 1, true) ~= nil)
  check("continue: AST valid", #Ast.validate(ast2) == 0)
end

-- ---------------------------------------------------------------------------
-- 8. Skip rules
-- ---------------------------------------------------------------------------
do
  local ast, stats = parse("if true then\n  print(1)\nend")
  local before = Emit.source(ast)
  local s = Flatten.run(ast, { seed = 3 })
  check("skip-small: not flattened", s.flattened == 0, s.flattened)
  check("skip-small: reason", (s.skipped.small or 0) == 1, s.skipped.small)
  check("skip-small: text untouched", Emit.source(ast) == before)
  check("skip-small: runs", execute(Emit.source(ast)) == "1")
end

do
  local ast, stats = parse("print(1)\nprint(2)\nprint(3)\nprint(4)")
  local s = Flatten.run(ast, { seed = 3 })
  check("skip-noif: not flattened", s.flattened == 0, s.flattened)
  check("skip-noif: reason", (s.skipped.noif or 0) == 1, s.skipped.noif)
end

do
  local src = [[
local function f(x)
  local s = 0
  if x then
    s = 1
    goto done
  end
  s = 2
  ::done::
  return s
end
print(f(true), f(false))
]]
  local ast, stats, result, renamed, text = runFlatten(src)
  check("skip-goto: not flattened", stats.flattened == 0, stats.flattened)
  check("skip-goto: reason", (stats.skipped["goto"] or 0) == 1, stats.skipped["goto"])
  check("skip-goto: goto preserved", text:find("goto", 1, true) ~= nil)
  check("skip-goto: AST valid", #Ast.validate(ast) == 0)
  if _VERSION ~= "Lua 5.1" then
    check("skip-goto: output", execute(text) == "1\t2", execute(text))
  end
end

do
  local src = [[
local function f(c)
  local x <const> = 1
  local y = 2
  if c then
    return x
  end
  return y
end
print(f(true))
]]
  local ast, stats = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local s = Flatten.run(ast, { seed = 3 })
  check("skip-attrs: not flattened", s.flattened == 0, s.flattened)
  check("skip-attrs: reason", (s.skipped.attrs or 0) == 1, s.skipped.attrs)
end

do
  local src = [[
local function f(c)
  local a = 1
  local b = 2
  if c then
    return a
  end
  return b
end
print(f(true))
]]
  local ast = parse(src)
  local before = Emit.source(ast)
  local s = Flatten.run(ast, { seed = 3 })
  check("skip-unscoped: not flattened", s.flattened == 0, s.flattened)
  check("skip-unscoped: reason", (s.skipped.unscoped or 0) >= 1, s.skipped.unscoped)
  check("skip-unscoped: text untouched", Emit.source(ast) == before)
end

do
  local ast, stats, _, renamed, text = runFlatten([[
local function f(a, b)
  local s = a + b
  local t = a - b
  if s > 10 then
    s = s - 10
  end
  return s + t
end
print(f(12, 5))
]], { seed = 3, enabled = false })
  check("skip-disabled: not flattened", stats.flattened == 0, stats.flattened)
  check("skip-disabled: text untouched", text == renamed)
end

do
  local ast, stats, _, _, _ = runFlatten([[
local function f(a, b)
  local s = a + b
  local t = a - b
  if s > 10 then
    s = s - 10
  end
  return s + t
end
print(f(12, 5))
]], { seed = 3, maxHoisted = 1 })
  check("skip-locals: not flattened", stats.flattened == 0, stats.flattened)
  check("skip-locals: reason", (stats.skipped.locals or 0) >= 1, stats.skipped.locals)
end

do
  local ast, stats, _, _, _ = runFlatten([[
local function f(c)
  local _ENV = { print = print }
  if c then
    return 1
  end
  return 0
end
print(f(true))
]], { seed = 3 })
  check("skip-reserved: not flattened", stats.flattened == 0, stats.flattened)
  check("skip-reserved: reason", (stats.skipped.reserved or 0) == 1, stats.skipped.reserved)
end

do
  local ast, stats, _, _, _ = runFlatten([[
local function f(a)
  local s = a
  if s > 0 then
    s = s + 1
  end
  return s
end
print(f(1))
]], { seed = 3, minStatements = 100 })
  check("skip-threshold: not flattened", stats.flattened == 0, stats.flattened)
  check("skip-threshold: reason", (stats.skipped.small or 0) >= 1, stats.skipped.small)
end

do
  local ast, stats = parse("print(1)")
  local s = Flatten.run(ast, { seed = 3 })
  check("empty: nothing to do", s.flattened == 0 and s.states == 0, s.flattened)
end

-- ---------------------------------------------------------------------------
-- 9. Determinism and polymorphism
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
    local stats = Flatten.run(ast, { seed = seed })
    return Emit.source(ast), stats
  end

  local a, sa = variant(7)
  local b = variant(7)
  check("determinism: same seed reproduces", a == b)
  check("determinism: different seed diverges", a ~= variant(8))
  check("determinism: state count stable", sa.states == select(2, variant(99)).states)

  local seen, unique, names = {}, true, {}
  local statesSame = true
  for seed = 1, 10 do
    local text, stats = variant(seed)
    if seen[text] then unique = false end
    seen[text] = true
    local machine = stats.machines[1]
    if names[machine.name] then unique = false end
    names[machine.name] = true
    if machine.states ~= sa.states then statesSame = false end
  end
  check("determinism: ten seeds, ten outputs", unique)
  check("determinism: ten distinct machine names", (function()
    local n = 0
    for _ in pairs(names) do n = n + 1 end
    return n == 10
  end)())
  check("determinism: shape is seed independent", statesSame)
  check("determinism: output preserved", execute(a) == "neg\tzero\tpos", execute(a))
  notes[#notes + 1] = "MODULE3_POLY 10/10"
end

-- ---------------------------------------------------------------------------
-- 10. Scale: 300 branches, flat dispatch stays logarithmic
-- ---------------------------------------------------------------------------
do
  local lines = { "local function big(n)", "  local acc = 0" }
  for i = 1, 300 do
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
  local stats = Flatten.run(ast, { seed = 5 })
  local text = Emit.source(ast)
  local elapsed = os.clock() - started

  check("scale: analyze clean", #result.errors == 0, errorText(result))
  check("scale: flattened", stats.flattened == 1, stats.flattened)
  check("scale: at least 300 states", stats.states >= 300, stats.states)
  check("scale: depth logarithmic",
    stats.machines[1].depth <= ceilLog2(stats.states) + 1,
    stats.machines[1].depth .. " > " .. (ceilLog2(stats.states) + 1))
  check("scale: AST valid", #Ast.validate(ast) == 0)
  check("scale: output", execute(text) == "45150", execute(text))
  check("scale: under five seconds", elapsed < 5, elapsed)
  notes[#notes + 1] = string.format("MODULE3_SCALE lines=%d states=%d depth=%d ms=%.1f",
    #lines, stats.states, stats.machines[1].depth, elapsed * 1000)
end

-- ---------------------------------------------------------------------------
-- 11. Machines inside loops keep loop context
-- ---------------------------------------------------------------------------
do
  local _, stats, _, _, text = runFlatten([[
local total = 0
for i = 1, 3 do
  for j = 1, 3 do
    local prod = i * j
    if prod % 2 == 0 then
      total = total + prod
    end
  end
end
print(total)
]])
  local loopMachines = 0
  for i = 1, #stats.machines do
    if stats.machines[i].loop then loopMachines = loopMachines + 1 end
  end
  check("loop-context: inner loop flattened", loopMachines >= 1, loopMachines)
  check("loop-context: output", execute(text) == "20", execute(text))
end

do
  local corpus = {
    [[
local x = 1
x = x + 2
x = x * 3
x = x - 4
x = x + 5
print(x)
]],
    [[
local function choose(n, ...)
  local value = 0
  local function read() return value end
  for i = 1, n do
    if i == 7 then break end
    if i % 2 == 0 then value = value + i else value = value - i end
  end
  local j = 0
  repeat
    j = j + 1
    if j == 3 then break end
    value = value + j
  until j >= n
  if n < 0 then return end
  return read(), select('#', ...), ...
end
print(choose(9, nil, false, 'end'))
print(choose(-1))
]],
  }
  local shapes, splitSeen = {}, false
  for ci = 1, #corpus do
    local expected = execute(corpus[ci])
    local first
    for seed = 1, 16 do
      local ast, stats, _, _, text = runFlatten(corpus[ci], {
        seed = seed, minIfs = 0, shapes = true, split = true,
        decoys = true, stateOffset = true,
      })
      local prefix = "hardened " .. ci .. "/" .. seed
      local actual, err = execute(text)
      check(prefix .. ": output", expected ~= nil and actual == expected, err or actual)
      check(prefix .. ": AST valid", #Ast.validate(ast) == 0)
      check(prefix .. ": machines present", stats.flattened > 0)
      if ci == 1 then
        if stats.states > 1 then splitSeen = true end
        if #Ast.find(ast, "Repeat") > 0 then
          shapes.repeatLoop = true
        else
          local loops = Ast.find(ast, "While")
          check(prefix .. ": dispatch loop present", #loops == 1, #loops)
          if loops[1] then shapes[loops[1].children[1].type] = true end
        end
      end
      if seed == 7 then first = text end
    end
    local _, _, _, _, again = runFlatten(corpus[ci], {
      seed = 7, minIfs = 0, shapes = true, split = true,
      decoys = true, stateOffset = true,
    })
    check("hardened " .. ci .. ": deterministic", first == again)
  end
  local count = 0
  for _ in pairs(shapes) do count = count + 1 end
  check("hardened: all dispatch shapes exercised", count == 3, count)
  check("hardened: straight-line body splitting exercised", splitSeen)

  local src = [[
local total = 0
if total == 0 then total = total + 1 end
if total == 1 then total = total + 2 end
if total == 3 then total = total + 4 end
print(total)
]]
  local _, baseline = runFlatten(src, { seed = 7 })
  local _, withDecoys, _, _, text = runFlatten(src, { seed = 7, decoys = true })
  check("hardened: decoy fixture eligible", baseline.flattened == 1 and baseline.states >= 4)
  local extra = withDecoys.states - baseline.states
  check("hardened: one or two decoys added", extra == 1 or extra == 2, extra)
  check("hardened: decoys preserve output", execute(text) == "7")
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
emit(string.format("MODULE3_CHECKS %d/%d", checks - failures, checks))
emit("MODULE3_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
