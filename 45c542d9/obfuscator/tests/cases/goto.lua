-- goto/label coverage (Lua 5.2+; Luau has no goto).
local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  out[#out + 1] = table.concat(parts, " ")
end

local i = 0
::top::
i = i + 1
if i < 5 then goto top end
log("loop", i)

for a = 1, 3 do
  for b = 1, 3 do
    if b == 2 then goto continue end
    log("pair", a, b)
  end
  ::continue::
end

do
  goto skip
  log("never")
  ::skip::
  log("skip")
end

local state = 0
::again::
state = state + 2
if state < 8 then
  do
    local marker = state
    if marker == 4 then goto again end
  end
  goto again
end
log("state", state)

print(table.concat(out, "|"))
