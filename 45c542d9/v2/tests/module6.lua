-- module6.lua -- acceptance tests for string encryption (layer 6).
--
-- Pipeline under test: parse -> analyze/rename -> consts -> flatten -> opaque
-- -> strings, which is the exact order the build uses. Strings are replaced by
-- calls into one generated decoder, so every program is compared with its
-- source behaviour on all five hosts.
local Parser = require("src.parser")
local Ast = require("src.ast")
local Scope = require("src.scope")
local Consts = require("src.consts")
local Flatten = require("src.flatten")
local Opaque = require("src.opaque")
local Strings = require("src.strings")
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

local function errorText(list)
  local parts = {}
  for i = 1, #list do
    local e = list[i]
    parts[i] = e.line .. ":" .. e.col .. " " .. tostring(e.msg)
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

local function pipeline(src, opts)
  local ast, errors = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  Consts.run(ast, { seed = 0x0C057A })
  Flatten.run(ast, { seed = 3 })
  Opaque.run(ast, { seed = 5, prob = 0.6 })
  local stats = Strings.run(ast, opts or { seed = 0x5CE41D })
  return ast, result, stats, Emit.source(ast), errors
end

local function checkProgram(name, src, expected)
  local original = execute(src)
  local ast, result, stats, text, errors = pipeline(src)
  check(name .. ": parse clean", #errors == 0, errorText(errors))
  check(name .. ": analyze clean", #result.errors == 0, errorText(result.errors))
  check(name .. ": literals handled",
    stats.strings > 0 or stats.skipped.empty > 0, stats.strings)
  local violations = Ast.validate(ast)
  check(name .. ": AST valid", #violations == 0, violations[1])
  local out, err = execute(text)
  check(name .. ": output", out == original, err or out)
  if expected ~= nil then
    check(name .. ": expected", out == expected, out)
  end
  return ast, stats, text
end

local function countOf(text, needle)
  local n, pos = 0, 1
  while true do
    local at = text:find(needle, pos, true)
    if not at then return n end
    n = n + 1
    pos = at + #needle
  end
end

-- Strings that came from the source program: synthetic decoder subtrees are
-- skipped, because their field names and pool are runtime structure.
local function countPlainStrings(root)
  local n = 0
  local function visit(node)
    if node.synthetic then return end
    if node.type == "String" then n = n + 1 end
    for i = 1, #node.children do visit(node.children[i]) end
  end
  visit(root)
  return n
end

local function makeRng(seed)
  local state = seed % 4294967296
  return function(n)
    state = (state * 1664525 + 1013904223) % 4294967296
    if n <= 65536 then return math.floor(state / 65536) % n + 1 end
    return state % n + 1
  end
end

-- ---------------------------------------------------------------------------
-- 1. Every scheme round-trips at build level
-- ---------------------------------------------------------------------------
do
  local values = {
    "a", "ab", "abc", "hello", "hello world", "abracadabra",
    "line\nbreak", 'quote"slash\\', "Türkçe metin",
    "bin\0\1\255", string.rep("x", 40), string.rep("abcdefghij", 20),
  }
  local bytes = {}
  for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
  values[#values + 1] = string.rep(table.concat(bytes), 3)
  local rng = makeRng(0xC0FFEE)
  for s = 1, #Strings.SCHEMES do
    local scheme = Strings.SCHEMES[s]
    local okAll, detail = true, nil
    for i = 1, #values do
      local value = values[i]
      local desc = Strings.encode(value, scheme, rng)
      if not desc then
        okAll = false
        detail = "encode declined " .. #value .. " bytes"
        break
      end
      local got = Strings.decode(desc)
      if got ~= value then
        okAll = false
        detail = scheme .. " mismatch at value " .. i
        break
      end
      if desc.salt < 0 or desc.salt > 65535 then
        okAll = false
        detail = "salt out of range"
        break
      end
      if #desc.key < 6 or #desc.key > 10 then
        okAll = false
        detail = "key length " .. #desc.key
        break
      end
      if #value >= 5 and desc.blob:find(value, 1, true) then
        okAll = false
        detail = "plaintext visible in blob"
        break
      end
    end
    check("scheme round-trip " .. scheme, okAll, detail)
  end

  local first = Strings.encode("same plaintext", "xor", rng)
  local second = Strings.encode("same plaintext", "xor", rng)
  check("same plaintext, distinct blobs", first.blob ~= second.blob)
  check("same plaintext, distinct salts", first.salt ~= second.salt)
  check("same plaintext, distinct keys", first.key ~= second.key)
  check("decode independent of descriptor order",
    Strings.decode(first) == "same plaintext" and
    Strings.decode(second) == "same plaintext")

  local original = string.rep("A", 300)
  local changed = original:sub(1, 99) .. "B" .. original:sub(101)
  local chained = Strings.encode(original, "xor", makeRng(12345))
  local altered = Strings.encode(changed, "xor", makeRng(12345))
  check("xor chain: same key and salt",
    chained.key == altered.key and chained.salt == altered.salt)
  check("xor chain: unchanged prefix", chained.blob:sub(1, 99) == altered.blob:sub(1, 99))
  local propagated = true
  for i = 100, #original do
    if chained.blob:byte(i) == altered.blob:byte(i) then propagated = false end
  end
  check("xor chain: change propagates past byte 256", propagated)
  check("xor chain: both directions round-trip",
    Strings.decode(chained) == original and Strings.decode(altered) == changed)

  local huff = Strings.encode(string.rep("z", 64), "huff", rng)
  check("huffman single-symbol", huff and Strings.decode(huff) == string.rep("z", 64))
end

-- ---------------------------------------------------------------------------
-- 2. Driver-level behaviour on a corpus
-- ---------------------------------------------------------------------------
checkProgram("basic", [[
print("hello world", "second string")
]], "hello world\tsecond string")

checkProgram("escapes", [[
local s = "line1\nline2\ttab\"quote\\slash"
print(s)
print(#s)
]], "line1\nline2\ttab\"quote\\slash\n27")

checkProgram("methods", [[
print(("alpha"):upper() .. "-" .. ("beta"):lower())
]], "ALPHA-beta")

checkProgram("table-name-keys", [[
local t = { first_key = 1, ["second key"] = 2, third = "value here" }
print(t.first_key, t["second key"], t.third)
]], "1\t2\tvalue here")

checkProgram("table-literal", [[
local t = { "one", "two", "three" }
print(#t, t[1], t[3])
]], "3\tone\tthree")

checkProgram("dotted-assignment", [[
local t = {}
t.field_name = "dotted access"
print(t.field_name, t["field_name"])
]], "dotted access\tdotted access")

checkProgram("empty-string", [[
print(#"", "" == "")
]], "0\ttrue")

checkProgram("binary-bytes", [[
local s = "\0\1\2\255\254binary"
print(#s, s:byte(1), s:byte(4), s:byte(5))
]], "11\t0\t255\t254")

checkProgram("duplicate-literal", [[
local a = "duplicate literal"
local b = "duplicate literal"
print(a == b, a)
]], "true\tduplicate literal")

checkProgram("long-bracket", [=[
local s = [[line one
line two "quoted" \n literal]]
print(s:sub(1, 8), #s)
]=], "line one\t37")

checkProgram("format", [[
print(string.format("%s=%d", "count", 7))
]], "count=7")

checkProgram("truthiness", [[
if "nonempty" then print("truthy") end
if "" then print("empty truthy") end
]], "truthy\nempty truthy")

checkProgram("utf8", [[
local s = "Türkçe metin"
print(#s, s:sub(1, 2))
]], "14\tT\195")

checkProgram("vararg", [[
local function f(...) return select("#", ...) end
print(f("one", "two", "three"))
]], "3")

checkProgram("nested-tables", [[
local cfg = { name = "outer", child = { label = "inner", value = 5 } }
print(cfg.name, cfg.child.label, cfg.child.value)
]], "outer\tinner\t5")

checkProgram("return-only", [[
return "tail value"
]], "")

checkProgram("closure", [[
local s = "closure seen"
local function f() return s end
print(f())
]], "closure seen")

checkProgram("loop-cache", [[
local total = 0
for i = 1, 100 do
  if "needle" == "needle" then total = total + 1 end
end
print(total, "needle")
]], "100\tneedle")

-- ---------------------------------------------------------------------------
-- 3. Pool and replacing structure
-- ---------------------------------------------------------------------------
do
  local strings = {}
  for i = 1, 15 do strings[i] = '"entry number ' .. i .. '"' end
  local ast, _, stats, text = pipeline("print(" .. table.concat(strings, ", ") .. ")")

  check("pool: every literal hidden", stats.strings == 15, stats.strings)
  check("pool: entries match", #stats.entries == 15, #stats.entries)
  check("pool: non-empty", stats.blobBytes > 0, stats.blobBytes)
  check("pool: every scheme used", (function()
    for i = 1, #Strings.SCHEMES do
      if (stats.schemes[Strings.SCHEMES[i]] or 0) < 1 then return false end
    end
    return true
  end)(), stats.schemes.xor .. "/" .. stats.schemes.b64 .. "/" .. stats.schemes.huff ..
    "/" .. stats.schemes.feistel .. "/" .. stats.schemes.lookup ..
    "/" .. stats.schemes.chain)

  local decoded = true
  for i = 1, #stats.entries do
    if Strings.decode(stats.entries[i], stats.poolInv) ~= stats.entries[i].plain then decoded = false end
  end
  check("pool: build decoder matches entries", decoded)

  -- Every entry carries one shared keyed byte permutation. Without the pool
  -- inverse the blob decodes to the same length but different bytes, and the
  -- S-box itself must stay a 256-way bijection.
  local pentry = stats.entries[1]
  local wrong = Strings.decode(pentry, nil)
  check("perm: global S-box guards entries", wrong ~= pentry.plain and
    #wrong == #pentry.plain, #pentry.plain)
  local seenPerm, permOk = {}, type(stats.poolPerm) == "table" and
    #stats.poolPerm == 256
  if permOk then
    for i = 1, 256 do
      local v = stats.poolPerm[i]
      if seenPerm[v] or v < 0 or v > 255 then permOk = false break end
      seenPerm[v] = true
    end
  end
  check("perm: pool S-box is a bijection", permOk)

  -- Blob map consumed by the layer 11 deviation: one {start, stop} pair per
  -- pool entry, each inside the pool and exactly as long as its blob.
  local ranges = Strings.poolBlobs(stats.pool)
  local blobOk = ranges ~= nil and #ranges == stats.totalEntries
  if blobOk then
    local order = stats.poolOrder
    for i = 1, #ranges do
      local e, entry = ranges[i], order[i]
      if e.start ~= entry.poolOffset + 12 + #entry.key + #entry.meta or
         e.stop - e.start + 1 ~= #entry.blob or e.stop > #stats.pool or
         e.start < 1 then
        blobOk = false
      end
    end
  end
  check("pool: blob ranges cover every ciphertext", blobOk)
  check("pool: blob ranges reject non-pools",
    Strings.poolBlobs("not a serialized pool") == nil and
    Strings.poolBlobs(string.rep("\0", 40)) == nil)

  local _, _, fstats = pipeline(
    'local t = { alpha = "value" } print(t.alpha)')
  local fieldCount = 0
  for _ in pairs(fstats.fieldKeys or {}) do fieldCount = fieldCount + 1 end
  check("pool: field-name entries are recorded", fieldCount >= 1, fieldCount)

  local ids = {}
  local distinct = true
  for i = 1, #Strings.SCHEMES do
    local id = stats.schemeIds[Strings.SCHEMES[i]]
    if id < 1 or id > 255 or ids[id] then distinct = false end
    ids[id] = true
  end
  check("pool: scheme ids remapped", distinct)

  check("pool: runtime name shape",
    type(stats.runtimeName) == "string" and #stats.runtimeName == 19 and
    stats.runtimeName:match("^_0x%x+$") ~= nil, stats.runtimeName)
  check("pool: runtime local once",
    countOf(text, "local " .. stats.runtimeName .. " =") == 1)
  check("pool: every replacement is a call",
    countOf(text, stats.runtimeName .. "(") == stats.strings,
    countOf(text, stats.runtimeName .. "("))

  local reparsed, errors = parse(text)
  check("pool: emitted text parses", #errors == 0, errorText(errors))
  check("pool: emitted AST valid", #Ast.validate(reparsed) == 0)
  check("pool: output", execute(text) == "entry number 1\tentry number 2\t" ..
    "entry number 3\tentry number 4\tentry number 5\tentry number 6\t" ..
    "entry number 7\tentry number 8\tentry number 9\tentry number 10\t" ..
    "entry number 11\tentry number 12\tentry number 13\tentry number 14\t" ..
    "entry number 15", execute(text))

  local again = Strings.run(ast, { seed = 0x5CE41D })
  check("pool: idempotent", again.strings == 0, again.strings)
  check("pool: text stable", Emit.source(ast) == text)

  check("pool: six dispatch arms",
    countOf(text, "if m ==") - countOf(text, "elseif m ==") == 1 and
    countOf(text, "elseif m ==") == 5,
    countOf(text, "if m ==") .. "/" .. countOf(text, "elseif m =="))

  local fields = Ast.find(ast, "TableField")
  local named = 0
  for i = 1, #fields do
    if fields[i].kind == "name" then named = named + 1 end
  end
  check("pool: no plain name fields left", named == 0, named)
  notes[#notes + 1] = string.format("MODULE6_POOL entries=%d bytes=%d",
    stats.strings, stats.blobBytes)
end

do
  local ast = parse('print("alpha", "beta", "", "gamma")')
  local before = countPlainStrings(ast)
  local stats = Strings.run(ast, { seed = 3 })
  local after = countPlainStrings(ast)
  check("structure: literals consumed", after == before - stats.strings,
    before .. " -> " .. after .. " (hidden " .. stats.strings .. ")")
  check("structure: only empty remains", after == 1, after)
end

-- ---------------------------------------------------------------------------
-- 3b. Trap layer: decoys, canaries, out-of-range and tamper response
-- ---------------------------------------------------------------------------
do
  local strings = {}
  for i = 1, 12 do strings[i] = '"trap target ' .. i .. '"' end
  local ast, _, stats, text = pipeline("print(" .. table.concat(strings, ", ") .. ")")

  check("trap: minimum decoys", stats.decoyCount == 24, stats.decoyCount)
  check("trap: pool total", stats.totalEntries == #stats.entries + stats.decoyCount,
    stats.totalEntries)
  check("trap: canaries", #stats.canaries == stats.decoyCount, #stats.canaries)
  check("trap: synthesis seed", type(stats.trap.synthSeed) == "number" and
    stats.trap.synthSeed >= 0 and stats.trap.synthSeed < 4294967296 and
    stats.trap.synthSeed % 1 == 0)

  local seenDecoy, decoyOk = {}, true
  local lengths, localOnly = {}, true
  for i = 1, #stats.decoys do
    local d = stats.decoys[i]
    if not d.decoy or d.seq then decoyOk = false end
    if d.plain == "" or seenDecoy[d.plain] then decoyOk = false end
    seenDecoy[d.plain] = true
    lengths[#d.plain] = true
    if #d.plain > 96 or d.plain:find("/", 1, true) then localOnly = false end
    if Strings.decode(d, stats.poolInv) ~= d.plain then decoyOk = false end
  end
  check("trap: decoy entries unique and self-consistent", decoyOk)
  check("trap: decoys are bounded local identifiers", localOnly)
  local lengthCount = 0
  for _ in pairs(lengths) do lengthCount = lengthCount + 1 end
  check("trap: decoy lengths vary", lengthCount >= 4, lengthCount)
  for i = 1, #Strings.SCHEMES do
    local scheme = Strings.SCHEMES[i]
    check("trap: decoy scheme " .. scheme, (stats.decoySchemes[scheme] or 0) > 0)
  end

  local collision = false
  for i = 1, #stats.entries do
    if seenDecoy[stats.entries[i].plain] then collision = true end
  end
  check("trap: decoys differ from real strings", not collision)

  local canaryOk = true
  for i = 1, #stats.canaries do
    local c = stats.canaries[i]
    local entry = stats.poolOrder[c.index]
    if not entry or not entry.decoy then canaryOk = false end
    if c.check ~= Strings.checksum(entry.plain) then canaryOk = false end
    if not stats.canaryKeys[c.index] or not ast.canaryKeys[c.index] then canaryOk = false end
  end
  check("trap: canaries point at decoys", canaryOk)

  local callOk, realCalls = true, 0
  local calls = Ast.find(ast, "Call")
  for i = 1, #calls do
    local fn = calls[i].children[1]
    if fn and fn.type == "Name" and fn.value == stats.runtimeName then
      realCalls = realCalls + 1
      local idx = calls[i].children[2].value
      local entry = stats.poolOrder[idx]
      if not entry or entry.decoy or entry.seq == nil then callOk = false end
    end
  end
  check("trap: every call points at a real entry",
    callOk and realCalls == stats.strings, realCalls .. "/" .. stats.strings)
  check("trap: output", execute(text) == execute("print(" ..
    table.concat(strings, ", ") .. ")"))

  local source = Strings.runtimeSource("T", stats.pool, stats.schemeIds, stats.trap,
    nil, stats.poolKey, stats.poolKey2)
  local probeIdx, probePlain = nil, nil
  for pos = 1, #stats.poolOrder do
    local entry = stats.poolOrder[pos]
    if not entry.decoy and #entry.plain >= 4 then
      probeIdx, probePlain = pos, entry.plain
      break
    end
  end
  check("trap: probe avail", probeIdx ~= nil)

  check("seal: length preserved", stats.poolSealed ~= nil and
    #stats.poolSealed == #stats.pool, stats.poolSealed and #stats.poolSealed)
  check("seal: ciphertext differs", stats.poolSealed ~= stats.pool)
  local blind = Strings.runtimeSource("B", stats.poolSealed, stats.schemeIds, nil)
  local blindOut = execute(blind .. "\nprint(B(" .. probeIdx .. "))")
  check("seal: no decode without key", blindOut ~= probePlain, tostring(blindOut))
  local keyed = Strings.runtimeSource("C", stats.poolSealed, stats.schemeIds, nil,
    stats.poolKey, stats.poolKey, stats.poolKey2)
  check("seal: keyed decode", execute(keyed .. "\nprint(C(" .. probeIdx .. "))") == probePlain)

  local out = execute(source .. "\nprint(T(" .. probeIdx .. "))")
  check("trap: clean pool decodes", out == probePlain, out)

  local otherTrap = {
    total = stats.trap.total, canaries = stats.trap.canaries,
    synthSeed = (stats.trap.synthSeed + 1) % 4294967296,
  }
  local expected = {}
  for i = 1, #stats.poolOrder do expected[i] = Strings.quote(stats.poolOrder[i].plain) end
  local fixture = "local function fixture()\n" .. source .. "\nreturn T end\n" ..
    "local forward,reverse=fixture(),fixture()\n" ..
    Strings.runtimeSource("other", stats.pool, stats.schemeIds, otherTrap,
      nil, stats.poolKey, stats.poolKey2) ..
    "\nlocal expected={" .. table.concat(expected, ",") .. "}\n" .. [[
local first = #expected + 1
local values, seen, lengths = {}, {}, {}
for i = first, first + 255 do
  local v = forward(i)
  assert(#v >= 24 and #v <= 48 and v:match("^[0-9a-f]+$"), "token format")
  assert(not seen[v], "consecutive tokens collide")
  assert(v ~= other(i), "different seeds collide")
  values[i], seen[v], lengths[#v] = v, true, true
end
for i = first + 255, first, -1 do
  assert(forward(i) == values[i], "same-index cache changed")
  assert(reverse(i) == values[i], "call order changed token")
  if i >= first + 16 then assert(values[i] ~= values[i - 16], "period-16 collision") end
end
local n = 0
for _ in pairs(lengths) do n = n + 1 end
assert(n > 1, "token lengths do not vary")
for i = #expected, 1, -1 do
  assert(forward(i) == expected[i] and reverse(i) == expected[i], "valid pool read changed")
  assert(other(i) == expected[i], "seed changed valid pool read")
end
print("ok")
]]
  local fixtureOut, fixtureErr = execute(fixture)
  check("trap: 256-token diversity, determinism and pool fixture",
    fixtureOut == "ok", fixtureErr or fixtureOut)

  local tampered = stats.pool
  for i = 1, #stats.canaries do
    local at = stats.canaries[i].blobOffset
    local b = tampered:byte(at)
    tampered = tampered:sub(1, at - 1) .. string.char((b + 1) % 256) ..
      tampered:sub(at + 1)
  end
  local badSource = Strings.runtimeSource("T", tampered, stats.schemeIds, stats.trap,
    nil, stats.poolKey, stats.poolKey2)
  local badOut = execute(badSource .. "\nprint(T(" .. probeIdx .. "))")
  local rotated = probePlain:sub(2) .. probePlain:sub(1, 1)
  check("trap: tampered pool diverges", badOut ~= probePlain, badOut)
  check("trap: tampered pool rotates", badOut == rotated,
    tostring(badOut) .. " vs " .. rotated)

  notes[#notes + 1] = string.format("MODULE6_TRAP decoys=%d canaries=%d total=%d",
    stats.decoyCount, #stats.canaries, stats.totalEntries)
end

do
  local ast = parse('print("one", "two", "three", "four")')
  local stats = Strings.run(ast, { seed = 0x33, traps = false })
  check("trap-off: no decoys", stats.decoyCount == 0 and #stats.canaries == 0)
  check("trap-off: index range", stats.totalEntries == stats.strings, stats.totalEntries)
  local source = Strings.runtimeSource("T", stats.pool, stats.schemeIds, stats.trap,
    nil, stats.poolKey, stats.poolKey2)
  check("trap-off: decoder has no canary scaffold",
    source:find("local G=0", 1, true) == nil and source:find("local NT=", 1, true) == nil)
  check("trap-off: out-of-range stays empty",
    execute(source .. "\nprint(#T(" .. (stats.totalEntries + 1) .. "))") == "0")
end

do
  local sizes = { 1, 43, 47, 100, 213, 214 }
  for i = 1, #sizes do
    local n, literals = sizes[i], {}
    for j = 1, n do literals[j] = Strings.quote("size item " .. j) end
    local ast = parse("return {" .. table.concat(literals, ",") .. "}")
    local stats = Strings.run(ast, { seed = 17 })
    local want = math.min(180, math.max(24, math.floor(n * 0.9)))
    check("trap: sizing " .. n, stats.strings == n and stats.decoyCount == want,
      stats.decoyCount .. "/" .. want)
  end
end
-- ---------------------------------------------------------------------------
-- 4. Name-field conversion and leakage
-- ---------------------------------------------------------------------------
do
  local ast, _, stats, text = pipeline([[
local t = { alpha = "delta", ["beta key"] = "gamma value" }
print(t.alpha, t["beta key"])
]])
  local fields = Ast.find(ast, "TableField")
  local converted = 0
  for i = 1, #fields do
    local field = fields[i]
    if field.kind == "key" and field.key and field.key.type == "Call" then
      converted = converted + 1
    end
  end
  check("keys: name fields converted", converted >= 2, converted)
  check("keys: output", execute(text) == "delta\tgamma value")

  local secret = "SUPER_SECRET_TOKEN_42"
  local _, _, leakStats, leakText = pipeline("local function token() return \"" ..
    secret .. "\" end\nprint(token())")
  check("leak: text clean", leakText:find(secret, 1, true) == nil)
  check("leak: pool clean", leakStats.pool:find(secret, 1, true) == nil)
  check("leak: output", execute(leakText) == secret)
end

-- ---------------------------------------------------------------------------
-- 5. Skips
-- ---------------------------------------------------------------------------
do
  local ast, _ = parse('print("keep me")')
  local before = Emit.source(ast)
  local stats = Strings.run(ast, { enabled = false })
  check("skip-disabled: nothing hidden", stats.strings == 0 and stats.skipped.disabled == 1)
  check("skip-disabled: text untouched", Emit.source(ast) == before)
end

do
  local ast = parse('print("one", "two", "three")')
  local before = Emit.source(ast)
  local stats = Strings.run(ast, { seed = 1, prob = 0 })
  check("skip-prob: total counted", stats.total == 3, stats.total)
  check("skip-prob: nothing hidden", stats.strings == 0, stats.strings)
  check("skip-prob: reason", stats.skipped.prob == 3, stats.skipped.prob)
  check("skip-prob: text untouched", Emit.source(ast) == before)
end

do
  local ast = parse('print("short", "long enough string")')
  local stats = Strings.run(ast, { seed = 1, minLength = 10 })
  check("skip-min: short skipped", stats.skipped.short == 1, stats.skipped.short)
  check("skip-min: long hidden", stats.strings == 1, stats.strings)
end

do
  local ast = parse('print("", #"")')
  local stats = Strings.run(ast, { seed = 1 })
  check("skip-empty: counted", stats.skipped.empty == 2, stats.skipped.empty)
  check("skip-empty: none hidden", stats.strings == 0, stats.strings)
end

do
  local ast = parse("local _0xdeadbeefdeadbeef = 5\nprint(_0xdeadbeefdeadbeef, \"text\")")
  local stats = Strings.run(ast, { seed = 0x99 })
  check("name: collision avoided", stats.runtimeName ~= "_0xdeadbeefdeadbeef",
    stats.runtimeName)
end

-- ---------------------------------------------------------------------------
-- 6. Determinism and polymorphism
-- ---------------------------------------------------------------------------
do
  local src = 'local s = "alpha" print(s, "beta", "gamma", "delta", "epsilon")'

  local function variant(seed)
    local ast = parse(src)
    local result = Scope.analyze(ast, { seed = 0x51EED })
    Scope.apply(result)
    local stats = Strings.run(ast, { seed = seed })
    return Emit.source(ast), stats
  end

  local a, sa = variant(7)
  local b, sb = variant(7)
  local c, sc = variant(8)
  check("determinism: same seed reproduces", a == b)
  check("determinism: different seed diverges", a ~= c)
  check("determinism: synthesis seed reproduces", sa.trap.synthSeed == sb.trap.synthSeed)
  check("determinism: synthesis seed varies", sa.trap.synthSeed ~= sc.trap.synthSeed)
  check("determinism: fractional seed normalized", a == variant(7.9))
  check("determinism: negative seed normalized", a == variant(-7.9))

  local seen, names = {}, {}
  local unique, namesUnique = true, true
  for seed = 1, 10 do
    local text, stats = variant(seed)
    if seen[text] then unique = false end
    seen[text] = true
    if names[stats.runtimeName] then namesUnique = false end
    names[stats.runtimeName] = true
  end
  check("determinism: ten seeds, ten outputs", unique)
  check("determinism: ten runtime names", namesUnique)
  notes[#notes + 1] = "MODULE6_POLY 10/10"

  local ast = parse('return "rng fixture"')
  local stats = Strings.run(ast, { seed = 12345, traps = false })
  check("rng: names retain full state", stats.runtimeName == "_0x852336b85efe0ab7",
    stats.runtimeName)
  check("rng: salt uses high half", stats.entries[1].salt == 21369, stats.entries[1].salt)
end

-- ---------------------------------------------------------------------------
-- 7. Scale: 300 literals
-- ---------------------------------------------------------------------------
do
  local lines = { "local t = {" }
  for i = 1, 300 do
    lines[#lines + 1] = string.format('  "item %03d",', i)
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = "print(#t, t[1], t[300])"
  local src = table.concat(lines, "\n")
  local original = execute(src)

  local started = os.clock()
  local ast = parse(src)
  local result = Scope.analyze(ast, { seed = 0x51EED })
  Scope.apply(result)
  local stats = Strings.run(ast, { seed = 5 })
  local text = Emit.source(ast)
  local elapsed = os.clock() - started

  check("scale: analyze clean", #result.errors == 0, errorText(result.errors))
  check("scale: all literals hidden", stats.strings == 300, stats.strings)
  check("scale: decoys capped", stats.decoyCount == 180, stats.decoyCount)
  local seen, forms, unique = {}, {}, true
  for i = 1, #stats.decoys do
    local plain = stats.decoys[i].plain
    if seen[plain] then unique = false end
    seen[plain] = true
    if plain:find("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x") then
      forms.uuid = true
    elseif plain:sub(1, 1) == "_" then forms.localName = true
    elseif plain:find("[", 1, true) then forms.indexed = true
    elseif plain:find(":", 1, true) then forms.scoped = true
    else forms.joined = true end
  end
  check("scale: decoys unique at cap", unique)
  check("scale: all five local decoy forms", forms.uuid and forms.localName and
    forms.indexed and forms.scoped and forms.joined)
  check("scale: AST valid", #Ast.validate(ast) == 0)
  check("scale: pool compact",
    stats.blobBytes < (stats.strings + stats.decoyCount) * 45, stats.blobBytes)
  local out, err = execute(text)
  check("scale: output", out == original, err or out)
  check("scale: under two seconds", elapsed < 2, elapsed)
  notes[#notes + 1] = string.format("MODULE6_SCALE strings=%d pool=%d ms=%.1f",
    stats.strings, stats.blobBytes, elapsed * 1000)
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
emit(string.format("MODULE6_CHECKS %d/%d", checks - failures, checks))
emit("MODULE6_RESULT " .. (failures == 0 and "PASS" or "FAIL"))
