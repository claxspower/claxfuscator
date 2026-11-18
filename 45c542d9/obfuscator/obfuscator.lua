-- obfuscator.lua -- command-line front-end.
-- Usage: lua obfuscator.lua input.lua output.lua [options]
-- Options: --seed N, --strength 1..3, --no-deadcode, --allow-errors, --quiet
package.path = "./?.lua;./src/?.lua;" .. package.path

local function scriptDir()
  local a0 = (arg and arg[0]) or "obfuscator.lua"
  a0 = a0:gsub("\\", "/")
  local dir = a0:match("^(.*)/[^/]*$")
  if not dir or dir == "" then return "." end
  return dir
end

local ROOT = scriptDir()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/src/?.lua;" .. package.path

local U = require("src.util")
local Parser = require("src.parser")
local T = require("src.transforms")
local Resolver = require("src.resolver")
local Compiler = require("src.compiler")
local VMGen = require("src.vmgen")

local function die(msg, code)
  io.stderr:write("error: " .. tostring(msg) .. "\n")
  os.exit(code or 1)
end

local function readAll(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

local function writeAll(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local STRENGTH = {
  [1] = { density = 1, decoys = 12 },
  [2] = { density = 2, decoys = 24 },
  [3] = { density = 3, decoys = 40 },
}

local function parseArgs(argv)
  local o = { seed = nil, strength = 1, deadcode = true, allowErrors = false, quiet = false }
  local positional = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--seed" then
      i = i + 1
      local v = argv[i]
      if not v or not v:match("^%d+$") then die("--seed requires a non-negative integer") end
      o.seed = tonumber(v) % 4294967296
    elseif a:match("^%-%-seed=") then
      local v = a:sub(8)
      if not v:match("^%d+$") then die("--seed requires a non-negative integer") end
      o.seed = tonumber(v) % 4294967296
    elseif a == "--strength" then
      i = i + 1
      local v = tonumber(argv[i] or "")
      if not v or v < 1 or v > 3 or v ~= math.floor(v) then
        die("--strength requires an integer from 1 to 3")
      end
      o.strength = v
    elseif a:match("^%-%-strength=") then
      local v = tonumber(a:sub(12))
      if not v or v < 1 or v > 3 or v ~= math.floor(v) then
        die("--strength requires an integer from 1 to 3")
      end
      o.strength = v
    elseif a == "--no-deadcode" then
      o.deadcode = false
    elseif a == "--allow-errors" then
      o.allowErrors = true
    elseif a == "--quiet" then
      o.quiet = true
    elseif a == "--help" or a == "-h" then
      o.help = true
    elseif a:sub(1, 1) == "-" then
      die("unknown option: " .. a)
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end
  o.input = positional[1]
  o.output = positional[2]
  return o
end

local function usage()
  io.write([[
Claxfuscator
usage: lua obfuscator.lua <input.lua> <output.lua> [options]

options:
  --seed N          deterministic build seed
  --strength N      protection level 1..3 (default 1)
  --no-deadcode     disable unreachable-code injection
  --allow-errors    emit a best-effort build even if the parser recovered errors
  --quiet           suppress the statistics banner
  -h, --help        show this help
]])
end

local function showDiagnostics(path, src, errors, limit)
  local lines = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local n = math.min(#errors, limit or 25)
  for i = 1, n do
    local e = errors[i]
    local ln = math.max(1, math.floor(tonumber(e.line) or 1))
    local col = math.max(1, math.floor(tonumber(e.col) or 1))
    io.stderr:write(string.format("%s:%d:%d: %s\n", path, ln, col, tostring(e.msg)))
    local text = lines[ln]
    if text then
      if #text > 160 then text = text:sub(1, 160) .. "..." end
      io.stderr:write("  " .. text .. "\n")
      io.stderr:write("  " .. string.rep(" ", math.min(col - 1, 159)) .. "^\n")
    end
  end
  if #errors > n then
    io.stderr:write(string.format("... and %d more diagnostic(s)\n", #errors - n))
  end
end

local opts = parseArgs(arg or {})
if opts.help then usage(); os.exit(0) end
if not opts.input or not opts.output then
  usage()
  die("missing input or output path", 2)
end

local src, rerr = readAll(opts.input)
if not src then die("cannot read '" .. opts.input .. "': " .. tostring(rerr), 2) end

U.seed(opts.seed or (os.time() * 997 + 12345))

local ast, parseErrors = Parser.parse(src, opts.input)
if #parseErrors > 0 then
  showDiagnostics(opts.input, src, parseErrors)
  if not opts.allowErrors then
    die(string.format("%d syntax error(s); no output written", #parseErrors), 2)
  end
  io.stderr:write("warning: continuing with the part of the AST that parsed cleanly\n")
end

local level = STRENGTH[opts.strength]

if opts.deadcode then T.deadcode(ast, { density = level.density }) end

local resolved = Resolver.resolve(ast)
if #resolved.errors > 0 then
  showDiagnostics(opts.input, src, resolved.errors)
  die(string.format("%d resolution error(s); no output written", #resolved.errors), 2)
end

local compiled = Compiler.compile(resolved, {})
if #compiled.errors > 0 then
  showDiagnostics(opts.input, src, compiled.errors)
  die(string.format("%d compilation error(s); no output written", #compiled.errors), 2)
end

local okGen, generated, stats = pcall(VMGen.generate, compiled,
  { seed = opts.seed, decoys = level.decoys })
if not okGen then
  die("code generation failed: " .. tostring(generated), 3)
end

-- Validate the emitted source with the host Lua before touching the output
-- file. This catches emission bugs without executing the payload.
local loader = loadstring or load
local fn, loadErr = loader(generated, "=" .. opts.output)
if not fn then
  writeAll(opts.output .. ".invalid.lua", generated)
  die("internal emitter produced invalid Lua: " .. tostring(loadErr), 3)
end

local BANNER = "--[[ This, File Protected By Claxfuscator V0.2 https://discord.gg/cHawU8Wmzj ]] "
generated = BANNER .. generated
stats.bytes = stats.bytes + #BANNER

local wrote, werr = writeAll(opts.output, generated)
if not wrote then die("cannot write '" .. opts.output .. "': " .. tostring(werr), 4) end

if not opts.quiet then
  io.write("Claxfuscator\n")
  io.write(string.format("  input     : %s\n", opts.input))
  io.write(string.format("  output    : %s\n", opts.output))
  io.write(string.format("  seed      : %s\n", tostring(opts.seed or "time")))
  io.write(string.format("  source    : %d bytes\n", #src))
  io.write(string.format("  output    : %d bytes\n", stats.bytes))
  io.write(string.format("  protos    : %d\n", stats.protos))
  io.write(string.format("  opcodes   : %d real + %d decoy\n", stats.opcodes, stats.decoys))
  io.write(string.format("  strings   : %d encrypted\n", stats.strings))
  io.write(string.format("  checksum  : %d\n", stats.checksum))
  io.write("  status    : ok\n")
end
