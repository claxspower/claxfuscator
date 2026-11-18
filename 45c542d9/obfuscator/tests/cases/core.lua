-- Core feature coverage: must run identically on Lua 5.1, 5.3, 5.4 and Luau.
local unpack = table.unpack or unpack

local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  out[#out + 1] = table.concat(parts, " ")
end

-- arithmetic and comparisons
log("arith", 7 + 3, 7 - 3, 7 * 3, 7 / 2, 7 % 3, 2 ^ 10, -5 + 2)
log("cmp", 1 < 2, 2 <= 2, 3 > 4, "a" < "b", 1 == 1.0, 1 ~= 2)
log("logic", nil and 1, false or "x", not nil, not 0, 0 and "zero")
log("unary", -3, - -3, #"hello", not not true)

-- strings and patterns
local s = "Hello, Lua!"
log("str", #s, s:sub(2, 6), s:upper(), s:lower(), s:reverse())
log("find", s:find("Lua"), s:find("l"), s:find("x"))
log("fmt", string.format("%d|%s|%.2f|%q", 42, "ok", 3.14159, 'a"b'))
log("rep", string.rep("ab", 3), string.char(72, 105), string.byte("A"))
log("concat", "a" .. 1 .. 2)
log("gsub", ("a1b22c"):gsub("(%a)(%d+)", function(a, b) return b .. a end))
log("gsubn", ("xx"):gsub("x", "y"))
log("match", ("key=value"):match("(%w+)=(%w+)"))
local words = {}
for w in ("one two three"):gmatch("%a+") do words[#words + 1] = w end
log("gmatch", table.concat(words, ","))
log("pattern", ("(abc)"):match("%b()"), tostring(("abc123"):match("%d+")))
log("esc", #"a\0b", "line\nbreak" == "line\10break")

-- tables (no array holes: '#' with holes is implementation-defined)
local t = { 10, 20, 30 }
t.x = 1
t.y = 2
log("table", #t, t[1], t[3], t.x, t.y)
t[4] = 40
log("len", #t)
table.insert(t, 99)
log("insert", t[#t])
table.insert(t, 1, 5)
log("insert2", t[1], t[#t])
local removed = table.remove(t)
log("remove", removed, #t)
local kt = { a = 1, b = 2, c = 3 }
local keys = {}
for k in pairs(kt) do keys[#keys + 1] = tostring(k) end
table.sort(keys)
log("keys", table.concat(keys, ","))
local arr = { 5, 2, 9, 1 }
table.sort(arr)
log("sort", table.concat(arr, ","))
table.sort(arr, function(a, b) return a > b end)
log("sortd", table.concat(arr, ","))
log("tconcat", table.concat({ "a", "b", "c" }, "-", 2, 3))

-- multiple assignment and evaluation order
local a, b = 1, 2
a, b = b, a
log("swap", a, b)
local m = {}
local i = 1
m[i], i = 100, 2
log("lvalue", m[1], i)
local p = { 1, 2 }
p[1], p[2] = p[2], p[1]
log("swapidx", p[1], p[2])

-- multi-return and varargs
local function two() return "A", "B" end
local function three() return 1, 2, 3 end
local x, y, z = two()
log("mr", x, y, z)
local x2, y2 = two(), three()
log("mr2", x2, y2)
local q = { two(), "tail" }
log("mrtab", #q, q[1], q[2])
local q2 = { "head", two() }
log("mrtab2", #q2, q2[1], q2[2], q2[3])
log("paren", (three()))
local function pack(...) return select("#", ...), ... end
local function relay(...) return pack(...) end
log("vararg", relay(7, 8, 9))
log("vararg2", pack(nil, nil))
log("vararg3", (pack(1, 2, 3)))

-- closures, upvalues, per-iteration capture
local function counter()
  local n = 0
  return function() n = n + 1; return n end, function() return n end
end
local inc, get = counter()
inc(); inc()
log("closure", inc(), get())
local fns = {}
for k = 1, 3 do fns[k] = function() return k * 10 end end
log("numcapture", fns[1](), fns[2](), fns[3]())
local gfs = {}
for _, v in ipairs({ "a", "b", "c" }) do gfs[#gfs + 1] = function() return v end end
log("gencapture", gfs[1](), gfs[2](), gfs[3]())
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
log("recursion", fact(6))
local isEven, isOdd
isEven = function(n) if n == 0 then return true end return isOdd(n - 1) end
isOdd = function(n) if n == 0 then return false end return isEven(n - 1) end
log("mutual", isEven(10), isOdd(7))

-- shadowing
local shadow = 1
do
  local shadow = shadow + 1
  log("shadow", shadow)
end
log("outer", shadow)

-- methods and metatables
local Vec = {}
Vec.__index = Vec
function Vec.new(x, y)
  return setmetatable({ x = x, y = y }, Vec)
end
function Vec:add(o) return Vec.new(self.x + o.x, self.y + o.y) end
function Vec:__tostring() return "(" .. self.x .. "," .. self.y .. ")" end
function Vec:__add(o) return Vec.new(self.x + o.x, self.y + o.y) end
function Vec:__eq(o) return self.x == o.x and self.y == o.y end
function Vec:__lt(o) return self.x < o.x end
function Vec:__concat(o) return tostring(self) .. "+" .. tostring(o) end
log("method", tostring(Vec.new(1, 2):add(Vec.new(3, 4))))
local v1, v2 = Vec.new(1, 2), Vec.new(1, 2)
log("meta", v1 == v2, Vec.new(1, 1) < Vec.new(2, 0), tostring(v1 .. v2))

local proxy = setmetatable({}, {
  __index = function(_, k) return "idx:" .. k end,
  __newindex = function(tbl, k, v) rawset(tbl, k, v * 2) end,
  __call = function(_, a, b) return a + b end,
  __len = function() return 7 end,
})
proxy.foo = 21
log("proxy", proxy.missing, proxy.foo, proxy(2, 3), #proxy, rawget(proxy, "missing"))

local Base = {}
Base.__index = Base
function Base:name() return "base" end
function Base:value() return self.n or 0 end
local Derived = setmetatable({}, { __index = Base })
Derived.__index = Derived
function Derived.new(n) return setmetatable({ n = n }, Derived) end
function Derived:name() return "derived:" .. Base.name(self) end
log("inherit", Derived.new(5):name(), Derived.new(5):value())

-- control flow
local total = 0
for n = 1, 10 do
  if n % 2 == 0 then total = total + n end
end
log("forif", total)
local desc = {}
for n = 5, 1, -2 do desc[#desc + 1] = n end
log("step", table.concat(desc, ","))
local w = 0
while w < 5 do w = w + 1 end
log("while", w)
local r = 0
repeat
  local step = r + 1
  r = r + step
until step >= 4
log("repeat", r)
local found
for _, v in ipairs({ 3, 4, 5 }) do
  if v == 4 then found = v; break end
end
log("break", found)
local nested = 0
for i2 = 1, 3 do
  for j2 = 1, 3 do
    if j2 == 2 then break end
    nested = nested + 1
  end
end
log("nested", nested)

-- custom generic for
local function range(n)
  local i = 0
  return function()
    i = i + 1
    if i <= n then return i, i * i end
  end
end
local sq = {}
for v, v2 in range(4) do sq[#sq + 1] = v .. ":" .. v2 end
log("iter", table.concat(sq, ","))

-- coroutines
local co = coroutine.create(function(a1, b1)
  local v = a1 + b1
  local x1, y1 = coroutine.yield(v, a1 * b1)
  return "done", x1 + y1
end)
log("co1", coroutine.resume(co, 3, 4))
log("co2", coroutine.resume(co, 10, 20))
log("costatus", coroutine.status(co))
local gen = coroutine.wrap(function()
  for k2 = 1, 3 do coroutine.yield(k2 * k2) end
end)
log("wrap", gen(), gen(), gen())
log("wrapdone", pcall(gen))

-- pcall / error
local ok1, err1 = pcall(function() error("boom", 0) end)
log("pcall", ok1, err1)
local ok2, ra, rb = pcall(function() return "r1", "r2" end)
log("pcall2", ok2, ra, rb)
local ok3, err3 = xpcall(function() error({ code = 9 }, 0) end, function(e)
  return type(e) .. ":" .. tostring(e.code)
end)
log("xpcall", ok3, err3)

-- function type / tostring
log("ftype", type(log), type(Vec.new))
log("select", select("#"), select("#", nil), select(2, "a", "b", "c"))

-- string/number coercion inside the VM
log("coerce", "10" + 5, 10 .. 20, 3 * "4")

do
  local first = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  local second = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefZ"
  local binary = "\000\001\009\010\013\031\032\034\092\126\127\128\200\254\255"
  assert(#first == 64 and #second == 65 and second:sub(1,64) == first)
  local expected = {0,1,9,10,13,31,32,34,92,126,127,128,200,254,255}
  for j=1,#expected do assert(binary:byte(j) == expected[j]) end
  local function values() return nil,false,987654321012345,binary,nil end
  local function verify(...)
    assert(select("#",...) == 5)
    local a,b,c,d,e = ...
    assert(a==nil and b==false and c==987654321012345 and d==binary and e==nil)
  end
  verify(values())
  verify(values())
  log("encrypted", #first, #second, #binary)
end

print(table.concat(out, "|"))
