-- envlog.lua -- layer 13: dump-environment detection and a local attempt log.
--
-- Pipeline position:
--   vmgen.emit(plan, { antidebug = cfg })   (needs the layer 11 names)
--
-- A file that has been unpacked by a dump bot or a deobfuscation website is
-- usually re-run somewhere else, and those tools keep their own header on the
-- first lines ("Dumped By ...", "deobfuscated with ...", "Dex Environment Log
-- End"). Four read-only signals are collected at load, each inside one
-- swallow-all pcall:
--
--   banner  the chunk name, or the first bytes of the loaded source, carry a
--           dump/deobfuscation marker (matched case-insensitively). Only
--           short_src and the 256-byte prefix are scanned, so a constant pool
--           that happens to hold the word "unpack" can never trip it; the scan
--           text is assembled from byte-code literals, so no keyword is
--           grep-able in the output.
--
-- Every environment name, keyword and log anchor this layer emits is
-- scrambled per build: the text is shifted by a random key (1-255), stored as
-- hex, and rebuilt at load time by a `gsub("%x%x", ...)` pass over the hex
-- with a function replacement. A byte-code scanner no longer sees the
-- keyword's ASCII values either; it sees a hex blob whose decode key lives in
-- the same emitted chunk.
--   web     window/document/navigator/WebAssembly/js exist in the chunk
--           environment: a browser-side Lua host (Fengari/wasmoon page).
--   bot     process/globalThis exist: a server-side Lua host (Node bot).
--   trace   the core C libraries were replaced by Lua closures. A runtime
--           tracer (Dex-style environment log) has to route globals through
--           its own wrappers; three or more present core functions answering
--           no "C" at all is that shape, while every real host keeps them C.
--
-- A banner always trips. A web/bot host trips only when the environment shows
-- no Roblox marker and no executor API, so a healthy executor session and the
-- build-time sandbox (which presents the getgenv marker) stay clean. A trace
-- fingerprint always trips. The trip action is the layer 11 one: the shared
-- ADT flag, so the runtime constants deviate silently instead of the chunk
-- dying with an easy-to-patch error.
--
-- Logger: on a confirmed detection the flags, the matched keyword id, the
-- executor name (when one exposes it) and a short sanitized excerpt of the
-- source name are appended to `clax_env.log` through appendfile/writefile if
-- the host has one. Nothing leaves the machine: there is no network call and
-- no webhook. Hosts without a filesystem API simply keep no record.
local Envlog = {}

Envlog.KEYWORDS = {
  "dumped", "dump by", "deobf", "unluac", "luadec", "decompil",
  "decrypt", "lua.deobfuscate", "dex utility", "dexplorer",
  "dex env", "environment log",
}
Envlog.WEB_KEYS = { "window", "document", "navigator", "WebAssembly", "js" }
Envlog.BOT_KEYS = { "process", "globalThis" }
Envlog.ROBLOX_KEYS = { "game", "Instance", "typeof", "workspace" }
Envlog.LOG_FILE = "clax_env.log"
Envlog.SCAN = 256

function Envlog.plan(opts)
  opts = opts or {}
  local seed = tonumber(opts.seed) or 0
  return {
    keywords = Envlog.KEYWORDS,
    web = Envlog.WEB_KEYS,
    bot = Envlog.BOT_KEYS,
    roblox = Envlog.ROBLOX_KEYS,
    logFile = opts.logFile or Envlog.LOG_FILE,
    scan = math.floor(tonumber(opts.scan) or Envlog.SCAN),
    -- Deterministic per build, different on every seed; the hex blobs in the
    -- emitted file are meaningless without it.
    key = (seed * 1103515245 + 12345) % 255 + 1,
  }
end

local function codes(text)
  local out = {}
  for i = 1, #text do out[i] = string.byte(text, i) end
  return table.concat(out, ",")
end

-- Runtime keys are all decoded from hex blobs, so the emitted file carries no
-- readable "getinfo", "short_src", "dumped" or "appendfile" anchor for a
-- patcher: not as text, and not as a plain byte-code list either.
function Envlog.prologue(names, cfg)
  local E = names.E
  local TY = names.G4 or "type"
  local PC = names.G3 or "pcall"
  local ADT = names.ADT or "ADT"
  local ADE = names.ADE or "0"
  local DM = names.DM
  local KEY = math.floor(tonumber(cfg.key) or 1) % 255
  if KEY < 1 then KEY = 1 end
  local function hex(text)
    local out = {}
    for i = 1, #text do
      out[i] = string.format("%02x", (string.byte(text, i) + KEY) % 256)
    end
    return table.concat(out)
  end
  local function K(text) return "__d(" .. string.format("%q", hex(text)) .. ")" end
  local D = names.ADB or (E .. "[" .. K("debug") .. "]")
  -- The layer 11 snapshot keeps getinfo (Plain Lua) only, so the Luau
  -- fallback reads debug.info from the live table instead.
  local DE = E .. "[" .. K("debug") .. "]"
  local GI = names.AGI or (D .. "[" .. K("getinfo") .. "]")
  local S = names.ADS or (E .. "[" .. K("string") .. "]")
  local ADX = names.ADX or "function() return 1 end"
  local scan = math.floor(tonumber(cfg.scan) or Envlog.SCAN)
  local logFile = K(cfg.logFile or Envlog.LOG_FILE)

  local function presence(keys)
    local parts = {}
    for i = 1, #keys do
      local v = "E[" .. K(keys[i]) .. "]"
      parts[i] = "(" .. TY .. "(" .. v .. ")==\"table\" or " .. TY .. "(" ..
        v .. ")==\"function\" or " .. TY .. "(" .. v .. ")==\"userdata\")"
    end
    return "(" .. table.concat(parts, " or ") .. ")"
  end
  local function defined(keys)
    local parts = {}
    for i = 1, #keys do
      parts[i] = "E[" .. K(keys[i]) .. "]~=nil"
    end
    return "(" .. table.concat(parts, " or ") .. ")"
  end
  local kwParts = {}
  for i = 1, #cfg.keywords do kwParts[i] = K(cfg.keywords[i]) end

  -- Load-time pass. EL packs banner (x8) | web (x1) | bot (x2) | roblox (x4).
  -- EX keeps the scanned text for the logger, BN the matched keyword id.
  -- Plain Lua reads the chunk name through getinfo(n, "S"); Luau has only
  -- debug.info(level, "s"), so that string form is the fallback there.
  -- Decoder shared by every literal below. It resolves string.char/gsub and
  -- tonumber from the live environment once per call, so the layer needs a
  -- single chunk-local name (`__d`, with underscores generated names never
  -- carry) and no extra register pressure. A host without string.gsub simply
  -- yields empty literals; the scan then has nothing to match.
  local dec =
    "local __d=function(h) local s=" .. E .. "[" .. DM .. "(" ..
      codes("string") .. ")] " ..
    "local c=s and s[" .. DM .. "(" .. codes("char") .. ")] " ..
    "local g=s and s[" .. DM .. "(" .. codes("gsub") .. ")] " ..
    "local t=" .. E .. "[" .. DM .. "(" .. codes("tonumber") .. ")] " ..
    "if not (c and g and t) then return \"\" end " ..
    "return (g(h,\"%x%x\",function(x) return c((t(x,16)-" .. KEY ..
      ")%256) end)) end"

  local lines = {
    dec,
    "local EL=0 local EX=\"\" local BN=0 local HT=0 local ID=0 " ..
      PC .. "(function() local E=" .. E .. " local TY=" .. TY ..
      " local D=" .. D .. " local S=" .. S ..
      " local SF=S and S[" .. K("find") .. "] local US=S and S[" ..
      K("sub") .. "] " ..
      "local WK=" .. presence(cfg.web) .. " and 1 or 0 " ..
      "local BK=" .. presence(cfg.bot) .. " and 1 or 0 " ..
      "local RB=" .. defined(cfg.roblox) .. " and 1 or 0 local tx=\"\" " ..
      "if D and TY(D[" .. GI .. "])==\"function\" then " ..
      "local ok,a=" .. PC .. "(D[" .. GI .. "]," .. ADX .. ",\"S\") " ..
      "if ok and TY(a)==\"table\" then local ss=a[" .. K("short_src") ..
      "] local sc=a[" .. K("source") .. "] " ..
      "if TY(ss)==\"string\" then tx=ss end " ..
      "if TY(sc)==\"string\" and TY(US)==\"function\" then tx=tx..\" \"..US(sc,1," ..
      scan .. ") end end " ..
      "elseif " .. DE .. " and TY(" .. DE .. "[" .. K("info") ..
      "])==\"function\" then " ..
      "local ok,ss=" .. PC .. "(" .. DE .. "[" .. K("info") .. "],2,\"s\") " ..
      "if ok and TY(ss)==\"string\" then tx=ss end end " ..
      "local SL=S and S[" .. K("lower") .. "] " ..
      "if TY(SL)==\"function\" and TY(tx)==\"string\" then tx=SL(tx) end " ..
      "EX=tx if TY(SF)==\"function\" and #tx>0 then local KV={" ..
      table.concat(kwParts, ",") .. "} " ..
      "for i=1,#KV do if SF(tx,KV[i],1,true) then BN=i end end end " ..
      -- Instrumentation probe: a tracer that logs calls has to route the core
      -- libraries through Lua closures in the chunk environment. Three or more
      -- present functions and not one "C" answer is that shape; a healthy host
      -- (even an executor) keeps the real C library.
      "local IQ=D and D[" .. GI .. "] local MO=0 " ..
      "if TY(IQ)==\"function\" then MO=1 elseif " .. DE .. " and TY(" .. DE ..
      "[" .. K("info") .. "])==\"function\" then IQ=" .. DE .. "[" .. K("info") ..
      "] MO=2 end " ..
      "local FN={S and S[" .. K("format") .. "],S and S[" .. K("byte") .. "]," ..
      E .. "[" .. K("table") .. "] and " .. E .. "[" .. K("table") .. "][" ..
      K("concat") .. "]," .. E .. "[" .. K("math") .. "] and " .. E ..
      "[" .. K("math") .. "][" .. K("floor") .. "]} " ..
      "local TV=0 local TC=0 local TA=0 " ..
      "if MO>0 then for i=1,4 do local f=FN[i] if TY(f)==\"function\" then TV=TV+1 " ..
      "if MO==1 then local o,a=" .. PC .. "(IQ,f,\"S\") " ..
      "if o then TA=TA+1 if TY(a)==\"table\" and a[" .. K("what") .. "]==\"C\" then TC=TC+1 end end " ..
      "else local o,a=" .. PC .. "(IQ,f,\"s\") " ..
      "if o then TA=TA+1 if a==\"[C]\" or a==\"=[C]\" then TC=TC+1 end end end end end end " ..
      "local TR=0 if TA>=3 and TC==0 then TR=1 end " ..
      -- Identity probe: recorded for the local log only. A run thread at
      -- identity 8 is normal on several healthy executors, so it must never
      -- deviate the session: a false trip used to garble the first prints
      -- before the restore path re-ran the chunk.
      "local GFn=E[" .. K("getidentity") .. "] or E[" .. K("getthreadidentity") ..
      "] " ..
      "if TY(GFn)==\"function\" then local o,v=" .. PC .. "(GFn) " ..
      "if o and TY(v)==\"number\" and v>=8 then ID=1 end end " ..
      "EL=BN*8+WK+BK*2+RB*4 end)",
  }
  -- Trip: a banner is unconditional; a web/bot host only when it looks like
  -- neither Roblox nor an executor. The identity and tracer probes are log
  -- facts only: several healthy executors run at identity 8 or route the core
  -- libraries through closures, and a false positive garbles the program's own
  -- first prints (the restore path then re-runs clean, leaving both in the
  -- console). HT keeps the logger off every other path.
  -- A trip also raises the anti-tamper notice: on a real client the notice
  -- disconnects, elsewhere the helper is a no-op and the session just
  -- deviates. Healthy executor sessions never reach this branch.
  local kick = names.KK and (names.KK .. "() ") or ""
  lines[#lines + 1] =
    "local HF=EL%8 if EL-HF>=8 or " ..
    "(HF%4~=0 and HF<4 and " .. ADE .. "==0) then " .. ADT .. "=1 HT=1 " ..
    kick .. "end"
  -- Local attempt log. Everything is pcall-guarded; a host without the
  -- filesystem API or with a proxy that raises one of these reads stays silent.
  local logLine = K("clax-env ") .. "..tm..\" f=\"..EL..\" k=\"..BN.." ..
    "\" id=\"..ID..\" x=\"..nm..\" src=\"..tx..\"\\n\""
  lines[#lines + 1] =
    PC .. "(function() if HT==0 then return end local E=" .. E .. " local TY=" ..
    TY .. " local W=E[" .. K("appendfile") .. "] or E[" .. K("writefile") ..
    "] if TY(W)~=\"function\" then return end " ..
    "local S=E[" .. K("string") .. "] local GG=S and S[" .. K("gsub") .. "] " ..
    "local OS=E[" .. K("os") .. "] local TT=OS and OS[" .. K("time") .. "] " ..
    "local tm=\"\" if TY(TT)==\"function\" then local o,v=" .. PC ..
    "(TT) if o then tm=v end end " ..
    "local IE=E[" .. K("identifyexecutor") .. "] or E[" .. K("getexecutorname") ..
    "] local nm=\"\" if TY(IE)==\"function\" then local o,v=" .. PC ..
    "(IE) if o and TY(v)==\"string\" then nm=v end end " ..
    "local tx=EX if TY(GG)==\"function\" and TY(tx)==\"string\" then tx=GG(tx,\"[%c]\",\"?\") end " ..
    PC .. "(W," .. logFile .. "," .. logLine .. ") end)"
  return lines
end

return Envlog
