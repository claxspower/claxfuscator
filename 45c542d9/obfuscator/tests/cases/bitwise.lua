-- bitwise operators and integer division (Lua 5.3+; Luau has no bitwise ops).
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  print(table.concat(parts, " "))
end

show(5 & 3, 5 | 3, 5 ~ 3, ~5)
show(1 << 4, 256 >> 4, 0x7fffffff >> 3)
show(-7 // 2, 7 // -2, 2 ^ 10)
show(12.0 & 10, 3 | 4.0)
show(1 << 40, (1 << 40) >> 20, 123456789 & 0xffff)

local mask = 0xFF00
local v = 0x1234
show((v & mask) >> 8, (v | 0x00FF) ~ 0x0F0F)
