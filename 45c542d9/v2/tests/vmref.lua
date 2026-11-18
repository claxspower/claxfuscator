-- vmref.lua -- test-only reference interpreter for the layer 7 register ISA.
--
-- This is deliberately *not* the shipped runtime: M8 generates the O(1)
-- handler table and the encrypted payload lives in M9/M10. The interpreter
-- exists so the acceptance test can prove that compiled bytecode preserves the
-- source semantics on every host, including Lua 5.1 (no goto, no bitwise
-- operators, no integer division).
--
-- Bit operations use the same portable 53-bit arithmetic contract as the
-- generated runtime: values are reduced modulo 2^53 and results are exact
-- non-negative doubles. `BNOT` matches Lua's `-x-1`.
local VM = {}

VM.implemented = {}

local unpackValues = table.unpack or unpack
local floor = math.floor
local MOD53 = 9007199254740992

local function pack(...)
  return { n = select("#", ...), ... }
end

local function truthy(v)
  return v ~= nil and v ~= false
end

local function bw(x, y, mode)
  x = floor(x) % MOD53
  y = floor(y) % MOD53
  local r, pw = 0, 1
  for _ = 1, 53 do
    local xa = x % 2
    local xb = y % 2
    local z
    if mode == 1 then z = (xa == 1 and xb == 1) and 1 or 0
    elseif mode == 2 then z = (xa == 1 or xb == 1) and 1 or 0
    else z = (xa ~= xb) and 1 or 0 end
    r = r + z * pw
    x = (x - xa) / 2
    y = (y - xb) / 2
    pw = pw * 2
  end
  return r
end

local function bnot(x)
  return -floor(x) - 1
end

local function shift(x, y, left)
  x = floor(x)
  y = floor(y)
  if y < 0 then return shift(x, -y, not left) end
  if y >= 53 then return 0 end
  if left then
    for _ = 1, y do x = x * 2 end
    return x
  end
  for _ = 1, y do x = floor(x / 2) end
  return x
end

local HANDLED = {
  MOVE = true, LOADK = true, LOADNIL = true, LOADBOOL = true, LOADINT = true,
  LOADNILN = true, GETUPVAL = true, SETUPVAL = true, NEWCELL = true,
  GETCELL = true, SETCELL = true, GETGLOBAL = true, SETGLOBAL = true,
  NEWTABLE = true, GETTABLE = true, SETTABLE = true, GETFIELD = true,
  SETFIELD = true, SELF = true, SETLIST = true, GETIDXI = true,
  SETIDXI = true, ADD = true, SUB = true, MUL = true, DIV = true, MOD = true,
  POW = true, IDIV = true, UNM = true, CONCAT = true, BAND = true,
  BOR = true, BXOR = true, BNOT = true, SHL = true, SHR = true, LEN = true,
  NOT = true, BOOL = true, EQ = true, NE = true, LT = true, LE = true,
  GT = true, GE = true, TEST = true, TESTSET = true, TESTNIL = true,
  JMP = true, JMPF = true, JMPT = true, FORPREP = true, FORLOOP = true,
  TFORCALL = true, TFORLOOP = true, CLOSE = true, NOP = true, SETTOP = true,
  CALL = true, TAILCALL = true, RETURN = true, CLOSURE = true, VARARG = true,
  ADDK = true, SUBK = true, MULK = true, DIVK = true, MODK = true,
  POWK = true, IDIVK = true, ADDI = true, SUBI = true, MULI = true,
  DIVI = true, MODI = true, EQK = true, NEK = true, LTK = true, LEK = true,
}
VM.implemented = HANDLED

