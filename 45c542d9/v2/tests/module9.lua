-- module9.lua -- acceptance tests for layer 9 (packed, encrypted bytecode).
--
-- Pipeline under test: layers 1-8 produce a randomized instruction plan, then
-- src/bytecode.lua serializes the prototypes into one varint stream, encrypts
-- it with ChaCha20 in counter mode (64-byte blocks, key and nonce derived from
-- the build key and header lengths) and prefixes a 16-byte header (FNV-1a
-- ciphertext checksum, plaintext length, key tag, version, magic), then appends
-- an 8-byte keyed SipHash-2-4 tag over the exact header and ciphertext.
-- src/vmgen.lua emits a runtime that verifies the header and decodes
-- the payload at load time; no instruction word, constant or prototype header
-- appears as text in the shipped file.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Consts = require("src.consts")
local Flatten = require("src.flatten")
local Opaque = require("src.opaque")
local Strings = require("src.strings")
local Compiler = require("src.compiler")
local VM = require("tests.vmref")
local VMGen = require("src.vmgen")
local Bytecode = require("src.bytecode")

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

local function build(src, opts)
  opts = opts or {}
  local ast, errors = parse(src)
  if not ast then return nil, errors end
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  if not opts.raw then
    Consts.run(ast, { seed = 0x0C057A })
    Flatten.run(ast, { seed = 3 })
    Opaque.run(ast, { seed = 5, prob = 0.6 })
    Strings.run(ast, { seed = 0x5CE41D })
  end
  local compiled = Compiler.compile(ast, {})
  return compiled, errors
end

-- ---------------------------------------------------------------- execution
local loadChunk = loadstring or load

local function makeEnv(out)
  local env = setmetatable({}, { __index = _G })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  return env
end

local function execute(src)
  local out = {}
  local env = makeEnv(out)
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

local function runGenerated(src)
  local out = {}
  local env = makeEnv(out)
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(src, "@vm")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@vm", "t", env)
  end
  if not chunk then return nil, tostring(err) end
  local ok, runErr = pcall(chunk)
  if not ok then return nil, tostring(runErr) end
  return table.concat(out, "\n")
end

local function loadGenerated(src)
  local env = makeEnv({})
  local chunk
  if setfenv then
    chunk = loadChunk(src, "@vm")
    if chunk then setfenv(chunk, env) end
  else
    chunk = load(src, "@vm", "t", env)
  end
  return chunk
end

-- ---------------------------------------------------------------- utilities
local function flipByte(s, pos)
  local b = string.byte(s, pos)
  if not b then return s end
  return s:sub(1, pos - 1) .. string.char((b + 1) % 256) .. s:sub(pos + 1)
end

local function hex32(n)
  return string.format("%08x", n % 4294967296)
end

