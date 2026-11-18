-- seal.lua -- at-rest seal for emitted artifacts.
--
--   Seal.wrap(text, seed) -> banner + single-line loader stub
--
-- The raw VM emit is readable Lua, so the delivered file never ships it in
-- the clear: the body is cut into 64 KiB blocks, LZSS-packed, encrypted with
-- a position-dependent stream cipher, base64-encoded over a shuffled 64-symbol
-- alphabet and carried inside one loader chunk. The loader rebuilds the text
-- block by block and hands it to `loadstring`/`load`.
--
-- Layout per block (all little endian, header included in the cipher):
--   bytes 1..4  raw length, high bit 8388608 marks a stored (uncompressed) block
--   bytes 5..8  FNV-1a 32 of the raw block
--   bytes 9..   stored payload (LZSS or raw)
--
-- LZSS: 2048-byte window, 11-bit distance, 4-bit length (3..18), flag bit
-- first, matches MSB-first. Base64 groups: 3 bytes -> 4 symbols, leftovers
-- 1 -> 2 and 2 -> 3; zero bits pad the tail and the decoder ignores them.
--
-- Everything here stays 5.1-compatible (no bitwise operators, no integer
-- division): the module runs inside the browser build VM, the CLI and tests.
local Seal = {}

Seal.BANNER = "--[[ This, File Protected By Claxfuscator V0.2 " ..
  "https://discord.gg/cHawU8Wmzj ]] "

Seal.BLOCK = 65536
-- Hard ceiling for one sealed file. Past this the wrapping is refused rather
-- than shipped in the clear: a "protected" banner over readable Lua is worse
-- than a reported build failure.
Seal.MAX_BYTES = 33554432
-- The poison card ("self copy") only exists so a deobfuscation host prints
-- ciphertext instead of program output. A prefix of the sealed blob carries
-- the full banner + alphabet + first blocks, which is enough to poison the
-- drain, so large artifacts do not have to embed a second complete copy.
Seal.COPY_MAX = 131072

local floor = math.floor
local char = string.char
local byte = string.byte

local function mul32(a, b)
  local a0 = a % 65536
  local a1 = (a - a0) / 65536
  local b0 = b % 65536
  local b1 = (b - b0) / 65536
  return (a0 * b0 + ((a0 * b1 + a1 * b0) % 65536) * 65536) % 4294967296
end

local XOR = {}
do
  local nib = {}
  for a = 0, 15 do
    for b = 0, 15 do
      local z, p, x, y = 0, 1, a, b
      for _ = 1, 4 do
        local xa, yb = x % 2, y % 2
        if xa ~= yb then z = z + p end
        x = (x - xa) / 2
        y = (y - yb) / 2
        p = p * 2
      end
      nib[a * 16 + b] = z
    end
  end
  for a = 0, 255 do
    local al = a % 16
    local ah = (a - al) / 16
    local base = a * 256
    for b = 0, 255 do
      local bl = b % 16
      local bh = (b - bl) / 16
      XOR[base + b] = nib[ah * 16 + bh] * 16 + nib[al * 16 + bl]
    end
  end
end

local function xb(a, b) return XOR[a * 256 + b] end

local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = mul32(h - h % 256 + xb(h % 256, byte(s, i)), 16777619)
  end
  return h
end

local function makeRng(seed)
  local s = floor(tonumber(seed) or 0) % 4294967296
  if s < 0 then s = s + 4294967296 end
  return function(n)
    s = (mul32(s, 1664525) + 1013904223) % 4294967296
    return floor(s / 65536) % n
  end
end

local function defaultSeed()
  local t = (os.time and os.time()) or 0
  local c = (os.clock and os.clock()) or 0
  local r = math.random and floor(math.random() * 4294967296) or 0
  return (mul32(t, 7919) + floor(c * 1000000) + r) % 4294967296
end