function VM.run(compiled, env, ...)
  local protos = compiled.protos
  if type(protos) ~= "table" or not protos[1] then
    error("vmref: no prototypes", 2)
  end
  env = env or _G

  local exec
  exec = function(pi, upvals, nargs, ...)
    local P = protos[pi]
    local code = P.code
    local K = P.k
    local U = upvals or {}
    local R = {}
    local nparams = P.params or 0
    local args = pack(...)
    for i = 1, nparams do R[i] = args[i] end

    local varargs = {}
    local nvar = 0
    if P.vararg and nargs > nparams then
      for i = nparams + 1, nargs do
        nvar = nvar + 1
        varargs[nvar] = args[i]
      end
    end

    local top = nparams + 1
    local pc = 1

    while true do
      local I = code[pc]
      if not I then error("vmref: pc out of range", 0) end
      local op = I.op
      local a, b, c, d = I.a, I.b, I.c, I.d
      local npc = pc + 1

      if op == "MOVE" then
        R[a] = R[b]
      elseif op == "LOADK" then
        R[a] = K[d]
      elseif op == "LOADNIL" then
        R[a] = nil
      elseif op == "LOADBOOL" then
        R[a] = (b ~= 0)
      elseif op == "LOADINT" then
        R[a] = d
      elseif op == "LOADNILN" then
        for i = 0, d - 1 do R[a + i] = nil end
      elseif op == "GETUPVAL" then
        R[a] = U[b][1]
      elseif op == "SETUPVAL" then
        U[b][1] = R[a]
      elseif op == "NEWCELL" then
        if b == 0 then R[a] = {}
        else R[a] = { R[b] } end
      elseif op == "GETCELL" then
        R[a] = R[b][1]
      elseif op == "SETCELL" then
        R[a][1] = R[b]
      elseif op == "GETGLOBAL" then
        R[a] = env[K[d]]
      elseif op == "SETGLOBAL" then
        env[K[d]] = R[a]
      elseif op == "NEWTABLE" then
        R[a] = {}
      elseif op == "GETTABLE" then
        R[a] = R[b][R[c]]
      elseif op == "SETTABLE" then
        R[a][R[b]] = R[c]
      elseif op == "GETFIELD" then
        R[a] = R[b][K[d]]
      elseif op == "SETFIELD" then
        R[a][K[d]] = R[b]
      elseif op == "SELF" then
        local obj = R[b]
        R[a + 1] = obj
        R[a] = obj[K[d]]
      elseif op == "SETLIST" then
        local tab = R[a]
        local count
        if d < 0 then
          count = top - c
          top = c
        else
          count = d
        end
        for i = 0, count - 1 do tab[b + i] = R[c + i] end
      elseif op == "GETIDXI" then
        R[a] = R[b][d]
      elseif op == "SETIDXI" then
        R[a][d] = R[b]
      elseif op == "ADD" then R[a] = R[b] + R[c]
      elseif op == "SUB" then R[a] = R[b] - R[c]
      elseif op == "MUL" then R[a] = R[b] * R[c]
      elseif op == "DIV" then R[a] = R[b] / R[c]
      elseif op == "MOD" then R[a] = R[b] % R[c]
      elseif op == "POW" then R[a] = R[b] ^ R[c]
      elseif op == "IDIV" then R[a] = floor(R[b] / R[c])
      elseif op == "UNM" then R[a] = -R[b]
      elseif op == "CONCAT" then R[a] = R[b] .. R[c]
      elseif op == "BAND" then R[a] = bw(R[b], R[c], 1)
      elseif op == "BOR" then R[a] = bw(R[b], R[c], 2)
      elseif op == "BXOR" then R[a] = bw(R[b], R[c], 3)
      elseif op == "BNOT" then R[a] = bnot(R[b])
      elseif op == "SHL" then R[a] = shift(R[b], R[c], true)
      elseif op == "SHR" then R[a] = shift(R[b], R[c], false)
      elseif op == "LEN" then R[a] = #R[b]
      elseif op == "NOT" then R[a] = not R[b]
      elseif op == "BOOL" then
        local v = truthy(R[b])
        if c ~= 0 then v = not v end
        R[a] = v
      elseif op == "EQ" then R[a] = (R[b] == R[c])
      elseif op == "NE" then R[a] = (R[b] ~= R[c])
      elseif op == "LT" then R[a] = (R[b] < R[c])
      elseif op == "LE" then R[a] = (R[b] <= R[c])
      elseif op == "GT" then R[a] = (R[b] > R[c])
      elseif op == "GE" then R[a] = (R[b] >= R[c])
      elseif op == "ADDK" then R[a] = R[b] + K[d]
      elseif op == "SUBK" then R[a] = R[b] - K[d]
      elseif op == "MULK" then R[a] = R[b] * K[d]
      elseif op == "DIVK" then R[a] = R[b] / K[d]
      elseif op == "MODK" then R[a] = R[b] % K[d]
      elseif op == "POWK" then R[a] = R[b] ^ K[d]
      elseif op == "IDIVK" then R[a] = floor(R[b] / K[d])
      elseif op == "ADDI" then R[a] = R[b] + d
      elseif op == "SUBI" then R[a] = R[b] - d
      elseif op == "MULI" then R[a] = R[b] * d
      elseif op == "DIVI" then R[a] = R[b] / d
      elseif op == "MODI" then R[a] = R[b] % d
      elseif op == "EQK" then R[a] = (R[b] == K[d])
      elseif op == "NEK" then R[a] = (R[b] ~= K[d])
      elseif op == "LTK" then R[a] = (R[b] < K[d])
      elseif op == "LEK" then R[a] = (R[b] <= K[d])
      elseif op == "TEST" then
        if truthy(R[b]) == (a ~= 0) then npc = pc + 2 end
      elseif op == "TESTSET" then
        if truthy(R[b]) == (a ~= 0) then
          R[c] = R[b]
          npc = pc + 2
        end
      elseif op == "TESTNIL" then
        if R[b] == nil then npc = pc + 2 end
      elseif op == "JMP" then
        npc = pc + 1 + d
      elseif op == "JMPF" then
        if not truthy(R[a]) then npc = pc + 1 + d end
      elseif op == "JMPT" then
        if truthy(R[a]) then npc = pc + 1 + d end
      elseif op == "FORPREP" then
        R[a] = R[a] - R[a + 2]
        npc = pc + 1 + d
      elseif op == "FORLOOP" then
        local step = R[a + 2]
        if step == 0 then error("'for' step is zero", 0) end
        R[a] = R[a] + step
        R[a + 3] = R[a]
        local limit = R[a + 1]
        if (step > 0 and R[a] <= limit) or (step < 0 and R[a] >= limit) then
          npc = pc + 1 + d
        end
      elseif op == "TFORCALL" then
        local res = pack(R[a](R[a + 1], R[a + 2]))
        for i = 1, b do R[a + 3 + i - 1] = res[i] end
        top = a + 3 + b
      elseif op == "TFORLOOP" then
        if R[a + 3] ~= nil then
          R[a + 2] = R[a + 3]
          npc = pc + 1 + d
        end
      elseif op == "CLOSE" then
        -- cells own their storage; nothing to close
      elseif op == "NOP" then
        -- no operation
      elseif op == "SETTOP" then
        top = a
      elseif op == "CALL" then
        local count = (b < 0) and (top - (a + 1)) or b
        local fn = R[a]
        local callArgs = {}
        for i = 1, count do callArgs[i] = R[a + i] end
        local res = pack(fn(unpackValues(callArgs, 1, count)))
        if c < 0 then
          local dest = (d > 0) and d or a
          for i = 1, res.n do R[dest + i - 1] = res[i] end
          top = dest + res.n
        elseif c > 0 then
          local dest = (d > 0) and d or a
          for i = 1, c do R[dest + i - 1] = res[i] end
        end
      elseif op == "TAILCALL" then
        local count = (b < 0) and (top - (a + 1)) or b
        local fn = R[a]
        local callArgs = {}
        for i = 1, count do callArgs[i] = R[a + i] end
        local res = pack(fn(unpackValues(callArgs, 1, count)))
        return unpackValues(res, 1, res.n)
      elseif op == "RETURN" then
        local count = (b < 0) and (top - a) or b
        if count <= 0 then return end
        return unpackValues(R, a, a + count - 1)
      elseif op == "CLOSURE" then
        local childProto = protos[b]
        local childUpvals = {}
        local desc = childProto.updesc or {}
        for i = 1, #desc do
          if desc[i][1] == 1 then
            childUpvals[i] = R[desc[i][2]]
          else
            childUpvals[i] = U[desc[i][2]]
          end
        end
        local childIndex = b
        R[a] = function(...)
          return exec(childIndex, childUpvals, select("#", ...), ...)
        end
      elseif op == "VARARG" then
        if b < 0 then
          for i = 1, nvar do R[a + i - 1] = varargs[i] end
          top = a + nvar
        else
          for i = 1, b do R[a + i - 1] = varargs[i] end
        end
      else
        error("vmref: unknown opcode '" .. tostring(op) .. "'", 0)
      end

      pc = npc
    end
  end

  return exec(1, {}, select("#", ...), ...)
end

return VM
