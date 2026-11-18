-- module1.lua -- acceptance tests for the v2 front-end.
-- Run from the v2 directory or with package.path pointing at v2 and v2/src.
local Lexer = require("src.lexer")
local Parser = require("src.parser")
local Ast = require("src.ast")

local results = {}
local failures = 0

local function check(name, ok, detail)
  if ok then
    results[#results + 1] = "PASS " .. name
  else
    failures = failures + 1
    local line = "FAIL " .. name
    if detail ~= nil then line = line .. ": " .. tostring(detail) end
    results[#results + 1] = line
  end
end

local function parse(src)
  local ast, errors = Parser.parse(src, "test.lua")
  return Ast.normalize(ast), errors
end

local function typeCount(root, typ)
  return #Ast.find(root, typ)
end

-- ---------------------------------------------------------------------------
-- 1. Lexer: token inventory, comments, numbers, strings, operators
-- ---------------------------------------------------------------------------
local lexSrc = [====[
-- line comment
--[==[ block comment ]==]
local s1 = "a\n" .. 'b' .. [[long]] .. [==[long2]==]
local n = 0x1p4 + 0b1010 + 1_000 + 10.5 + 0xFF
local t = { a = 1, [2] = 3, 4, }
local f = function(a, b, ...) return a end;
::top::
for i = 1, 10, 2 do if i % 2 == 0 then break end end
for k, v in pairs(t) do goto done end
::done::
while true do do break end end
repeat until true
local x = a and b or not c
local y = a < b and b <= c or b ~= c
local z = a | b & c ~ d << 1 >> 2
local q = f(1):m(2).x[3]
local u = "unary" .. #t .. -n
x = x + 1
print(x)
]====]

local lexTokens, lexErrors = Lexer.lex(lexSrc, "lex.lua")
check("lexer: no diagnostics on valid source", #lexErrors == 0, #lexErrors .. " errors")

local counts, raws = {}, {}
for i = 1, #lexTokens do
  local tk = lexTokens[i]
  counts[tk.t] = (counts[tk.t] or 0) + 1
  if tk.raw and #tk.raw > 0 then raws[#raws + 1] = tk.raw end
end
check("lexer: keywords", (counts["local"] or 0) >= 4 and (counts["for"] or 0) >= 2)
check("lexer: names", (counts["name"] or 0) >= 20, counts["name"])
check("lexer: numbers", (counts["number"] or 0) >= 5, counts["number"])
check("lexer: short and long strings", (counts["string"] or 0) >= 5, counts["string"])
check("lexer: operators", (counts["::"] or 0) >= 2 and (counts["|"] or 0) >= 1
  and (counts["<<"] or 0) >= 1 and (counts[";"] or 0) >= 1)
check("lexer: vararg token", (counts["..."] or 0) >= 1)
check("lexer: comments are not tokens",
  (counts["comment"] or 0) == 0 and #lexTokens < 400, #lexTokens)

local stringRaws = {}
for i = 1, #lexTokens do
  if lexTokens[i].t == "string" then stringRaws[#stringRaws + 1] = lexTokens[i].raw end
end
local sawLong = false
for i = 1, #stringRaws do
  if stringRaws[i] == "[[long]]" or stringRaws[i] == "[==[long2]==]" then sawLong = true end
end
check("lexer: long string raw text preserved", sawLong)

-- ---------------------------------------------------------------------------
-- 2. Numeric literal decoding
-- ---------------------------------------------------------------------------
local function numberValue(src)
  local tokens = Lexer.lex(src, "n.lua")
  return tokens[1] and tokens[1].v
end
check("lexer: hex float", numberValue("0x1p4") == 16, numberValue("0x1p4"))
check("lexer: hex integer", numberValue("0xFF") == 255, numberValue("0xFF"))
check("lexer: binary integer", numberValue("0b1010") == 10, numberValue("0b1010"))
check("lexer: digit separators", numberValue("1_000") == 1000, numberValue("1_000"))

-- ---------------------------------------------------------------------------
-- 3. Parser: Lua 5.1-5.4 corpus, normalized contract
-- ---------------------------------------------------------------------------
local root, errors = parse(lexSrc)
check("parser: valid corpus has no diagnostics", #errors == 0, #errors .. " errors")

local violations = Ast.validate(root)
check("ast: contract violations are zero", #violations == 0, violations[1])
check("ast: root is Chunk", root.type == "Chunk")

local stats = Ast.count(root)
check("ast: node count is realistic", stats.nodes >= 100, stats.nodes)
check("ast: depth is realistic", stats.maxDepth >= 6, stats.maxDepth)
check("ast: has statements",
  (stats.byType.Local or 0) >= 5 and (stats.byType.Assign or 0) >= 1 and
  (stats.byType.NumericFor or 0) >= 1 and (stats.byType.GenericFor or 0) >= 1 and
  (stats.byType.While or 0) >= 1 and (stats.byType.Repeat or 0) >= 1)
check("ast: has expressions",
  (stats.byType.BinaryOp or 0) >= 10 and (stats.byType.UnaryOp or 0) >= 1 and
  (stats.byType.Call or 0) >= 4 and (stats.byType.Table or 0) >= 1)
check("ast: has labels and goto",
  (stats.byType.Label or 0) >= 2 and (stats.byType.Goto or 0) >= 1)

local legacy = 0
Ast.walk(root, function(node)
  if node.t ~= nil then legacy = legacy + 1 end
end)
check("ast: no legacy 't' field", legacy == 0, legacy)

-- ---------------------------------------------------------------------------
-- 4. Operator precedence and associativity
-- ---------------------------------------------------------------------------
local precRoot = parse("return 1 + 2 * 3 ^ 4 .. \"x\" .. 5 and 6 or 7")
local ret = Ast.find(precRoot, "Return")[1]
local expr = ret and ret.children[1]
check("precedence: or is the root", expr and expr.type == "BinaryOp" and expr.op == "or")
local andNode = expr and expr.children[1]
check("precedence: and binds tighter than or",
  andNode and andNode.type == "BinaryOp" and andNode.op == "and")
local concat = andNode and andNode.children[1]
check("precedence: concat below and",
  concat and concat.type == "BinaryOp" and concat.op == "..")
check("precedence: concat is right associative",
  concat and concat.children[2] and concat.children[2].type == "BinaryOp" and
  concat.children[2].op == ".." and concat.children[2].children[2].value == 5)
local sum = concat and concat.children[1]
check("precedence: addition below concat",
  sum and sum.type == "BinaryOp" and sum.op == "+")
local mul = sum and sum.children[2]
check("precedence: multiplication below addition",
  mul and mul.type == "BinaryOp" and mul.op == "*")
local pow = mul and mul.children[2]
check("precedence: power below multiplication",
  pow and pow.type == "BinaryOp" and pow.op == "^")
check("precedence: power binds tighter than unary minus",
  (function()
    local r = parse("return -2 ^ 2")
    local e = Ast.find(r, "Return")[1].children[1]
    return e.type == "UnaryOp" and e.op == "-" and
      e.children[1].type == "BinaryOp" and e.children[1].op == "^"
  end)())

-- ---------------------------------------------------------------------------
-- 5. Statement shapes and child ordering
-- ---------------------------------------------------------------------------
local structSrc = [====[
local a, b = 1, 2
a = b
f(1)
function t.m(x) return x end
local function g() end
if x then y() elseif z then w() else q() end
for i = 1, 3 do end
for k, v in pairs(t) do end
while x do end
repeat until x
do end
return 1, 2
]====]
local sroot, serrors = parse(structSrc)
check("structure: parses without diagnostics", #serrors == 0, #serrors .. " errors")
check("structure: contract is sound", #Ast.validate(sroot) == 0)

local expected = {
  "Local", "Assign", "CallStatement", "FunctionDeclaration", "LocalFunction",
  "If", "NumericFor", "GenericFor", "While", "Repeat", "Do", "Return",
}
local actual = {}
for i = 1, #sroot.children do actual[i] = sroot.children[i].type end
local same = #actual == #expected
if same then
  for i = 1, #expected do
    if actual[i] ~= expected[i] then same = false; break end
  end
end
check("structure: top-level statement order", same, table.concat(actual, ","))

local localNode = sroot.children[1]
check("structure: local names are preserved",
  localNode.names and localNode.names[1] == "a" and localNode.names[2] == "b")
check("structure: local children are initializers",
  #localNode.children == 2 and localNode.children[1].value == 1)

local fnDecl = sroot.children[4]
check("structure: function declaration children",
  #fnDecl.children == 2 and fnDecl.children[1].type == "Index" and
  fnDecl.children[2].type == "Function")
local fn = fnDecl.children[2]
check("structure: function metadata",
  fn.params and fn.params[1] == "x" and fn.vararg == false and #fn.children == 1)

local ifNode = sroot.children[6]
check("structure: if flattens branches and else in order",
  #ifNode.children == 5, #ifNode.children)
check("structure: if branch condition and body",
  ifNode.children[1].type == "Name" and ifNode.children[2].type == "CallStatement" and
  ifNode.children[3].type == "Name" and ifNode.children[4].type == "CallStatement" and
  ifNode.children[5].type == "CallStatement")

local numFor = sroot.children[7]
check("structure: numeric for metadata and children",
  numFor.var == "i" and #numFor.children == 2 and
  numFor.children[1].value == 1 and numFor.children[2].value == 3)

local genFor = sroot.children[8]
check("structure: generic for children",
  genFor.names and genFor.names[1] == "k" and genFor.names[2] == "v" and
  #genFor.children == 1 and genFor.children[1].type == "Call")

local retNode = sroot.children[#sroot.children]
check("structure: return child list", retNode.type == "Return" and #retNode.children == 2)

local callStats = Ast.find(sroot, "CallStatement")
check("structure: source line numbers are kept", callStats[1].line == 3, callStats[1].line)

-- ---------------------------------------------------------------------------
-- 6. Luau syntax
-- ---------------------------------------------------------------------------
local luauSrc = [====[
type Point<T> = { x: T, y: T }
export type Alias = number
local function id<T>(value: T): T
  return value
end
local function clamp(n: number, lo: number, hi: number): number
  local v = n :: number
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end
local p: Point<number> = { x = 1, y = 2 }
p.x += 1
local total = 0
for i = 1, 5 do
  if i % 2 == 0 then continue end
  total += i
end
local label = `total = {total}`
local pick = if total > 0 then "pos" else "neg"
return id(total), p, label, pick, clamp(5, 0, 10)
]====]
local lroot, lerrors = parse(luauSrc)
check("luau: parses without diagnostics", #lerrors == 0, lerrors[1] and lerrors[1].msg)
check("luau: contract is sound", #Ast.validate(lroot) == 0)
check("luau: continue statement", #Ast.find(lroot, "Continue") == 1)
check("luau: if-expression", #Ast.find(lroot, "IfExpression") == 1)
check("luau: compound assignment lowered",
  #Ast.find(lroot, "Do") >= 2 and #Ast.find(lroot, "Assign") >= 2)
check("luau: interpolation lowers to concatenation",
  #Ast.find(lroot, "String") >= 1 and #Ast.find(lroot, "BinaryOp") >= 1)
local luauStats = Ast.count(lroot)
check("luau: function type annotations are erased",
  (luauStats.byType.Name or 0) > 0 and #Ast.find(lroot, "Unknown") == 0)

-- ---------------------------------------------------------------------------
-- 7. Goto/label corpus (Lua 5.2+)
-- ---------------------------------------------------------------------------
local gotoRoot, gotoErrors = parse([====[
local i = 0
::top::
i = i + 1
if i < 3 then goto top end
do goto done end
::done::
return i
]====])
check("goto: parses without diagnostics", #gotoErrors == 0, gotoErrors[1] and gotoErrors[1].msg)
check("goto: label and goto nodes", #Ast.find(gotoRoot, "Label") == 2 and
  #Ast.find(gotoRoot, "Goto") == 2)
check("goto: contract is sound", #Ast.validate(gotoRoot) == 0)

-- ---------------------------------------------------------------------------
-- 8. Error reporting and recovery
-- ---------------------------------------------------------------------------
local badRoot, badErrors = parse("local a = = 1\nprint(\"survivor\")")
check("errors: reported", #badErrors >= 1)
check("errors: line and column",
  badErrors[1] and badErrors[1].line == 1 and badErrors[1].col == 11,
  badErrors[1] and (badErrors[1].line .. ":" .. badErrors[1].col))
check("errors: message text",
  badErrors[1] and type(badErrors[1].msg) == "string" and #badErrors[1].msg > 0)
local survivor = Ast.find(badRoot, "CallStatement")
check("errors: recovery keeps the next statement", #survivor == 1,
  #survivor .. " call statements")
check("errors: recovered tree still satisfies the contract",
  #Ast.validate(badRoot) == 0)

local _, eofErrors = parse("function f(")
check("errors: eof does not crash", #eofErrors >= 1 and eofErrors[1].line >= 1)

local _, stringErrors = parse("local s = \"unterminated")
check("errors: unterminated string", #stringErrors >= 1 and
  stringErrors[1].line == 1 and
  tostring(stringErrors[1].msg):find("unfinished string") ~= nil,
  stringErrors[1] and stringErrors[1].msg)

local deep = string.rep("(", 300) .. "1" .. string.rep(")", 300)
local _, deepErrors = parse("return " .. deep)
check("errors: nesting guard reports instead of crashing", #deepErrors >= 1,
  #deepErrors .. " errors")

-- ---------------------------------------------------------------------------
-- 9. Validator hardening
-- ---------------------------------------------------------------------------
local fake = {
  type = "Chunk", line = 1, col = 1,
  children = { { type = "Bogus", line = 1, col = 1, children = {} } },
}
local fakeErrors = Ast.validate(fake)
check("validator: unknown node type is rejected", #fakeErrors == 1 and
  tostring(fakeErrors[1]):find("unknown type") ~= nil, fakeErrors[1])

local cyclic = { type = "Chunk", line = 1, col = 1, children = {} }
cyclic.children[1] = cyclic
local cycleErrors = Ast.validate(cyclic)
check("validator: cycles are detected", #cycleErrors >= 1 and
  tostring(cycleErrors[1]):find("cycle") ~= nil, cycleErrors[1])

local text = Ast.toText(sroot)
check("ast: text dump renders types", text:find("FunctionDeclaration") ~= nil and
  text:find("NumericFor") ~= nil)

-- ---------------------------------------------------------------------------
-- 10. Regression: unary expressions in a return list
-- ---------------------------------------------------------------------------
local urRoot, urErrors = parse("return -1, #t, not x")
check("return: unary expressions start a value list",
  #urErrors == 0 and #urRoot.children[1].children == 3,
  urErrors[1] and urErrors[1].msg)

-- ---------------------------------------------------------------------------
-- 11. Regression: the v1 acceptance corpus parses cleanly
-- ---------------------------------------------------------------------------
local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local corpus = { "core.lua", "goto.lua", "bitwise.lua", "luau.lua" }
for i = 1, #corpus do
  local name = corpus[i]
  local src = readFile("../obfuscator/tests/cases/" .. name)
  check("corpus: " .. name .. " readable", src ~= nil)
  if src then
    local croot, cerrors = parse(src)
    check("corpus: " .. name .. " parses clean", #cerrors == 0,
      cerrors[1] and (cerrors[1].line .. ":" .. cerrors[1].col .. " " .. cerrors[1].msg))
    local cv = Ast.validate(croot)
    check("corpus: " .. name .. " contract is sound", #cv == 0, cv[1])
  end
end

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------
print(table.concat(results, "\n"))
local passCount = #results - failures
print(string.format("MODULE1_CHECKS %d/%d", passCount, #results))
print("MODULE1_NODES " .. stats.nodes .. " depth=" .. stats.maxDepth)
if failures == 0 then
  print("MODULE1_RESULT PASS")
else
  print("MODULE1_RESULT FAIL")
end