-- LZSS ----------------------------------------------------------------------
local function lzPack(src)
  local n = #src
  local out = {}
  local buf, nb = 0, 0
  local function put(v, bits)
    for k = bits - 1, 0, -1 do
      buf = buf * 2 + floor(v / 2 ^ k) % 2
      nb = nb + 1
      if nb == 8 then
        out[#out + 1] = char(buf)
        buf, nb = 0, 0
      end
    end
  end
  local b = {}
  for i = 1, n do b[i] = byte(src, i) end
  local head, prev = {}, {}
  for i = 0, 4095 do head[i] = 0 end
  local i = 1
  while i <= n do
    local bestLen, bestDist = 0, 0
    if i + 2 <= n then
      local h = (b[i] * 65536 + b[i + 1] * 256 + b[i + 2]) % 4096
      local cand = head[h]
      local tries = 0
      while cand > 0 and i - cand <= 2048 and tries < 32 do
        local maxl = 18
        if n - i + 1 < maxl then maxl = n - i + 1 end
        local l = 0
        while l < maxl and b[cand + l] == b[i + l] do l = l + 1 end
        if l >= 3 and l > bestLen then
          bestLen, bestDist = l, i - cand
          if l == maxl and maxl == 18 then break end
        end
        cand = prev[cand % 2048]
        tries = tries + 1
      end
    end
    if bestLen >= 3 then
      put(1, 1)
      put(bestLen - 3, 4)
      put(bestDist - 1, 11)
      local stop = i + bestLen - 1
      local j = i
      while j <= stop do
        if j + 2 <= n then
          local hh = (b[j] * 65536 + b[j + 1] * 256 + b[j + 2]) % 4096
          prev[j % 2048] = head[hh]
          head[hh] = j
        end
        j = j + 1
      end
      i = stop + 1
    else
      put(0, 1)
      put(b[i], 8)
      if i + 2 <= n then
        local hh = (b[i] * 65536 + b[i + 1] * 256 + b[i + 2]) % 4096
        prev[i % 2048] = head[hh]
        head[hh] = i
      end
      i = i + 1
    end
  end
  if nb > 0 then out[#out + 1] = char(buf * 2 ^ (8 - nb)) end
  return table.concat(out)
end

-- Cipher / encoding ---------------------------------------------------------
local function encrypt(bi, plain, keyBytes, mul, tap)
  local out = {}
  local st = (2166136261 + (bi - 1) * 2654435761) % 4294967296
  local prev = 0
  for i = 1, #plain do
    local kk = keyBytes[((i - 1) * mul + (bi - 1) * 8) % 16 + 1]
    st = (st * 1664525 + kk * 131 + i + (bi - 1) * 65537) % 4294967296
    local ks
    if tap == 1 then ks = floor(st / 65536) % 256 else ks = st % 256 end
    local v = xb(xb(xb(byte(plain, i), ks), kk), prev)
    prev = v
    out[i] = v
  end
  return out
end

local function b64(alpha, bytes)
  local n = #bytes
  local out = {}
  local map = {}
  for i = 1, #alpha do map[i] = alpha:sub(i, i) end
  local function sym(v) return map[v + 1] end
  local i = 1
  while i + 2 <= n do
    local v = bytes[i] * 65536 + bytes[i + 1] * 256 + bytes[i + 2]
    out[#out + 1] = sym(floor(v / 262144) % 64) ..
      sym(floor(v / 4096) % 64) .. sym(floor(v / 64) % 64) .. sym(v % 64)
    i = i + 3
  end
  local left = n - i + 1
  if left == 1 then
    local v = bytes[i]
    out[#out + 1] = sym(floor(v / 4) % 64) .. sym((v % 4) * 16)
  elseif left == 2 then
    local v = bytes[i] * 256 + bytes[i + 1]
    out[#out + 1] = sym(floor(v / 1024) % 64) .. sym(floor(v / 16) % 64) ..
      sym((v % 16) * 4)
  end
  return table.concat(out)
end

-- Loader stub ---------------------------------------------------------------
local STUB = [=[
local S=string local C=table local F=math.floor
local U=C.unpack if type(U)~="function" then U=unpack end
local function M32(a,b)local a0=a%65536 local a1=(a-a0)/65536 local b0=b%65536 local b1=(b-b0)/65536 return (a0*b0+((a0*b1+a1*b0)%65536)*65536)%4294967296 end
local NB={} for a=0,15 do for b=0,15 do local z,p,x,y=0,1,a,b for q=1,4 do local xa=x%2 local yb=y%2 if xa~=yb then z=z+p end x=(x-xa)/2 y=(y-yb)/2 p=p*2 end NB[a*16+b]=z end end
local X={} for a=0,255 do local al=a%16 local ah=(a-al)/16 local bb=a*256 for b=0,255 do local bl=b%16 local bh=(b-bl)/16 X[bb+b]=NB[ah*16+bh]*16+NB[al*16+bl] end end
local function xb(a,b)return X[a*256+b] end
local function H(t,n)local h=2166136261 for i=1,n do h=M32(h-h%256+xb(h%256,t[i]),16777619) end return h end
local MB={} for i=1,#A do MB[S.sub(A,i,i)]=i-1 end
local function B(s)local o,acc,nb,k={},0,0,0 for i=1,#s do local v=MB[S.sub(s,i,i)] or 0 acc=acc*64+v nb=nb+6 while nb>=8 do nb=nb-8 local pw=2^nb k=k+1 o[k]=F(acc/pw) acc=acc%pw end end return o end
local function LZ(t,p,n)
local o,on={},0
local function g(bn)local v=0 for k=1,bn do local bi=F(p/8)+1 if bi>#t then return nil end local sh=7-(p%8) v=v*2+F(t[bi]/2^sh)%2 p=p+1 end return v end
while on<n do
local f=g(1) if f==nil then return nil end
if f==1 then
local ln=g(4) local ds=g(11) if ln==nil or ds==nil then return nil end
ln=ln+3 ds=ds+1 if ds>on then return nil end
for k=1,ln do if on>=n then break end on=on+1 o[on]=o[on-ds] end
else
local v=g(8) if v==nil then return nil end on=on+1 o[on]=v
end
end
return o
end
local OUT={}
for bi=1,#G do
local t=B(G[bi]) local st=(2166136261+(bi-1)*2654435761)%4294967296 local pv=0
for i=1,#t do
local kk=S.byte(K,((i-1)*M+(bi-1)*8)%16+1)
st=(st*1664525+kk*131+i+(bi-1)*65537)%4294967296
local ks if T==1 then ks=F(st/65536)%256 else ks=st%256 end
local q=t[i] t[i]=xb(xb(xb(q,pv),ks),kk) pv=q
end
local n=t[1]+t[2]*256+t[3]*65536+t[4]*16777216
local raw=false if n>=8388608 then raw=true n=n-8388608 end
local ck=t[5]+t[6]*256+t[7]*65536+t[8]*16777216
local body
if raw then body={} for i=9,#t do body[i-8]=t[i] end else body=LZ(t,64,n) end
if not body or #body~=n or H(body,n)~=ck then local z={} z[1]() end
local parts,j={},0
while j<n do
local m=n-j if m>200 then m=200 end
local w={} for q=1,m do w[q]=body[j+q] end
parts[#parts+1]=S.char(U(w,1,m)) j=j+m
end
OUT[#OUT+1]=C.concat(parts)
end
local Z=C.concat(OUT)
local E
local function has(t)return type(t)=="table" and (type(t["loadstring"])=="function" or type(t["load"])=="function") end
if type(getfenv)=="function" then local function g0()return getfenv(1)end local o,v=pcall(g0) if o and has(v) then E=v end end
if E==nil and type(getgenv)=="function" then local o,v=pcall(getgenv) if o and has(v) then E=v end end
if E==nil and has(_ENV) then E=_ENV end
if E==nil and has(_G) then E=_G end
if E==nil then local z={} z[1]() end
local R=E
local okr,t=pcall(setmetatable,{},{__index=E})
if okr and type(t)=="table" then R=t end
local ls=E["loadstring"] local ld=E["load"]
local L0 if type(ls)=="function" then L0=ls else L0=ld end
if type(L0)~="function" then local z={} z[1]() end
if type(E["typeof"])~="function" then
local hz=false
pcall(function() local dbg=E["debug"] if type(dbg)~="table" or type(dbg["getinfo"])~="function" then return end local oi,di=pcall(dbg["getinfo"],L0,"S") if not oi or type(di)~="table" or di["what"]~="Lua" then return end hz=true local w=E["warn"] if type(w)~="function" then w=E["print"] end if type(w)=="function" then w(C.concat(G,"")) end end)
if hz then return end
end
local f
if type(ls)=="function" then f=ls(Z) else f=ld(Z,"s","t",R) end
if f==nil then local z={} z[1]() end
if type(setfenv)=="function" then pcall(setfenv,f,R) end
return f(...)
end)(...)
]=]
STUB = STUB:gsub("%s*\n%s*", " ")

local function makeAlphabet(rng)
  local codes = {}
  for c = 33, 126 do
    if c ~= 34 and c ~= 92 and c ~= 93 then codes[#codes + 1] = c end
  end
  for i = #codes, 2, -1 do
    local j = rng(i) + 1
    codes[i], codes[j] = codes[j], codes[i]
  end
  local out = {}
  for i = 1, 64 do out[i] = char(codes[i]) end
  return table.concat(out), codes
end

function Seal.isWrapped(text)
  return type(text) == "string" and
    text:sub(1, #Seal.BANNER) == Seal.BANNER and
    text:find("local G={[==[", 1, true) ~= nil
end

function Seal.wrap(text, seed, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then return text end
  if text:sub(1, #Seal.BANNER) == Seal.BANNER then
    text = text:sub(#Seal.BANNER + 1)
  end
  if #text > (opts.maxBytes or Seal.MAX_BYTES) then
    return nil, "artifact is " .. #text .. " bytes; the seal limit is " ..
      (opts.maxBytes or Seal.MAX_BYTES)
  end
  local rng = makeRng(seed or defaultSeed())
  local alpha, codes = makeAlphabet(rng)
  local keyParts = {}
  local keyBytes = {}
  for i = 1, 16 do
    local c = codes[rng(#codes) + 1]
    keyParts[i] = char(c)
    keyBytes[i] = c
  end
  local key = table.concat(keyParts)
  local mul = 1 + rng(15)
  local tap = rng(2)

  local block = opts.blockSize or Seal.BLOCK
  local blobs = {}
  local bi = 0
  local pos = 1
  while pos <= #text do
    bi = bi + 1
    local stop = pos + block - 1
    if stop > #text then stop = #text end
    local raw = text:sub(pos, stop)
    pos = stop + 1
    local packed = lzPack(raw)
    local rawLen = #raw
    local store, flag
    if packed and #packed < rawLen then
      store, flag = packed, rawLen
    else
      store, flag = raw, rawLen + 8388608
    end
    local sum = fnv1a(raw)
    local plain = {
      char(flag % 256, floor(flag / 256) % 256, floor(flag / 65536) % 256,
        floor(flag / 16777216) % 256,
        sum % 256, floor(sum / 256) % 256, floor(sum / 65536) % 256,
        floor(sum / 16777216) % 256),
    }
    plain = plain[1] .. store
    local cipher = encrypt(bi, plain, keyBytes, mul, tap)
    blobs[bi] = b64(alpha, cipher)
  end

  local parts = {}
  parts[#parts + 1] = "return(function(...)local A=\""
  parts[#parts + 1] = alpha
  parts[#parts + 1] = "\" local K=\""
  -- The key never sits in the source as one contiguous 16-character string:
  -- it is cut at random points and rebuilt by concatenation at load, so a
  -- static scan has to fold string joins before it sees the key material.
  local c1 = 4 + rng(9)
  if c1 >= #key - 1 then c1 = #key - 3 end
  local c2 = c1 + 2 + rng(9)
  if c2 >= #key then c2 = #key - 1 end
  parts[#parts + 1] = key:sub(1, c1)
  parts[#parts + 1] = "\"..\""
  parts[#parts + 1] = key:sub(c1 + 1, c2)
  parts[#parts + 1] = "\"..\""
  parts[#parts + 1] = key:sub(c2 + 1)
  parts[#parts + 1] = "\" local M="
  parts[#parts + 1] = tostring(mul)
  parts[#parts + 1] = " local T="
  parts[#parts + 1] = tostring(tap)
  parts[#parts + 1] = " local G={"
  for i = 1, #blobs do
    parts[#parts + 1] = (i > 1 and "," or "") .. "[==[" .. blobs[i] .. "]==]"
  end
  parts[#parts + 1] = "}" .. STUB
  return Seal.BANNER .. table.concat(parts)
end

return Seal
