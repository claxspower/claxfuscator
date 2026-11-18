-- driver.lua -- browser-side entry point for the obfuscator.
-- The page prepends __SRC, __SEED, __DEAD, __ALLOW, __DENSITY and __DECOYS,
-- plus the module table and a require shim, then runs this chunk in Fengari.
-- Result framing: status \1 payloadLength \1 payload \1 stats \1 diagnostics
-- Fengari hands Lua strings to JavaScript as UTF-8 text, so a frame framed in
-- Lua bytes can be sliced at the wrong offset. Escaping every byte outside
-- printable ASCII keeps byte length and JS length identical.
local function asciiSafe(s)
  s = s:gsub("%%", "%%25")
  s = s:gsub("[^\32-\126\t\n\r]", function(c)
    return string.format("%%%02X", c:byte())
  end)
  return s
end

local function formatErrors(errs)
  local parts = {}
  for i = 1, math.min(#errs, 40) do
    local e = errs[i]
    parts[#parts + 1] = string.format("%d:%d:%s",
      e.line or 0, e.col or 0, tostring(e.msg))
  end
  return table.concat(parts, string.char(10))
end

local function finish(status, payload, stats, diagnostics)
  payload = asciiSafe(payload or "")
  diagnostics = asciiSafe(diagnostics or "")
  return table.concat({
    status, tostring(#payload), payload, stats or "", diagnostics,
  }, string.char(1))
end

local ok, result = pcall(function()
  local U = require("src.util")
  local Parser = require("src.parser")
  local T = require("src.transforms")
  local Resolver = require("src.resolver")
  local Compiler = require("src.compiler")
  local VMGen = require("src.vmgen")

  U.seed(__SEED)
  local ast, parseErrors = Parser.parse(__SRC, "input.lua")
  local warnings = ""
  if #parseErrors > 0 then
    if not __ALLOW then
      return finish("PARSE", "", "", formatErrors(parseErrors))
    end
    warnings = formatErrors(parseErrors)
  end

  if __DEAD then T.deadcode(ast, { density = __DENSITY }) end

  local resolved = Resolver.resolve(ast)
  if #resolved.errors > 0 then
    return finish("RESOLVE", "", "", formatErrors(resolved.errors))
  end

  local compiled = Compiler.compile(resolved, {})
  if #compiled.errors > 0 then
    return finish("COMPILE", "", "", formatErrors(compiled.errors))
  end

  local generatedOk, generated, stats = pcall(VMGen.generate, compiled,
    { seed = __SEED, decoys = __DECOYS })
  if not generatedOk then
    return finish("GEN", "", "", tostring(generated))
  end

  local loader = loadstring or load
  local fn, loadError = loader(generated, "=output")
  if not fn then
    return finish("INVALID", "", "", tostring(loadError))
  end

  local statLine = string.format("%d|%d|%d|%d|%d|%d",
    stats.protos, stats.strings, stats.checksum, stats.bytes, stats.opcodes, stats.decoys)
  return finish("OK", generated, statLine, warnings)
end)

if not ok then
  return finish("CRASH", "", "", tostring(result))
end
return result
