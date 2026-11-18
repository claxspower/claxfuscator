-- parse_smoke.lua -- internal parser sanity checks (not part of the emitted output).
package.path = "./?.lua;./src/?.lua;" .. package.path
local Parser = require("src.parser")

local samples = {
  {
    name = "lua-core",
    src = [[
local t = {1, 2, x = 3, ["y"] = 4}
local function add(a, b) return a + b end
for i = 1, 10 do t[i] = add(i, 2) end
for k, v in pairs(t) do print(k, v) end
if t.x then while false do break end elseif 1 < 2 then
  repeat t.n = (t.n or 0) + 1 until t.n > 2
else end
print(("hi"):upper(), #t, 2 ^ 3, 7 // 2, 5 & 3, 1 << 4, ~5)
function obj:method(x) return x * 2 end
local f = function(...) return select("#", ...) end
goto skip
::skip::
do local a <const> = 1 end
return add(1, 2)
]],
  },
  {
    name = "luau",
    src = [[
local x: number = 5
local function f<T>(a: T): T return a end
x += 1
for i = 1, 3 do
  if i == 2 then continue end
  print(i)
end
local s = `a{x}b`
type Foo = {x: number, y: (number) -> string}
local v = if x > 3 then "big" else "small"
local o = {m = function(self) return self end}
print(s, v, f(x), o:m())
]],
  },
}

local failed = 0
for _, sample in ipairs(samples) do
  local ast, errors = Parser.parse(sample.src, sample.name)
  if #errors > 0 then
    failed = failed + 1
    print("FAIL " .. sample.name .. " (" .. #errors .. " errors)")
    for i = 1, #errors do
      print(string.format("  %d:%d %s", errors[i].line, errors[i].col, errors[i].msg))
    end
  else
    print("OK   " .. sample.name .. " statements=" .. #ast.block)
  end
end
os.exit(failed == 0 and 0 or 1)
