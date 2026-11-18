-- Luau-only syntax coverage.
type Pair = { a: number, b: number }
type Mapper<T> = (T) -> T

local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  out[#out + 1] = table.concat(parts, " ")
end

local function add(a: number, b: number): number
  return a + b
end
log("types", add(2, 3))

local sum: number = 0
for i = 1, 10 do
  if i % 2 == 0 then continue end
  sum += i
end
log("continue", sum)

local total = 0
local i = 0
while i < 6 do
  i += 1
  if i == 3 then continue end
  total += i
end
log("while", total)

local nested = {}
for a = 1, 3 do
  for b = 1, 3 do
    if b == 2 then continue end
    nested[#nested + 1] = a .. ":" .. b
  end
end
log("nested", table.concat(nested, ","))

local name = "Lua"
local version: number = 5
log("interp", `hello {name} {version + 1} {"!"}`)

local choice = if sum > 20 then "big" elseif sum > 10 then "medium" else "small"
log("ifexpr", choice)

local asserted = (5 :: number) * 2
log("assert", asserted)

local identity = function<T>(v: T): T
  return v
end
log("generic", identity(7), identity("x"))

local pair: Pair = { a = 1, b = 2 }
pair.a += 10
pair.b *= 3
log("pair", pair.a, pair.b)

local arr = { 1, 2, 3 }
arr[1] += 100
local idx = 2
arr[idx] -= 1
log("index", arr[1], arr[2], arr[3])

local obj = { value = 5 }
local function getObj(): Pair
  return obj :: any
end
getObj().value += 3
log("once", obj.value)

local calls = 0
local function bump(): number
  calls += 1
  return 1
end
local box = { n = 10 }
box.n += bump()
box.n += bump()
log("side", box.n, calls)

local co = coroutine.wrap(function()
  coroutine.yield(`y{1}`)
  coroutine.yield(`y{2}`)
  return `end`
end)
log("co", co(), co(), co())

print(table.concat(out, "|"))
