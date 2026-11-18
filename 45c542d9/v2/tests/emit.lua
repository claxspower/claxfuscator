-- emit.lua -- minimal AST -> Lua source printer used by the module tests.
--
-- This is intentionally *not* part of the obfuscator pipeline (module 7 builds
-- bytecode). The tests need runnable Lua to prove that renaming preserves
-- semantics, and this printer reproduces the normalized tree exactly, including
-- operator precedence and parentheses.

local Emit = {}

local PREC = {
  ["or"] = 1, ["and"] = 2,
  ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
  ["|"] = 4, ["~"] = 5, ["&"] = 6, ["<<"] = 7, [">>"] = 7,
  [".."] = 8, ["+"] = 9, ["-"] = 9, ["*"] = 10, ["/"] = 10, ["//"] = 10,
  ["%"] = 10, ["^"] = 12,
}
local RIGHT_ASSOC = { [".."] = true, ["^"] = true }
local UNARY_PREC = 11

local function quote(s)
  s = tostring(s)
  local parts = { '"' }
  for i = 1, #s do
    local byte = s:byte(i)
    local c = s:sub(i, i)
    if c == "\\" then parts[#parts + 1] = "\\\\"
    elseif c == '"' then parts[#parts + 1] = '\\"'
    elseif c == "\n" then parts[#parts + 1] = "\\n"
    elseif c == "\r" then parts[#parts + 1] = "\\r"
    elseif byte < 32 or byte >= 127 then parts[#parts + 1] = string.format("\\%03d", byte)
    else parts[#parts + 1] = c end
  end
  parts[#parts + 1] = '"'
  return table.concat(parts)
end

local function numberText(n)
  local raw = n.raw
  if type(raw) == "string" and raw:match("^%-?%d+$") then return raw end
  local v = n.value
  if type(v) ~= "number" then return "0" end
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
    return string.format("%.0f", math.floor(v))
  end
  return string.format("%.17g", v)
end

local exprAt
local blockLines

local function indentText(level)
  return string.rep("  ", level)
end

local function appendAll(dst, src)
  for i = 1, #src do dst[#dst + 1] = src[i] end
end

local function paramText(fn)
  local parts = {}
  for i = 1, #(fn.params or {}) do parts[i] = fn.params[i] end
  if fn.vararg then parts[#parts + 1] = "..." end
  return table.concat(parts, ", ")
end

local function functionExpr(fn)
  local lines = { "function(" .. paramText(fn) .. ")" }
  appendAll(lines, blockLines(fn.children, 1))
  lines[#lines + 1] = "end"
  return table.concat(lines, "\n")
end

local function tableExpr(node)
  local parts = {}
  for i = 1, #node.children do
    local field = node.children[i]
    local value = field.children[#field.children]
    if field.kind == "name" then
      parts[i] = field.key.value .. " = " .. exprAt(value, 0)
    elseif field.kind == "key" then
      parts[i] = "[" .. exprAt(field.key, 0) .. "] = " .. exprAt(value, 0)
    else
      parts[i] = exprAt(value, 0)
    end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function ifExpr(node)
  local parts = {}
  local branches = node.branches or {}
  for i = 1, #branches do
    local branch = branches[i]
    local lead = (i == 1) and "if " or "elseif "
    parts[#parts + 1] = lead .. exprAt(node.children[branch.cond], 0) ..
      " then " .. exprAt(node.children[branch.value], 0)
  end
  parts[#parts + 1] = "else " .. exprAt(node.children[node.elseIndex], 0)
  return "(" .. table.concat(parts, " ") .. ")"
end

local function isPrefix(node)
  local t = node.type
  return t == "Name" or t == "Index" or t == "Call" or t == "Parenthesized"
end

local function prefixText(node)
  if isPrefix(node) then return exprAt(node, 0) end
  return "(" .. exprAt(node, 0) .. ")"
end

local function suffix(node)
  local t = node.type
  if t == "Name" then return node.value end
  if t == "Number" then return numberText(node) end
  if t == "String" then return quote(node.value) end
  if t == "Boolean" then return node.value and "true" or "false" end
  if t == "Nil" then return "nil" end
  if t == "Vararg" then return "..." end
  if t == "Table" then return tableExpr(node) end
  if t == "Function" then return functionExpr(node) end
  if t == "IfExpression" then return ifExpr(node) end
  if t == "Index" then
    local obj = prefixText(node.children[1])
    local key = node.children[2]
    if node.dot and key.type == "String" then
      return obj .. "." .. key.value
    end
    return obj .. "[" .. exprAt(key, 0) .. "]"
  end
  if t == "Call" then
    local fn = prefixText(node.children[1])
    local args = {}
    if node.method then
      for i = 2, #node.children do args[#args + 1] = exprAt(node.children[i], 0) end
      return fn .. ":" .. node.method .. "(" .. table.concat(args, ", ") .. ")"
    end
    for i = 2, #node.children do args[#args + 1] = exprAt(node.children[i], 0) end
    return fn .. "(" .. table.concat(args, ", ") .. ")"
  end
  error("emit: unsupported expression node '" .. tostring(t) .. "'")
end

exprAt = function(node, limit)
  local t = node.type
  if t == "BinaryOp" then
    local p = PREC[node.op] or 0
    local leftLimit = RIGHT_ASSOC[node.op] and (p + 1) or p
    local rightLimit = RIGHT_ASSOC[node.op] and p or (p + 1)
    local text = exprAt(node.children[1], leftLimit) .. " " .. node.op .. " " ..
      exprAt(node.children[2], rightLimit)
    if p < limit then return "(" .. text .. ")" end
    return text
  end
  if t == "UnaryOp" then
    -- The space after '-' keeps `- -x` from collapsing into a `--` comment.
    local gap = (node.op == "not" or node.op == "-") and " " or ""
    local text = node.op .. gap .. exprAt(node.children[1], UNARY_PREC)
    if UNARY_PREC < limit then return "(" .. text .. ")" end
    return text
  end
  if t == "Parenthesized" then
    return "(" .. exprAt(node.children[1], 0) .. ")"
  end
  return suffix(node)
end

local function stmtLines(node, level)
  local pad = indentText(level)
  local t = node.type
  if t == "Local" then
    local names = {}
    for i = 1, #(node.names or {}) do
      local name = node.names[i]
      local attr = node.attrs and node.attrs[i]
      if attr then name = name .. " <" .. attr .. ">" end
      names[i] = name
    end
    local text = pad .. "local " .. table.concat(names, ", ")
    if #node.children > 0 then
      local values = {}
      for i = 1, #node.children do values[i] = exprAt(node.children[i], 0) end
      text = text .. " = " .. table.concat(values, ", ")
    end
    return { text }
  end
  if t == "Assign" then
    local targetCount = node.targetCount or 0
    local left, right = {}, {}
    for i = 1, targetCount do left[i] = exprAt(node.children[i], 0) end
    for i = targetCount + 1, #node.children do
      right[#right + 1] = exprAt(node.children[i], 0)
    end
    return { pad .. table.concat(left, ", ") .. " = " .. table.concat(right, ", ") }
  end
  if t == "CallStatement" then
    return { pad .. exprAt(node.children[1], 0) }
  end
  if t == "Do" then
    local lines = { pad .. "do" }
    appendAll(lines, blockLines(node.children, level + 1))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "While" then
    local lines = { pad .. "while " .. exprAt(node.children[1], 0) .. " do" }
    appendAll(lines, blockLines(node.children, level + 1, 2))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "Repeat" then
    local lines = { pad .. "repeat" }
    appendAll(lines, blockLines(node.children, level + 1, 1, #node.children - 1))
    lines[#lines + 1] = pad .. "until " .. exprAt(node.children[#node.children], 0)
    return lines
  end
  if t == "If" then
    local lines = {}
    local index = 1
    local branches = node.branches or {}
    for i = 1, #branches do
      local branch = branches[i]
      local lead = (i == 1) and "if " or "elseif "
      lines[#lines + 1] = pad .. lead .. exprAt(node.children[index], 0) .. " then"
      appendAll(lines, blockLines(node.children, level + 1, index + 1, index + branch.count))
      index = index + 1 + branch.count
    end
    if (node.elseCount or 0) > 0 then
      lines[#lines + 1] = pad .. "else"
      appendAll(lines, blockLines(node.children, level + 1, index, index + node.elseCount - 1))
    end
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "NumericFor" then
    local bounds = { exprAt(node.children[1], 0), exprAt(node.children[2], 0) }
    local start = 3
    if node.hasStep then
      bounds[3] = exprAt(node.children[3], 0)
      start = 4
    end
    local lines = { pad .. "for " .. node.var .. " = " .. table.concat(bounds, ", ") .. " do" }
    appendAll(lines, blockLines(node.children, level + 1, start, #node.children))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "GenericFor" then
    local exprCount = node.exprCount or 0
    local values = {}
    for i = 1, exprCount do values[i] = exprAt(node.children[i], 0) end
    local lines = { pad .. "for " .. table.concat(node.names or {}, ", ") ..
      " in " .. table.concat(values, ", ") .. " do" }
    appendAll(lines, blockLines(node.children, level + 1, exprCount + 1, #node.children))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "FunctionDeclaration" then
    local fn = node.children[2]
    local lines = { pad .. "function " .. exprAt(node.children[1], 0) ..
      "(" .. paramText(fn) .. ")" }
    appendAll(lines, blockLines(fn.children, level + 1))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "LocalFunction" then
    local fn = node.children[1]
    local lines = { pad .. "local function " .. node.name .. "(" .. paramText(fn) .. ")" }
    appendAll(lines, blockLines(fn.children, level + 1))
    lines[#lines + 1] = pad .. "end"
    return lines
  end
  if t == "Return" then
    if #node.children == 0 then return { pad .. "return" } end
    local values = {}
    for i = 1, #node.children do values[i] = exprAt(node.children[i], 0) end
    return { pad .. "return " .. table.concat(values, ", ") }
  end
  if t == "Break" then return { pad .. "break" } end
  if t == "Continue" then return { pad .. "continue" } end
  if t == "Goto" then return { pad .. "goto " .. node.name } end
  if t == "Label" then return { pad .. "::" .. node.name .. "::" } end
  error("emit: unsupported statement node '" .. tostring(t) .. "'")
end

blockLines = function(list, level, from, to)
  from = from or 1
  to = to or #list
  local lines = {}
  for i = from, to do
    if list[i] then appendAll(lines, stmtLines(list[i], level)) end
  end
  return lines
end

function Emit.source(ast)
  return table.concat(blockLines(ast.children, 0), "\n")
end

Emit.quote = quote
Emit.expr = function(node) return exprAt(node, 0) end

return Emit