local function sameValue(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then
    if a ~= a or b ~= b then return a ~= a and b ~= b end
    if a == 0 and b == 0 then return 1 / a == 1 / b end
    if a ~= b then return false end
    if math.type then return math.type(a) == math.type(b) end
    return true
  end
  return a == b
end

local function compareProtos(want, got)
  if #want ~= #got then
    return false, "proto count " .. #got .. " ~= " .. #want
  end
  for pi = 1, #want do
    local W, G = want[pi], got[pi]
    if (W.a or 0) ~= (G.a or 0) then return false, "proto " .. pi .. " params" end
    if not not W.v ~= not not G.v then return false, "proto " .. pi .. " vararg" end
    if #W.c ~= #G.c then return false, "proto " .. pi .. " code size" end
    for i = 1, #W.c do
      local x, y = W.c[i], G.c[i]
      for f = 1, 5 do
        if not sameValue(x[f], y[f]) then
          return false, "proto " .. pi .. " ins " .. i .. " field " .. f
        end
      end
    end
    if #W.k ~= #G.k then return false, "proto " .. pi .. " const count" end
    for i = 1, #W.k do
      if not sameValue(W.k[i], G.k[i]) then
        return false, "proto " .. pi .. " const " .. i .. " " ..
          tostring(W.k[i]) .. " ~= " .. tostring(G.k[i])
      end
    end
    if #W.u ~= #G.u then return false, "proto " .. pi .. " updesc count" end
    for i = 1, #W.u do
      if W.u[i][1] ~= G.u[i][1] or W.u[i][2] ~= G.u[i][2] then
        return false, "proto " .. pi .. " updesc " .. i
      end
    end
  end
  return true
end

local function countConsts(plan)
  local n = 0
  for pi = 1, #plan.protos do n = n + #plan.protos[pi].k end
  return n
end

local function countInstr(plan)
  local n = 0
  for pi = 1, #plan.protos do n = n + #plan.protos[pi].c end
  return n
end

-- ---------------------------------------------------------------------------
-- 1. Container format: header, lengths, checksum and key tag
-- ---------------------------------------------------------------------------
local SAMPLE = [[
local function add(a, b) return a + b end
local function rep(s, n) return s:rep(n) end
print(add(2, 3), rep("ab", 2), "tail")
]]

local sampleCompiled = build(SAMPLE)
local samplePlan = VMGen.randomize(sampleCompiled,
  { seed = 0x9A11, decoys = 160 })
local samplePayload = Bytecode.pack(samplePlan, { seed = 0x9A11 })

check("container: blob is a string",
  type(samplePayload.blob) == "string" and #samplePayload.blob > 16)
check("container: blob = 16 header + cipher body + 8 tag",
  #samplePayload.blob == 24 + samplePayload.cipherBytes)
check("container: cipher body is 64-byte aligned",
  samplePayload.cipherBytes % 64 == 0 and
  samplePayload.cipherBytes >= samplePayload.plainBytes,
  samplePayload.cipherBytes)
check("container: plaintext survives padding",
  samplePayload.plainBytes <= samplePayload.cipherBytes and
  samplePayload.plainBytes > 0)
check("container: version byte in range", samplePayload.version < 256)
check("container: key in 32-bit range",
  samplePayload.key >= 0 and samplePayload.key < 4294967296)

local hdr = Bytecode.parseHeader(samplePayload.blob)
check("header: parses", hdr ~= nil)
if hdr then
  check("header: plaintext length", hdr.plainLength == samplePayload.plainBytes,
    hdr.plainLength .. " ~= " .. samplePayload.plainBytes)
  check("header: version byte derived", hdr.version ==
    Bytecode.magicOf(samplePayload.keyTag)[1], hdr.version)
  local em = Bytecode.magicOf(samplePayload.keyTag)
  check("header: signature is per-build", hdr.magic[1] == em[2] and
    hdr.magic[2] == em[3] and hdr.magic[3] == em[4] and
    not (hdr.magic[1] == 67 and hdr.magic[2] == 76 and hdr.magic[3] == 57))
  check("header: checksum covers body",
    hdr.checksum == Bytecode._internals.fnv1a(hdr.body))
  check("header: checksum matches pack",
    hdr.checksum == samplePayload.checksum)
  check("header: key tag matches pack", hdr.keyTag == samplePayload.keyTag)
  check("header: key tag covers key bytes",
    hdr.keyTag == Bytecode._internals.tagOf(samplePayload.key))
  check("header: key tag is not the FNV mirror",
    hdr.keyTag ~= Bytecode._internals.fnv1a(
      Bytecode._internals.le32(samplePayload.key)))
  check("header: body length",
    #hdr.body == samplePayload.cipherBytes)
end
check("header: truncated input rejected",
  Bytecode.parseHeader(string.sub(samplePayload.blob, 1, 10)) == nil)
check("header: non-string rejected", Bytecode.parseHeader({}) == nil)

-- SipHash-2-4 is checked against the published vectors: key 00..0f, message
-- 00..n-1, folded to the low^high 32 bits of the 64-bit digest.
local sipVectors = {
  { 0, 0xaf61d576 }, { 1, 0xe7245e38 }, { 2, 0xd4c5cf53 },
  { 3, 0x529c18bb }, { 4, 0xe8561357 }, { 5, 0xd5eff3e9 },
  { 8, 0x0966d11b }, { 15, 0xe8978f84 }, { 63, 0x7e8c773e },
}
for _, case in ipairs(sipVectors) do
  local chars = {}
  for i = 1, case[1] do chars[i] = string.char(i - 1) end
  check("siphash: vector n=" .. case[1],
    Bytecode._internals.sipRaw(table.concat(chars), 0x07060504, 0x03020100,
      0x0f0e0d0c, 0x0b0a0908) == case[2])
end
check("siphash: tail length byte",
  Bytecode._internals.sipRaw(" ", 0x07060504, 0x03020100,
    0x0f0e0d0c, 0x0b0a0908) ~=
  Bytecode._internals.sipRaw("  ", 0x07060504, 0x03020100,
    0x0f0e0d0c, 0x0b0a0908))
check("siphash: tag is keyed",
  Bytecode._internals.tagOf(1) ~= Bytecode._internals.tagOf(2) and
  Bytecode._internals.tagOf(0xFFFFFFF) ~= Bytecode._internals.tagOf(0xFFFFFFE))

-- ---------------------------------------------------------------------------
-- 2. Round trip: every field, constant tag and subtype survives pack/unpack
-- ---------------------------------------------------------------------------
local NAN = 0 / 0
local fakePlan = {
  protos = {
    {
      a = 3, v = true,
      c = {
        { 7, 1, 2, 3, 0 },
        { 9, 2, -3, 4, 1.0 },
        { 11, 0, 0, 0, -0.0 },
        { 12, 5, 6, -7, -42 },
        { 13, 0, 0, 0, 0 / 0 },
        { 14, 0, 0, 0, 9007199254740991 },
        { 15, 0, 0, 0, 4503599627370495 },
        { 16, 0, 0, 0, -4503599627370496 },
        { 17, 0, 0, 0, 4503599627370496 },
      },
      k = {
        NAN, math.huge, -math.huge, -0.0, 1.0, 1,
        3.25, 123456789012345, "plain", "", true, false,
      },
      u = { { 1, 2 }, { 0, 5 }, { 1, 0 } },
    },
    {
      a = 0, v = false,
      c = { { 1, 0, 0, 0, 0 } },
      k = {}, u = {},
    },
  },
}
local fakeKey = 0xDEADBEEF
local fakePayload = Bytecode.pack(fakePlan, { key = fakeKey })
check("round trip: pack key honoured", fakePayload.key == fakeKey)
local fakeBack = Bytecode.unpack(fakePayload.blob, fakeKey)
check("round trip: unpack returns protos", fakeBack ~= nil)
if fakeBack then
  local ok, why = compareProtos(fakePlan.protos, fakeBack)
  check("round trip: all fields, tags and subtypes", ok, why)
  check("round trip: proto count", #fakeBack == 2)
  if math.type then
    check("round trip: float subtype kept",
      math.type(fakeBack[1].k[5]) == "float" and
      math.type(fakeBack[1].k[6]) == "integer")
    check("round trip: float instruction operand kept",
      math.type(fakeBack[1].c[2][5]) == "float")
    check("round trip: negative zero kept", 1 / fakeBack[1].k[4] < 0 and
      1 / fakeBack[1].c[3][5] < 0)
  end
  check("round trip: infinity kept",
    fakeBack[1].k[2] == math.huge and fakeBack[1].k[3] == -math.huge)
  check("round trip: NaN kept", fakeBack[1].k[1] ~= fakeBack[1].k[1])
  check("round trip: negative key normalised",
    Bytecode.unpack(fakePayload.blob,
      fakeKey - 4294967296 - 4294967296) ~= nil)
end

local planBack = Bytecode.unpack(samplePayload.blob, samplePayload.key)
check("pipeline round trip: unpack returns protos", planBack ~= nil)
if planBack then
  local ok, why = compareProtos(samplePlan.protos, planBack)
  check("pipeline round trip: plan identical", ok, why)
end
check("pipeline round trip: verifyOnly accepts",
  Bytecode.unpack(samplePayload.blob, samplePayload.key,
    { verifyOnly = true }) == true)

-- ---------------------------------------------------------------------------
-- 3. Tamper detection: header fields, checksum and key tag
-- ---------------------------------------------------------------------------
local function expectReject(name, blob, key, needle)
  local protos, err = Bytecode.unpack(blob, key)
  local ok = protos == nil and type(err) == "string"
  if ok and needle then ok = string.find(err, needle, 1, true) ~= nil end
  check(name, ok, err or "unpack accepted tampered payload")
end

expectReject("tamper: body byte", flipByte(samplePayload.blob, 17),
  samplePayload.key, "checksum")
expectReject("tamper: checksum field", flipByte(samplePayload.blob, 2),
  samplePayload.key, "checksum")
expectReject("tamper: version byte", flipByte(samplePayload.blob, 13),
  samplePayload.key, "format")
expectReject("tamper: magic byte", flipByte(samplePayload.blob, 14),
  samplePayload.key, "format")
expectReject("tamper: key tag field", flipByte(samplePayload.blob, 9),
  samplePayload.key, "bad key")
expectReject("tamper: wrong key",
  samplePayload.blob, (samplePayload.key + 1) % 4294967296, "bad key")
expectReject("tamper: truncated body",
  string.sub(samplePayload.blob, 1, 15), samplePayload.key, "truncated")

-- The emitted runtime must reject the same tampering before executing.
local function runTampered(blob, key, plan, noLoader)
  local payload = { blob = blob, key = key,
    plainBytes = samplePayload.plainBytes, blobBytes = #blob }
  local source = VMGen.emit(plan or samplePlan, { payload = payload })
  local out = {}
  local env = makeEnv(out)
  local chunk, err
  if setfenv then
    chunk, err = loadChunk(source, "@vm")
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(source, "@vm", "t", env)
  end
  if not chunk then return false, tostring(err), #out, false end
  if noLoader then
    env.load, env.loadstring, env.loadfile, env.dofile = false, false, false, false
  end
  local ok, runErr = pcall(chunk)
  return ok, tostring(runErr), #out, true
end

local okBody, errBody = runTampered(flipByte(samplePayload.blob, 17),
  samplePayload.key)
check("runtime tamper: body rejected", not okBody, errBody)
check("runtime tamper: body message",
  string.find(errBody, "checksum", 1, true) ~= nil, errBody)
local okTag, errTag = runTampered(flipByte(samplePayload.blob, 9),
  samplePayload.key)
check("runtime tamper: key tag rejected", not okTag, errTag)
check("runtime tamper: key tag message",
  string.find(errTag, "bad key", 1, true) ~= nil, errTag)
local okVer, errVer = runTampered(flipByte(samplePayload.blob, 13),
  samplePayload.key)
check("runtime tamper: version rejected", not okVer, errVer)
local okTrunc, errTrunc = runTampered(
  string.sub(samplePayload.blob, 1, 10), samplePayload.key)
check("runtime tamper: truncation rejected", not okTrunc, errTrunc)
check("runtime tamper: truncation message",
  string.find(errTrunc, "truncated", 1, true) ~= nil, errTrunc)

-- Authenticated adversarial fixtures: recompute both outer integrity fields
-- (and inner checksums) so parser failures cannot be explained by a bad MAC.
do
  local I, C = Bytecode._internals, string.char
  local key = samplePayload.key
  local function sign(message)
    local _, hi, lo = I.sip32(message, key, (key + 0x41555448) % 4294967296)
    return message .. I.le32(lo) .. I.le32(hi)
  end
  local function wrap(cipher, length)
    return sign(I.le32(I.fnv1a(cipher)) .. I.le32(length) ..
      samplePayload.blob:sub(9, 16) .. cipher)
  end
  local function bodyBlob(plain)
    return wrap(I.encrypt(plain, key), #plain)
  end
  local function rejectBoth(name, blob, plan, needle)
    local ok, value, err = pcall(Bytecode.unpack, blob, key)
    check(name .. ": unpack controlled", ok and value == nil and
      type(err) == "string" and err:find("bytecode:", 1, true) ~= nil and
      not err:find("attempt to", 1, true) and not err:find("nil value", 1, true) and
      (not needle or err:find(needle, 1, true) ~= nil), err)
    local ran, why, prints, loaded = runTampered(blob, key, plan)
    check(name .. ": runtime controlled before print", loaded and not ran and
      prints == 0 and why:find("bytecode:", 1, true) ~= nil and
      (not needle or why:find(needle, 1, true) ~= nil), why)
  end
  local function rejectBody(name, plain, plan, needle)
    local blob = bodyBlob(plain)
    check(name .. ": authenticated", Bytecode.unpack(blob, key,
      { verifyOnly = true }) == true)
    rejectBoth(name, blob, plan, needle)
  end
  for i, args in ipairs({ {nil, key}, {false, key}, {{}, key}, {12, key},
      {samplePayload.blob, 0 / 0}, {samplePayload.blob, math.huge},
      {samplePayload.blob, key, true} }) do
    local ok, value, err = pcall(Bytecode.unpack, args[1], args[2], args[3])
    check("unpack: bad input " .. i, ok and value == nil and
      type(err) == "string" and err:find("bytecode:", 1, true) ~= nil, err)
  end
  local raw = samplePayload.blob:sub(1, -9)
  check("auth: pack tag matches raw SipHash", sign(raw) == samplePayload.blob)
  check("auth: header exposes eight tag bytes", hdr.tag ==
    samplePayload.blob:sub(-8) and #hdr.tag == 8)
  local folded, hi, lo = I.sipRaw("", 0x07060504, 0x03020100,
    0x0f0e0d0c, 0x0b0a0908)
  check("siphash: raw published 64-bit vector", hi == 0x726fdb47 and
    lo == 0xdd0e0e31 and folded == I.xor32(hi, lo))
  for i = 1, 8 do
    rejectBoth("auth: trailer byte " .. i,
      flipByte(samplePayload.blob, #samplePayload.blob - 8 + i), nil,
      "authentication")
  end
  local modified = flipByte(hdr.body, 1)
  rejectBoth("auth: forged FNV is insufficient", I.le32(I.fnv1a(modified)) ..
    samplePayload.blob:sub(5, 16) .. modified .. hdr.tag, nil, "authentication")
  rejectBoth("auth: changed length is bound", raw:sub(1, 4) ..
    I.le32(hdr.plainLength - 1) .. raw:sub(9) .. hdr.tag, nil, "authentication")
  for _, size in ipairs({0, 1, 15, 16, 23, 24, 25, 87,
      #samplePayload.blob - 8, #samplePayload.blob - 1}) do
    rejectBoth("truncation: " .. size, samplePayload.blob:sub(1, size))
  end
  local badLengths = {
    { "empty", "", 0 }, { "unaligned short", C(0), 1 },
    { "unaligned long", string.rep(C(0), 65), 2 },
    { "zero plain", string.rep(C(0), 64), 0 },
    { "plain past cipher", string.rep(C(0), 64), 65 },
    { "padding full block", string.rep(C(0), 128), 64 },
    { "huge plain", string.rep(C(0), 64), 4294967295 },
  }
  for _, t in ipairs(badLengths) do
    local blob = wrap(t[2], t[3])
    rejectBoth("length: " .. t[1], blob, nil, "length")
    local ok, err = Bytecode.unpack(blob, key, { verifyOnly = true })
    check("length: verifyOnly " .. t[1], ok == nil and
      err:find("length", 1, true) ~= nil, err)
  end
  -- Authenticated header fields still obey their format constraints.
  for _, pos in ipairs({9, 13, 14, 15, 16}) do
    rejectBoth("header: authenticated byte " .. pos, sign(flipByte(raw, pos)))
  end
  local max = 9007199254740991
  local minimal = C(1, 0, 0, 0, 0, 0, 0)
  local maxProto = I.decodeProtos(C(1) .. I.uvar(max) .. C(0, 0, 0, 0, 0), key)
  check("varint: exact double maximum", maxProto[1].a == max)
  check("varint: encoder rejects overflow", not pcall(I.uvar, max + 1))
  local cases = {
    { "truncated varint", C(128) },
    { "noncanonical varint", C(129, 0) .. minimal:sub(2), "varint" },
    { "overflow varint", string.rep(C(255), 7) .. C(16), "varint" },
    { "ninth varint byte", string.rep(C(128), 8) .. C(1), "varint" },
    { "zero prototypes", C(0), "count" },
    { "huge prototypes", I.uvar(max) .. minimal, "count" },
    { "vararg flag", C(1, 0, 2, 0, 0, 0, 0), "flags" },
    { "selfmod flag", C(1, 0, 0, 2, 0, 0, 0), "flags" },
    { "instruction count", C(1, 0, 0, 0) .. I.uvar(max) .. C(0, 0), "count" },
    { "constant section size", C(1, 0, 0, 0, 0, 1) .. I.uvar(max) .. C(0), "bounds" },
    { "upvalue count", minimal:sub(1, 6) .. I.uvar(max), "count" },
    { "upvalue flag", minimal:sub(1, 6) .. C(1, 2, 0), "flag" },
    { "trailing outer data", I.encodeProtos(samplePlan, key) .. C(0), "trailing" },
  }
  for _, t in ipairs(cases) do rejectBody(t[1], t[2], nil, t[3]) end
  for size = 0, 8 do
    rejectBody("constant short section " .. size,
      C(1, 0, 0, 0, 0, 1, size) .. string.rep(C(0), size) .. C(0), nil, "bounds")
  end
  local badFields = {
    { "field tag", C(8), "field tag" },
    { "field empty number", C(3, 0), "number" },
    { "field invalid number", C(3, 3) .. "bad", "number" },
    { "field number overflow", C(3, 5) .. "1e999", "number" },
    { "field length", C(3) .. I.uvar(max), "bounds" },
    { "field varint overlong", C(0, 128, 0), "varint" },
    { "field varint overflow", C(0) .. string.rep(C(255), 7) .. C(16), "varint" },
  }
  for _, t in ipairs(badFields) do
    rejectBody(t[1], C(1, 0, 0, 0, 1, 1, 0, 0, 0) .. t[2] .. C(0, 0), nil, t[3])
  end

  local compiled = build('print("SIDE_EFFECT")', { raw = true })
  local plan = VMGen.randomize(compiled, { seed = 0x91FF, decoys = 160 })
  local function codePrefix(P)
    local out = { I.uvar(P.a), I.uvar(P.v and 1 or 0), C(0), I.uvar(#P.c) }
    for _, ins in ipairs(P.c) do
      out[#out + 1] = I.uvar(ins[1]) .. I.uvar(I.zigzag(ins[2])) ..
        I.uvar(I.zigzag(ins[3])) .. I.uvar(I.zigzag(ins[4])) .. I.encodeField(ins[5])
    end
    return table.concat(out)
  end
  local function sealConstants(data)
    local st = 1234567
    local out, pv = { I.le32(st) }, st % 256
    data = I.le32(I.fnv1a(data)) .. data
    for j = 1, #data do
      st = (st * 1664525 + 1013904223) % 4294967296
      pv = I.xor8(data:byte(j), I.xor8(math.floor(st / 16777216), pv))
      out[#out + 1] = C(pv)
    end
    return table.concat(out)
  end
  local function constProto(P, data, nk)
    local sealed = sealConstants(data)
    local u = { I.uvar(#P.u) }
    for _, pair in ipairs(P.u) do u[#u + 1] = I.uvar(pair[1]) .. I.uvar(pair[2]) end
    return codePrefix(P) .. I.uvar(nk) .. I.uvar(#sealed) .. sealed .. table.concat(u)
  end
  local constants = {
    { "unknown tag", C(8), 1, "tag" },
    { "missing tag", C(4, 1, 65), 2, nil },
    { "truncated length", C(4, 128), 1, "bounds" },
    { "noncanonical length", C(4, 128, 0), 1, "varint" },
    { "overflow length", C(4) .. string.rep(C(255), 7) .. C(16), 1, "varint" },
    { "string bounds", C(4, 10, 65), 1, "bounds" },
    { "empty number", C(3, 0), 1, "number" },
    { "invalid number", C(3, 3) .. "bad", 1, "number" },
    { "number overflow", C(3, 5) .. "1e999", 1, "number" },
    { "trailing data", C(2, 0), 1, "trailing" },
    { "excess count", C(1), 2, "bounds" },
  }
  for _, t in ipairs(constants) do
    rejectBody("lazy constant: " .. t[1], C(1) ..
      constProto(plan.protos[1], t[2], t[3]), plan, t[4])
  end
  local values = {}
  for _, v in ipairs(plan.protos[1].k) do values[#values + 1] = I.encodeValue(v) end
  local validNil = bodyBlob(C(1) .. constProto(plan.protos[1],
    table.concat(values) .. C(0), #values + 1))
  check("constant tag zero: accepted", Bytecode.unpack(validNil, key) ~= nil)
  local ran, why, prints, loaded = runTampered(validNil, key, plan, true)
  check("runtime: loader-free execution", loaded and ran and prints == 1, why)

  local Selfmod = require("src.selfmod")
  local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {} for k, v in pairs(t) do out[k] = copy(v) end return out
  end
  local smPlan = copy(plan)
  Selfmod.apply(smPlan, { key = key, blockSize = 2, maxBlocks = 1 })
  local goodSM = Bytecode.pack(smPlan, { key = key })
  check("selfmod: unpack validates legitimate blocks", Bytecode.unpack(goodSM.blob, key) ~= nil)
  ran, why, prints, loaded = runTampered(goodSM.blob, key, smPlan, true)
  check("selfmod: lazy blocks execute loader-free", loaded and ran and prints == 1, why)
  local badSM = {
    { "zero block size", function(p) p.B = 0 end },
    { "zero cap", function(p) p.cap = 0 end },
    { "small cap", function(p) p.cap = 1 end },
    { "excess cap", function(p) p.cap = p.total + 1 end },
    { "partial window", function(p) p.cap = 3 p.total = 10 end },
    { "zero total", function(p) p.total = 0 end },
    { "block count", function(p) table.remove(p.blocks) end },
    { "chain overflow", function(p) p.chain[1] = 4294967296 end },
    { "short block", function(p) p.blocks[1] = C(0, 0, 0, 0) end },
  }
  for _, t in ipairs(badSM) do
    local bad = copy(smPlan) t[2](bad.protos[1])
    rejectBoth("selfmod: " .. t[1], Bytecode.pack(bad, { key = key }).blob, smPlan)
  end
  local function blockBody(data)
    local bad = copy(smPlan)
    local p = bad.protos[1]
    p.blocks[1] = I.le32(42) .. Selfmod._internals.crypt(
      I.le32(I.fnv1a(data)) .. data, key, 1, 1, 42, p.chain[1])
    return I.encodeProtos(bad, key)
  end
  local goodSlice = Selfmod._internals.encodeSlice(plan.protos[1].c, 1, 2):sub(5)
  rejectBody("lazy block: trailing data", blockBody(goodSlice .. C(0)), smPlan, "trailing")
  rejectBody("lazy block: noncanonical varint", blockBody(C(129, 0, 0, 0, 0, 0, 0) ..
    C(1, 0, 0, 0, 0, 0)), smPlan, "varint")
  rejectBody("lazy block: overflowing opcode", blockBody(string.rep(C(255), 7) ..
    C(16, 0, 0, 0, 0, 0)), smPlan, "varint")
  rejectBody("lazy block: truncated opcode", blockBody(C(1, 0, 0, 0, 3, 5) ..
    "12345" .. C(128)), smPlan, "bounds")
  rejectBody("lazy block: truncated field", blockBody(C(1, 0, 0, 0, 0, 0) ..
    C(1, 0, 0, 0)), smPlan)
  for _, t in ipairs(badFields) do
    rejectBody("lazy block: " .. t[1], blockBody(C(1, 0, 0, 0) .. t[2] ..
      C(1, 0, 0, 0, 0, 0)), smPlan, t[3])
  end
  -- B may exceed total and a whole-prototype cap need not be B-aligned.
  local largeB = copy(plan)
  Selfmod.apply(largeB, { key = key, blockSize = 10000 })
  local largeBlob = Bytecode.pack(largeB, { key = key }).blob
  check("selfmod: block larger than total", Bytecode.unpack(largeBlob, key) ~= nil)
  ran, why, prints, loaded = runTampered(largeBlob, key, largeB)
  check("selfmod: whole prototype partial cap", loaded and ran and prints == 1, why)

  -- Unused sections must remain lazy: malformed contents are checked on access,
  -- not by eagerly decrypting every prototype at startup.
  local lazy = VMGen.randomize(build([[local function unused() return "UNUSED" end
print("SIDE_EFFECT")]], { raw = true }), { seed = 0x9201, decoys = 160 })
  local pieces = { I.uvar(#lazy.protos) }
  for pi, p in ipairs(lazy.protos) do
    pieces[#pieces + 1] = pi == 2 and constProto(p, C(8), 1) or
      I.encodeProtos({ protos = { p } }, key):sub(2)
  end
  local lazyBlob = bodyBlob(table.concat(pieces))
  check("lazy constant: unpack checks unused pool", Bytecode.unpack(lazyBlob, key) == nil)
  ran, why, prints, loaded = runTampered(lazyBlob, key, lazy)
  check("lazy constant: runtime leaves unused pool sealed", loaded and ran and prints == 1, why)
  Selfmod.apply(lazy, { key = key })
  local child = lazy.protos[2]
  child.blocks[1] = flipByte(child.blocks[1], #child.blocks[1])
  lazyBlob = Bytecode.pack(lazy, { key = key }).blob
  check("lazy block: unpack checks unused block", Bytecode.unpack(lazyBlob, key) == nil)
  ran, why, prints, loaded = runTampered(lazyBlob, key, lazy)
  check("lazy block: runtime leaves unused block sealed", loaded and ran and prints == 1, why)
end

-- ---------------------------------------------------------------------------
-- 4. No plaintext in the payload or the emitted chunk
-- ---------------------------------------------------------------------------
local LEAK_MARKER = "ZQ_LEAK_MARKER_9f3a71"
local LEAK_NUMBER = "1234567890123"
local leakSrc = 'print("' .. LEAK_MARKER .. '", ' .. LEAK_NUMBER .. ')'
-- raw = skip string/constant hiding so the literal really lands in K; layer 9
-- alone must keep it out of the file.
local leakCompiled = build(leakSrc, { raw = true })
local leakPlan = VMGen.randomize(leakCompiled, { seed = 0x9A21, decoys = 160 })
local leakPayload = Bytecode.pack(leakPlan, { seed = 0x9A21 })
local leakSource = VMGen.emit(leakPlan, { payload = leakPayload })

check("leak: literal present before packing",
  string.find(table.concat(leakPlan.protos[1].k, "\1"), LEAK_MARKER, 1, true) ~=
    nil)
check("leak: marker absent from blob",
  string.find(leakPayload.blob, LEAK_MARKER, 1, true) == nil)
check("leak: marker absent from source",
  string.find(leakSource, LEAK_MARKER, 1, true) == nil)
check("leak: number text absent from blob",
  string.find(leakPayload.blob, LEAK_NUMBER, 1, true) == nil)
check("leak: number text absent from source",
  string.find(leakSource, LEAK_NUMBER, 1, true) == nil)
local leakPlain, leakStats = VMGen.emit(leakPlan)
local protoKey = "\"" .. leakStats.names.PCC .. "\"]={{"
check("leak: plaintext proto table absent from source",
  string.find(leakSource, protoKey, 1, true) == nil and
  string.find(leakPlain, protoKey, 1, true) ~= nil)
check("leak: key literal absent from source",
  string.find(leakSource, tostring(leakPayload.key), 1, true) == nil)
check("leak: decoder present in source",
  string.find(leakSource, "local n=#", 1, true) ~= nil)
check("leak: no decoder stage name in source",
  string.find(leakSource, "bytecode:", 1, true) == nil and
  string.find(leakSource, "checksum", 1, true) == nil)

local opcodeNames = {}
for i = 1, #Compiler.OPS do opcodeNames[#opcodeNames + 1] = Compiler.OPS[i] end
local opcodeLeaks = 0
for i = 1, #opcodeNames do
  if string.find(leakSource, opcodeNames[i], 1, true) then
    opcodeLeaks = opcodeLeaks + 1
  end
end
check("leak: no opcode mnemonic in source", opcodeLeaks == 0, opcodeLeaks)
notes[#notes + 1] = string.format(
  "MODULE9_LEAK marker=0 number=0 opcodes=%d key=0", opcodeLeaks)

-- ---------------------------------------------------------------------------
-- 5. Cipher properties (ChaCha20 counter mode)
-- ---------------------------------------------------------------------------
local I = Bytecode._internals

-- RFC 8439 section 2.3.2 keystream block: key 00..1f, nonce
-- 000000090000004a00000000, counter 1.
local rfcKeyParts = {}
for i = 0, 31 do rfcKeyParts[#rfcKeyParts + 1] = string.char(i) end
local rfcKey = table.concat(rfcKeyParts)
local rfcNonce = string.char(0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0)
local rfcHex =
  "10f1e7e4d13b5915500fdd1fa32071c4" ..
  "c7d1f4c733c068030422aa9ac3d46c4e" ..
  "d2826446079faa0914c2d705d98b02a2" ..
  "b5129cd1de164eb9cbd083e8a2503c4e"
local rfcWant = {}
for k = 1, #rfcHex, 2 do
  rfcWant[#rfcWant + 1] = string.char(tonumber(rfcHex:sub(k, k + 1), 16))
end
rfcWant = table.concat(rfcWant)
local rfcGot = Bytecode.chacha20Block(rfcKey, rfcNonce, 1)
check("cipher: RFC 8439 keystream vector", rfcGot == rfcWant, #rfcGot)

-- Deterministic pseudo-random bytes for the round-trip sweep.
local function bytes(n, seed)
  local parts, st = {}, (seed or 1) % 4294967296
  for i = 1, n do
    st = (st * 1103515245 + 12345) % 4294967296
    parts[i] = string.char(st % 256)
  end
  return table.concat(parts)
end

local roundTripFail = nil
for len = 1, 40 do
  local plain = bytes(len, len * 7919)
  local cipher = I.encrypt(plain, 0xC0FFEE)
  local want = math.ceil(len / 64) * 64
  if #cipher ~= want then
    roundTripFail = "length " .. len .. " got " .. #cipher .. " want " .. want
    break
  end
  local back = I.decrypt(cipher, 0xC0FFEE, len)
  if back ~= plain then
    roundTripFail = "content " .. len
    break
  end
end
check("cipher: encrypt/decrypt round trip 1..40 bytes", roundTripFail == nil,
  roundTripFail)

local zeros = string.rep("\0", 64)
local zcipher = I.encrypt(zeros, 0x51CE)
local zsame = 0
for i = 1, #zcipher do
  if string.byte(zcipher, i) == 0 then zsame = zsame + 1 end
end
check("cipher: zero plaintext does not stay zero", zsame < 5, zsame)

-- A stream cipher XORs the keystream position by position, so a one-byte
-- plaintext change must move exactly one ciphertext byte.
local oneBit = flipByte(zeros, 33)
local bitCipher = I.encrypt(oneBit, 0x51CE)
local diff = 0
for i = 1, #zcipher do
  if string.byte(zcipher, i) ~= string.byte(bitCipher, i) then
    diff = diff + 1
  end
end
check("cipher: single-byte change stays local", diff == 1, diff)

-- One key bit must scramble a large share of the first block.
local keyBase, keyBit = 0xC0FFEE, 0xC0FFEF
local cBase = I.encrypt(zeros, keyBase)
local cBit = I.encrypt(zeros, keyBit)
local avalanche = 0
for i = 1, 64 do
  if string.byte(cBase, i) ~= string.byte(cBit, i) then
    avalanche = avalanche + 1
  end
end
check("cipher: key change avalanches", avalanche >= 20, avalanche)

local distinctCipher, cipherSet = 0, {}
for k = 1, 10 do
  local c = I.encrypt(zeros, 0x1000 + k * 7919)
  if not cipherSet[c] then distinctCipher = distinctCipher + 1 end
  cipherSet[c] = true
end
check("cipher: ten keys give ten ciphertexts", distinctCipher == 10,
  distinctCipher)

-- The plaintext length is bound into the nonce: decrypting with any other
-- length must not reproduce the plaintext.
local boundPlain = bytes(37, 0xB0B0)
local boundCipher = I.encrypt(boundPlain, 0xBADF00D)
local wrongLen = I.decrypt(boundCipher, 0xBADF00D, 36)
check("cipher: length is bound into the keystream",
  wrongLen ~= boundPlain:sub(1, 36))
local wrongKey = I.decrypt(boundCipher, 0xBADF00E, 37)
check("cipher: key is bound into the keystream", wrongKey ~= boundPlain)

-- ---------------------------------------------------------------------------
-- 6. Emitted runtime equivalence over a semantic corpus
-- ---------------------------------------------------------------------------
local corpus = {
  { "arith", [[
local function f(a, b) return a * b + a - b / 2 end
print(f(3, 4), f(-2, 5), 2 ^ 10, 7 % 3, -7 % 3, 1 / 4)
print(10, 1, 10 + 1, 10 / 2, 10.0 / 2, 3 * 4, 2 ^ 8)
]] },
  { "strings", [[
local s = "ab" .. 1 .. "-" .. 2.5
print(s, #s, ("abc"):upper(), string.rep("xy", 3))
print("tab\tline\nend", "A\66", ("a,b,c"):find(",", 1, true))
]] },
  { "tables", [[
local t = {10, 20, 30, x = "hi"}
t[4] = 40
t.y = "bye"
local u = {0, t[1], t.x}
print(#t, t[1] + t[2] + t[3] + t[4], t.x, t.y, #u, u[2])
]] },
  { "recursion", [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fact(7), fib(10))
]] },
  { "closures", [[
local function counter(start)
  local n = start
  return function(step) n = n + step return n end
end
local c = counter(10)
print(c(1), c(2), c(3))
]] },
  { "loop capture", [[
local t = {}
for i = 1, 3 do t[i] = function() return i * 10 end end
print(t[1](), t[2](), t[3]())
]] },
  { "nested upvalues", [[
local function outer(a)
  local b = a * 2
  local function middle(c)
    local function inner(d) return a + b + c + d end
    return inner(4)
  end
  return middle(3)
end
print(outer(1))
]] },
  { "varargs", [[
local function f(...) local n = select("#", ...) return n, ... end
print(f(1, nil, 3))
local function sum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s
end
print(sum(1, 2, 3, 4))
]] },
  { "method multi assign", [[
local acc = {v = 0}
function acc:add(d) self.v = self.v + d return self end
acc:add(5):add(7)
local function two() return 8, 9 end
local a, b, c = two()
print(acc.v, a, b, c)
]] },
  { "control", [[
local s = 0
for i = 10, 1, -3 do
  s = s + i
  if i == 4 then break end
end
local j = 0
repeat j = j + 2 until j >= 7
print(s, j, 1 < 2, "a" < "b", nil == false, false and 1 or 2)
]] },
  { "generic for", [[
local t = {4, 5, 6}
local s = 0
for i, v in ipairs(t) do s = s + i * v end
local h = {10, 20, 30}
local hsum = 0
for _, v in ipairs(h) do hsum = hsum + v end
print(s, hsum)
]] },
  { "number subtypes", [[
local k = 2.5
print(k * 2, k + 1, -0.0, 1 / 3, 1e300, math.huge, -math.huge)
print(9007199254740991, 123456789012345, 0.1 + 0.2, 1.0, 1)
]] },
  { "constant operands", [[
local x = 10
print(x + 0.5, x - 0.25, x * 1.5, x / 0.5, x % 2.5, 4 ^ 0.5,
      x + 3, x - 3, x * 3, x / 4, x % 3)
]] },
  { "do scope shadowing", [[
local x = 1
do local x = 2 print(x) end
print(x)
local function bump() x = x + 1 return x end
print(bump(), bump(), x)
]] },
}

local covered, corpusFail = 0, nil
for ci = 1, #corpus do
  local name, src = corpus[ci][1], corpus[ci][2]
  local compiled = build(src)
  local seed = 0x9B01 + ci * 131
  local source, stats = Bytecode.generate(compiled,
    { seed = seed, decoys = 160 })
  local want, runErr = execute(src)
  local got, genErr = runGenerated(source)
  local ok = want ~= nil and got == want and stats.packed == true
  if ok then
    covered = covered + 1
  elseif not corpusFail then
    corpusFail = name .. ": " .. tostring(genErr or runErr or
      ("got=" .. tostring(got) .. " want=" .. tostring(want)))
  end
end
check("corpus: packed runtime matches source", corpusFail == nil, corpusFail)
notes[#notes + 1] = string.format("MODULE9_CORPUS %d/%d", covered, #corpus)

-- Stats and convenience wrapper agree with the manual path.
local oneCompiled = build(corpus[1][2])
local onePlan = VMGen.randomize(oneCompiled, { seed = 0x9C01, decoys = 160 })
local onePayload = Bytecode.pack(onePlan, { seed = 0x9C01 })
local oneSource, oneStats = VMGen.emit(onePlan, { payload = onePayload })
check("stats: packed flag", oneStats.packed == true)
check("stats: payload size", oneStats.payloadBytes == #onePayload.blob,
  tostring(oneStats.payloadBytes) .. " ~= " .. #onePayload.blob)
check("stats: plaintext size", oneStats.plainBytes == onePayload.plainBytes)
check("stats: key", oneStats.key == onePayload.key)
check("emit: deterministic", VMGen.emit(onePlan, { payload = onePayload }) ==
  oneSource)
check("emit: still one table dispatch",
  select(2, string.gsub(oneSource, "local " .. oneStats.names.VNPC .. "=", "")) == 1)

-- ---------------------------------------------------------------------------
-- 7. Polymorphism: ten runs, ten distinct payloads and chunks
-- ---------------------------------------------------------------------------
local blobSet, sourceSet, keySet = {}, {}, {}
local distinctBlobs, distinctSources, distinctKeys = 0, 0, 0
for i = 1, 10 do
  local seed = 0x9D00 + i * 1013
  local plan = VMGen.randomize(sampleCompiled, { seed = seed, decoys = 160 })
  local payload = Bytecode.pack(plan, { seed = seed })
  local source = VMGen.emit(plan, { payload = payload })
  if not blobSet[payload.blob] then distinctBlobs = distinctBlobs + 1 end
  blobSet[payload.blob] = true
  if not sourceSet[source] then distinctSources = distinctSources + 1 end
  sourceSet[source] = true
  local key = hex32(payload.key)
  if not keySet[key] then distinctKeys = distinctKeys + 1 end
  keySet[key] = true
end
check("polymorphism: ten distinct blobs", distinctBlobs == 10, distinctBlobs)
check("polymorphism: ten distinct sources", distinctSources == 10,
  distinctSources)
check("polymorphism: ten distinct keys", distinctKeys == 10, distinctKeys)
notes[#notes + 1] = string.format(
  "MODULE9_POLY blobs=%d/10 sources=%d/10 keys=%d/10",
  distinctBlobs, distinctSources, distinctKeys)

-- Same seed must reproduce byte-identical output.
local detA = Bytecode.pack(VMGen.randomize(sampleCompiled,
  { seed = 0x9E01, decoys = 160 }), { seed = 0x9E01 })
local detB = Bytecode.pack(VMGen.randomize(sampleCompiled,
  { seed = 0x9E01, decoys = 160 }), { seed = 0x9E01 })
check("polymorphism: same seed is deterministic", detA.blob == detB.blob)

-- ---------------------------------------------------------------------------
-- 8. Reference VM agreement and a tampered-key runtime check
-- ---------------------------------------------------------------------------
local refOut = {}
local refEnv = makeEnv(refOut)
local refOk, refErr = pcall(VM.run, oneCompiled, refEnv)
local refText = refOk and table.concat(refOut, "\n") or nil
check("reference VM: runs", refOk, refErr)
check("reference VM: agrees with packed runtime",
  refText == runGenerated(oneSource),
  tostring(refText) .. " ~= " .. tostring(runGenerated(oneSource)))

local wrongKeySource = VMGen.emit(onePlan, { payload = {
  blob = onePayload.blob, key = (onePayload.key + 7919) % 4294967296,
  plainBytes = onePayload.plainBytes } })
local wrongChunk = loadGenerated(wrongKeySource)
check("runtime tamper: wrong embedded key rejected",
  wrongChunk ~= nil and not pcall(wrongChunk))

-- ---------------------------------------------------------------------------
-- 9. Scale: 300-line program through the packed pipeline
-- ---------------------------------------------------------------------------
local lines = { "local s = 0" }
for i = 1, 298 do
  lines[#lines + 1] = string.format("s = s + %d", (i * 37) % 23 + 1)
end
lines[#lines + 1] = "print(s)"
local scaleSrc = table.concat(lines, "\n")

local t0 = os.clock()
local scaleCompiled = build(scaleSrc)
local compileMs = (os.clock() - t0) * 1000

t0 = os.clock()
local scalePlan = VMGen.randomize(scaleCompiled,
  { seed = 0x9F01, decoys = 160 })
local scalePayload = Bytecode.pack(scalePlan, { seed = 0x9F01 })
local packMs = (os.clock() - t0) * 1000

t0 = os.clock()
local scaleSource = VMGen.emit(scalePlan, { payload = scalePayload })
local emitMs = (os.clock() - t0) * 1000

local scaleWant = execute(scaleSrc)
local scaleGot = runGenerated(scaleSource)
local scaleInstr = countInstr(scalePlan)
check("scale: packed runtime matches source", scaleWant ~= nil and
  scaleGot == scaleWant,
  tostring(scaleGot) .. " ~= " .. tostring(scaleWant))
check("scale: under the 10 s build budget",
  compileMs + packMs + emitMs < 10000,
  string.format("%.1f ms", compileMs + packMs + emitMs))
check("scale: blob smaller than source", #scalePayload.blob < #scaleSource,
  #scalePayload.blob .. " >= " .. #scaleSource)
check("scale: one chunk loads and runs", loadGenerated(scaleSource) ~= nil)

local lineCount = select(2, string.gsub(scaleSrc, "\n", "")) + 1
notes[#notes + 1] = string.format(
  "MODULE9_SCALE lines=%d protos=%d instr=%d consts=%d plain=%d cipher=%d " ..
  "blob=%d source=%d compile_ms=%.1f pack_ms=%.1f emit_ms=%.1f",
  lineCount, #scalePlan.protos, scaleInstr, countConsts(scalePlan),
  scalePayload.plainBytes, scalePayload.cipherBytes, #scalePayload.blob,
  #scaleSource, compileMs, packMs, emitMs)

-- A payload past ~200 chunks used to be emitted as one `..` chain. Lua parses
-- that as a right-nested expression and rejects the chunk well before any
-- runtime code runs (5.1: "too many syntax levels", 5.4: C stack overflow), so
-- long inputs silently stopped loading. Large payloads must stay flat syntax.
local bigLen = 8192 * 240 + 123
local pad = string.char(0, 17, 254, 3, 128, 41)
local bigBlob = string.rep(pad, math.ceil(bigLen / #pad)):sub(1, bigLen)
local bigSource = VMGen.emit(onePlan, { payload = {
  blob = bigBlob, key = onePayload.key, plainBytes = bigLen } })
local bigChunk, bigErr
if setfenv then
  bigChunk, bigErr = loadChunk(bigSource, "@bigvm")
else
  bigChunk, bigErr = load(bigSource, "@bigvm", "t", {})
end
check("large payload: flat syntax compiles", bigChunk ~= nil, bigErr)
local deepChain = false
for line in bigSource:gmatch("[^\n]+") do
  if line:sub(-2) == ".." then deepChain = true break end
end
check("large payload: no deep concat chain", not deepChain,
  "payload still emitted as one .. chain")
notes[#notes + 1] = string.format(
  "MODULE9_BIGPAYLOAD bytes=%d source=%d chunks=%d",
  bigLen, #bigSource, math.ceil(bigLen / 8192))

-- ---------------------------------------------------------------------------
-- 10. Summary
-- ---------------------------------------------------------------------------
notes[#notes + 1] = string.format(
  "MODULE9_HEADER header=16 trailer=8 version=9 magic=per-build checksum=fnv1a auth=siphash24 " ..
  "sample_plain=%d sample_cipher=%d sample_blob=%d",
  samplePayload.plainBytes, samplePayload.cipherBytes, #samplePayload.blob)
notes[#notes + 1] = string.format(
  "MODULE9_ROUNDTRIP protos=%d instr=%d consts=%d",
  #samplePlan.protos, countInstr(samplePlan), countConsts(samplePlan))
notes[#notes + 1] = string.format(
  "MODULE9_TAMPER unpack=7 runtime=4 wrongkey=1")
notes[#notes + 1] = string.format("MODULE9_CHECKS %d/%d",
  checks - failures, checks)

local printOut = print
for i = 1, #notes do printOut(notes[i]) end
printOut("MODULE9_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
