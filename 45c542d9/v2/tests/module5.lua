-- module5.lua -- acceptance tests for constant hiding (layer 5).
--
-- Pipeline order under test: parse -> analyze/rename -> consts, and then the
-- full order parse -> analyze -> consts -> flatten -> opaque to prove that
-- hiding constants does not disturb the structural passes that follow.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Consts = require("src.consts")
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

local function evalValue(node, setup)
  local src = (setup or "") .. "\nreturn " .. Emit.expr(node)
  local chunk, err = loadChunk(src, "@expr")
  if not chunk then return nil, tostring(err) end
  local ok, value = pcall(chunk)
  if not ok then return nil, tostring(value) end
  return value
end

-- Numeric tokens only: identifiers (including the 16-hex names from layer 2)
-- are stripped first so their digits cannot be mistaken for constants.
local function numberTokens(text)
  local stripped = text:gsub("([^%w_])[%a_][%w_]*", "%1 ")
  stripped = stripped:gsub("^[%a_][%w_]*", " ")
  local out = {}
  for token in stripped:gmatch("%-?%d+%.?%d*") do
    out[#out + 1] = tonumber(token)
  end
  return out
end

local function hasNumber(text, value)
  local tokens = numberTokens(text)
  for i = 1, #tokens do
    if tokens[i] == value then return true end
  end
  return false
end

local function countType(root, typ)
  return #Ast.find(root, typ)
end

-- Layers 1-2 then layer 5.
local function runConsts(src, opts)
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local renamed = Emit.source(ast)
  local stats = Consts.run(ast, opts or { seed = 0xC0FFEE })
  return ast, result, renamed, stats, Emit.source(ast)
end

-- Full order: 1-2, then 5, then 3, then 4.
local function runFull(src)
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local stats = Consts.run(ast, { seed = 0xC0FFEE })
  local flattenStats = Flatten.run(ast, { seed = 0xBEEF })
  local opaqueStats = Opaque.run(ast, { seed = 0xF00D })
  return ast, result, stats, flattenStats, opaqueStats, Emit.source(ast)
end

local function checkProgram(name, src, expected)
  local original, originalErr = execute(src)
  check(name .. ": original executes", original ~= nil, originalErr)
  if expected ~= nil then
    check(name .. ": original output", original == expected, original)
  end

  local ast, result, renamed, stats, text = runConsts(src)
  check(name .. ": analyze clean", #result.errors == 0, errorText(result))

  local renamedOut, renamedErr = execute(renamed)
  check(name .. ": renamed output", renamedOut == original, renamedErr or renamedOut)

  local out, outErr = execute(text)
  check(name .. ": hidden output", out == original, outErr or out)
  if expected ~= nil then
    check(name .. ": hidden expected", out == expected, out)
  end

  local violations = Ast.validate(ast)
  check(name .. ": hidden AST valid", #violations == 0, violations[1])
  return ast, stats, text
end

local function checkFull(name, src, expected)
  local original, originalErr = execute(src)
  check(name .. ": original executes", original ~= nil, originalErr)
  if expected ~= nil then
    check(name .. ": original output", original == expected, original)
  end

  local ast, result, constsStats, _, opaqueStats, text = runFull(src)
  check(name .. ": analyze clean", #result.errors == 0, errorText(result))
  check(name .. ": consts hid literals", constsStats.total > 0, constsStats.total)
  check(name .. ": opaque wraps conditions", opaqueStats.conditions > 0,
    opaqueStats.conditions)
  local out, outErr = execute(text)
  check(name .. ": full output", out == original, outErr or out)
  if expected ~= nil then
    check(name .. ": full expected", out == expected, out)
  end
  local violations = Ast.validate(ast)
  check(name .. ": full AST valid", #violations == 0, violations[1])
end

-- ---------------------------------------------------------------------------
-- 1. Every integer shape is exact
-- ---------------------------------------------------------------------------
do
  local state = 424242
  local function rng(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (state % n) + 1
  end

  local values = { 0, 1, 2, 3, 7, 42, 255, 1000, 12345, 65535,
    4503599627370496, -1, -7, -12345, -4503599627370496 }

  check("integer shapes count", #Consts.INTEGER_SHAPES >= 10, #Consts.INTEGER_SHAPES)
  for shapeIndex = 1, #Consts.INTEGER_SHAPES do
    local shape = Consts.INTEGER_SHAPES[shapeIndex]
    local bad
    for i = 1, #values do
      local value = values[i]
      local expr = shape.build(value, rng, 1, 1)
      local got, err = evalValue(expr)
      if err or got ~= value then
        bad = "v=" .. value .. " -> " .. tostring(got) .. " " .. tostring(err or "")
        break
      end
    end
    check("integer shape " .. shape.id, bad == nil, bad)
  end
end

-- ---------------------------------------------------------------------------
-- 2. Float shapes are exact
-- ---------------------------------------------------------------------------
do
  local state = 777
  local function rng(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (state % n) + 1
  end

  local values = { 0.1, 0.25, 1.5, -2.75, 3.141592653589793, 1e-300, 1e-10 }
  check("float shapes count", #Consts.FLOAT_SHAPES >= 4, #Consts.FLOAT_SHAPES)
  for shapeIndex = 1, #Consts.FLOAT_SHAPES do
    local shape = Consts.FLOAT_SHAPES[shapeIndex]
    local bad
    for i = 1, #values do
      local value = values[i]
      local expr = shape.build(value, rng, 1, 1)
      local got, err = evalValue(expr)
      if err or got ~= value then
        bad = "v=" .. tostring(value) .. " -> " .. tostring(got) .. " " .. tostring(err or "")
        break
      end
    end
    check("float shape " .. shape.id, bad == nil, bad)
  end
end

-- ---------------------------------------------------------------------------
-- 3. Boolean and nil shapes are exact and single-valued
-- ---------------------------------------------------------------------------
do
  local state = 999
  local function rng(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (state % n) + 1
  end

  check("true shapes count", #Consts.TRUE_SHAPES >= 4, #Consts.TRUE_SHAPES)
  for i = 1, #Consts.TRUE_SHAPES do
    local shape = Consts.TRUE_SHAPES[i]
    local got, err = evalValue(shape.build(rng, 1, 1))
    check("true shape " .. shape.id, not err and got == true, err or got)
  end

  check("false shapes count", #Consts.FALSE_SHAPES >= 4, #Consts.FALSE_SHAPES)
  for i = 1, #Consts.FALSE_SHAPES do
    local shape = Consts.FALSE_SHAPES[i]
    local got, err = evalValue(shape.build(rng, 1, 1))
    check("false shape " .. shape.id, not err and got == false, err or tostring(got))
  end

  check("nil shapes count", #Consts.NIL_SHAPES >= 3, #Consts.NIL_SHAPES)
  for i = 1, #Consts.NIL_SHAPES do
    local shape = Consts.NIL_SHAPES[i]
    local expr = shape.build(rng, 1, 1)
    local got, err = evalValue(expr)
    check("nil shape " .. shape.id, not err and got == nil, err or tostring(got))
    local arity = evalValue({ type = "Call", line = 1, col = 1, children = {
      { type = "Name", value = "select", line = 1, col = 1, children = {} },
      { type = "String", value = "#", line = 1, col = 1, children = {} },
      expr,
    } })
    check("nil shape arity " .. shape.id, arity == 1, arity)
  end
end

-- ---------------------------------------------------------------------------
-- 4. Driver-level value preservation for numbers
-- ---------------------------------------------------------------------------
do
  local values = { 0, 1, 2, 3, 7, 42, 255, 1000, 12345, 65535,
    4503599627370496, -1, -7, -12345 }
  for i = 1, #values do
    local value = values[i]
    -- %.0f keeps 2^52 exact; 5.1's tostring would emit 4.5035996273705e+15.
    local src = "local x = " .. string.format("%.0f", value) .. "\nprint(x)"
    local ast, _, _, stats, text = runConsts(src)
    local out, err = execute(text)
    check("driver integer " .. value, out == tostring(value), err or out)
    check("driver integer hidden " .. value, not hasNumber(text, value), text)
    check("driver integer counted " .. value, stats.numbers == 1, stats.numbers)
  end

  local floats = { 0.1, 0.25, 1.5, -2.75 }
  for i = 1, #floats do
    local text = select(5, runConsts("local x = " .. floats[i] .. "\nprint(x)"))
    local out, err = execute(text)
    check("driver float " .. floats[i], out ~= nil, err or out)
    local got = tonumber(out)
    check("driver float value " .. floats[i], got == floats[i], out)
  end
end

-- ---------------------------------------------------------------------------
-- 5. Semantics corpus through layers 1-2 and 5
-- ---------------------------------------------------------------------------
checkProgram("arithmetic", "print(1 + 2 * 3)", "7")

checkProgram("table-index", [[
local t = {[7] = "seven", 1, 2}
print(t[7], #t)
]], "seven\t2")

checkProgram("concat", [[
print("n=" .. 42 .. "!")
]], "n=42!")

checkProgram("booleans", [[
local x = true
local y = false
if x and not y then print("ok") end
]], "ok")

checkProgram("nil-check", [[
local x = nil
if x == nil then print("nil") end
]], "nil")

checkProgram("nil-arity", [[
local function n(...) return select("#", ...) end
local function g() return nil end
print(n(nil), n(1, nil), n(nil, nil), n(), n(g()))
]], "1\t2\t2\t0\t1")

checkProgram("nil-table", [[
local t = {1, nil, 3}
print(t[1], t[2], t[3])
]], "1\tnil\t3")

checkProgram("floats", [[
print(1.5 + 0.25 == 1.75, (0.1 + 0.2) == 0.3, math.floor(2.75 * 4))
]], "true\tfalse\t11")

checkProgram("numeric-for", [[
local s = 0
for i = 1, 10 do s = s + i end
print(s)
]], "55")

checkProgram("while-true", [[
local i = 0
while true do
  i = i + 1
  if i == 3 then break end
end
print(i)
]], "3")

checkProgram("hex-numbers", "print(0xFF + 0x10)", "271")

checkProgram("negative", [[
local x = -12345
print(x)
]], "-12345")

checkProgram("index-write", [[
local t = {}
t[5] = "x"
print(t[5], t[4])
]], "x\tnil")

checkProgram("big-integer", "print(4503599627370496 + 1 == 4503599627370497)", "true")

checkProgram("boolean-keys", [[
local t = {[true] = "yes", [false] = "no"}
print(t[true], t[false])
]], "yes\tno")

checkProgram("multi-assign", [[
local a, b = 1, nil
print(a, b)
]], "1\tnil")

checkProgram("nil-key", [[
local t = {[1] = nil}
print(t[1], t[2])
]], "nil\tnil")

checkProgram("nested-constants", [[
local a = 10
local b = 20
local c = 30
print(a * b + c, (a + b) * c, a * (b + c))
]], "230\t900\t500")

-- ---------------------------------------------------------------------------
-- 6. Full pipeline: consts -> flatten -> opaque
-- ---------------------------------------------------------------------------
checkFull("full-if", [[
local function pick(n)
  if n > 10 then return 1 end
  if n > 5 then return 2 end
  return 3
end
print(pick(20), pick(7), pick(1))
]], "1\t2\t3")

checkFull("full-loop", [[
local s = 0
for i = 1, 5 do
  if i % 2 == 0 then s = s + i end
end
print(s)
]], "6")

checkFull("full-bool-nil", [[
local flag = true
local missing = nil
if flag and missing == nil then print("yes") end
]], "yes")

-- ---------------------------------------------------------------------------
-- 7. Structure: no identifiers, literal types removed, keys stay linked
-- ---------------------------------------------------------------------------
do
  local src = [[
local secret = 12345
local flag = true
local nothing = nil
local t = {[12345] = "v"}
print(secret, flag, nothing, t[12345])
]]
  local ast, result, _, stats, text = runConsts(src)

  check("structure: analyze clean", #result.errors == 0, errorText(result))
  check("structure: all literals hidden", stats.numbers == 3 and stats.booleans == 1 and
    stats.nils == 1 and stats.total == 5, stats.total)
  check("structure: no Boolean left", countType(ast, "Boolean") == 0, countType(ast, "Boolean"))
  check("structure: no Nil left", countType(ast, "Nil") == 0, countType(ast, "Nil"))
  check("structure: nodes added", stats.added > 5, stats.added)

  -- Layer 5 owns no names: the identifier and declaration counts are untouched.
  local raw = parse(src)
  local result2 = Scope.analyze(raw, { seed = 0x51EED })
  Scope.apply(result2)
  local namesBefore = countType(raw, "Name")
  local localsBefore = countType(raw, "Local")
  Consts.run(raw, { seed = 0xC0FFEE })
  check("structure: no names created", countType(raw, "Name") == namesBefore,
    countType(raw, "Name") .. " ~= " .. namesBefore)
  check("structure: no locals created", countType(raw, "Local") == localsBefore,
    countType(raw, "Local") .. " ~= " .. localsBefore)

  -- TableField.key is a reference, not an index: it must follow the rewrite.
  local fields = Ast.find(ast, "TableField")
  local linked = false
  for i = 1, #fields do
    local f = fields[i]
    if f.key and f.kind == "key" then
      linked = (f.key == f.children[1]) and f.key.synthetic == true
    end
  end
  check("structure: table key relinked", linked)

  check("structure: original value absent", not hasNumber(text, 12345), text)
  check("structure: no nil token", text:find("nil", 1, true) == nil, text)
  check("structure: no boolean token", text:find("true", 1, true) == nil and
    text:find("false", 1, true) == nil, text)
  check("structure: output", execute(text) == "12345\ttrue\tnil\tv", execute(text))
  check("structure: AST valid", #Ast.validate(ast) == 0, Ast.validate(ast)[1])

  local synthetic = 0
  Ast.walk(ast, function(n)
    if n.synthetic then synthetic = synthetic + 1 end
  end)
  check("structure: synthetic roots", synthetic == stats.total, synthetic)

  -- Idempotence: a second pass must not re-hide generated constants.
  local before = Emit.source(ast)
  local again = Consts.run(ast, { seed = 0xC0FFEE })
  check("structure: second pass no-op", again.total == 0, again.total)
  check("structure: text stable", Emit.source(ast) == before)
end

-- ---------------------------------------------------------------------------
-- 8. Skip rules
-- ---------------------------------------------------------------------------
do
  local src = "local a = 12345\nlocal b = true\nlocal c = nil\nprint(a, b, c)"
  local ast = parse(src)
  local before = Emit.source(ast)
  local stats = Consts.run(ast, { enabled = false })
  check("skip-disabled: nothing hidden", stats.total == 0, stats.total)
  check("skip-disabled: reason", stats.skipped.disabled == 1)
  check("skip-disabled: text untouched", Emit.source(ast) == before)
end

do
  local src = "local a = 12345\nlocal b = true\nlocal c = nil\nprint(a, b, c)"
  local ast = parse(src)
  local stats = Consts.run(ast, { numbers = false })
  check("skip-numbers: numbers untouched", stats.numbers == 0, stats.numbers)
  check("skip-numbers: booleans hidden", stats.booleans == 1, stats.booleans)
  check("skip-numbers: nils hidden", stats.nils == 1, stats.nils)
  check("skip-numbers: output", execute(Emit.source(ast)) == "12345\ttrue\tnil")
end

do
  local src = "local a = 12345\nlocal b = true\nlocal c = nil\nprint(a, b, c)"
  local ast = parse(src)
  local before = Emit.source(ast)
  local stats = Consts.run(ast, { prob = 0 })
  check("skip-prob: nothing hidden", stats.total == 0, stats.total)
  check("skip-prob: reason", stats.skipped.prob == 3, stats.skipped.prob)
  check("skip-prob: text untouched", Emit.source(ast) == before)
end

do
  local ast = parse("local x = 0.5\nprint(x)")
  local stats = Consts.run(ast, { floats = false })
  check("skip-floats: float untouched", stats.skipped.float == 1, stats.skipped.float)
  check("skip-floats: text keeps literal", Emit.source(ast):find("0.5", 1, true) ~= nil,
    Emit.source(ast))
end

do
  local ast = parse("local x = 1e16\nprint(x == 1e16)")
  local stats = Consts.run(ast)
  check("skip-huge: huge integer untouched", stats.skipped.huge == 2, stats.skipped.huge)
  check("skip-huge: output", execute(Emit.source(ast)) == "true",
    execute(Emit.source(ast)))
end

do
  local stats = Consts.run(nil)
  check("invalid: rejected", stats.total == 0 and stats.skipped.disabled == 1)
end

-- ---------------------------------------------------------------------------
-- 9. Determinism and polymorphism
-- ---------------------------------------------------------------------------
do
  local src = [[
local a = 12345
local b = 6789
local c = true
local d = false
local e = nil
print(a + b, c, d, e)
]]
  local function variant(seed)
    local ast = parse(src)
    local result = Scope.analyze(ast, { seed = 0x1234 })
    Scope.apply(result)
    local stats = Consts.run(ast, { seed = seed })
    return Emit.source(ast), stats
  end

  local a, sa = variant(7)
  local b = variant(7)
  check("determinism: same seed reproduces", a == b)
  check("determinism: different seed diverges", a ~= variant(8))
  check("determinism: literal count stable", sa.total == select(2, variant(99)).total)

  local seen, unique = {}, true
  local shapes = {}
  local shapeCount = 0
  for seed = 1, 10 do
    local text, stats = variant(seed)
    if seen[text] then unique = false end
    seen[text] = true
    local out = execute(text)
    if out ~= "19134\ttrue\tfalse\tnil" then
      check("determinism: seed " .. seed .. " output", false, out)
    end
    for id in pairs(stats.shapes) do
      if not shapes[id] then
        shapes[id] = true
        shapeCount = shapeCount + 1
      end
    end
  end

  check("determinism: ten seeds, ten outputs", unique)
  check("determinism: output preserved", execute(a) == "19134\ttrue\tfalse\tnil", execute(a))
  check("determinism: many shapes used", shapeCount >= 8, shapeCount)
  notes[#notes + 1] = string.format("MODULE5_POLY 10/10 shapes=%d", shapeCount)
end

-- ---------------------------------------------------------------------------
-- 10. Scale: 300 constants
-- ---------------------------------------------------------------------------
do
  local lines = { "local function big()", "  local s = 0" }
  for i = 1, 300 do
    lines[#lines + 1] = "  s = s + " .. i
  end
  lines[#lines + 1] = "  return s"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = "print(big())"
  local src = table.concat(lines, "\n")

  local started = os.clock()
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local stats = Consts.run(ast, { seed = 5 })
  local text = Emit.source(ast)
  local elapsed = os.clock() - started

  check("scale: analyze clean", #result.errors == 0, errorText(result))
  check("scale: all numbers hidden", stats.numbers == 301, stats.numbers)
  check("scale: AST valid", #Ast.validate(ast) == 0, Ast.validate(ast)[1])
  local out, err = execute(text)
  check("scale: output", out == "45150", err or out)
  check("scale: nodes added", stats.added >= 301 * 3, stats.added)
  check("scale: under two seconds", elapsed < 2, elapsed)
  notes[#notes + 1] = string.format("MODULE5_SCALE literals=%d nodes=%d ms=%.1f",
    stats.total, Ast.count(ast).nodes, elapsed * 1000)
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
emit(string.format("MODULE5_CHECKS %d/%d", checks - failures, checks))
emit("MODULE5_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
