#!/usr/bin/env python3
"""Cross-runtime verification suite for the obfuscator.

Each case is executed twice -- once straight from source and once after
obfuscation -- on every interpreter that supports it, and the stdout of both
runs must match exactly.

    python tests/run.py
    python tests/run.py --lua /path/to/lua --luau /path/to/luau --keep

The suite also covers parser error recovery, build determinism and leakage of
source identifiers / string literals into the generated file.
"""

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / "tests" / "cases"
ERRORS = ROOT / "tests" / "errors"


# ---------------------------------------------------------------------------
# interpreters
# ---------------------------------------------------------------------------
class LupaRuntime:
    def __init__(self, flavor):
        self.flavor = flavor
        ver = flavor[3:]
        self.label = "Lua " + ver[0] + "." + ver[1:]

    def run(self, path):
        mod = __import__("lupa." + self.flavor, fromlist=["LuaRuntime"])
        runtime = mod.LuaRuntime(unpack_returned_tuples=True)
        setup = (
            "__cap = {} "
            "print = function(...) "
            "  local t = {} "
            "  for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end "
            "  __cap[#__cap + 1] = table.concat(t, '\\t') "
            "end"
        )
        try:
            runtime.execute(setup)
            runtime.execute(Path(path).read_bytes())
            out = runtime.eval("table.concat(__cap, '\\n')")
            return 0, out or ""
        except Exception as exc:  # lupa.LuaError
            return 1, str(exc)


class SubprocessRuntime:
    def __init__(self, label, exe):
        self.label = label
        self.exe = str(exe)

    def run(self, path):
        proc = subprocess.run(
            [self.exe, str(path)], capture_output=True, text=True, timeout=120
        )
        out = proc.stdout
        if proc.returncode != 0 and proc.stderr:
            out += "\n[stderr] " + proc.stderr.strip()
        return proc.returncode, out


def find_native_lua(override):
    candidates = [override, shutil.which("lua"),
                  r"C:/Users/user/AppData/Local/Programs/Lua/bin/lua.exe"]
    for cand in candidates:
        if cand and Path(cand).exists():
            return str(cand)
    return None


def build_runtimes(args):
    runtimes = [LupaRuntime(f) for f in ("lua51", "lua52", "lua53", "lua54")]
    lua54 = find_native_lua(args.lua)
    if lua54:
        runtimes.insert(0, SubprocessRuntime("Lua 5.4 (native)", lua54))
    else:
        print("note: native lua not found; skipping the native 5.4 runtime")
    luau = args.luau or (ROOT.parent / ".tools" / "luau.exe")
    if Path(luau).exists():
        runtimes.append(SubprocessRuntime("Luau", luau))
    else:
        print("note: luau not found; skipping the Luau runtime")
    return runtimes, lua54


# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------
ALL = {"5.1", "5.2", "5.3", "5.4", "luau"}
CASES_LIST = [
    {"name": "core", "file": "core.lua", "seed": 424242, "runtimes": ALL},
    {"name": "core-s3", "file": "core.lua", "seed": 2024, "strength": 3, "runtimes": ALL},
    {"name": "goto", "file": "goto.lua", "seed": 555, "runtimes": {"5.2", "5.3", "5.4"}},
    {"name": "bitwise", "file": "bitwise.lua", "seed": 888, "runtimes": {"5.3", "5.4"}},
    {"name": "luau", "file": "luau.lua", "seed": 777, "runtimes": {"luau"}},
]


def runtime_key(rt):
    if isinstance(rt, LupaRuntime):
        ver = rt.flavor[3:]
        return ver[0] + "." + ver[1:]
    if rt.label == "Luau":
        return "luau"
    return "5.4"


def obfuscate(lua, source, output, seed, extra=()):
    cmd = [lua, str(ROOT / "obfuscator.lua"), str(source), str(output),
           "--seed", str(seed), "--quiet", *extra]
    return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, timeout=300)


def compare(name, runtime, expected_rc, expected_out, actual_rc, actual_out):
    if actual_rc != expected_rc:
        return "%s: exit code %d, expected %d" % (runtime.label, actual_rc, expected_rc)
    if actual_out.strip() != expected_out.strip():
        return ("%s: output mismatch\n  expected: %r\n  actual  : %r"
                % (runtime.label, expected_out.strip(), actual_out.strip()))
    return None


def check_symbol_leak(name, obf_path, banned):
    text = Path(obf_path).read_text(errors="replace")
    found = [needle for needle in banned if needle in text]
    if found:
        return "%s: source symbols leaked into output: %s" % (name, ", ".join(found))
    return None


# ---------------------------------------------------------------------------
# extra checks
# ---------------------------------------------------------------------------
def check_error_recovery(lua, runtime, tmp):
    src = ERRORS / "multi.lua"
    out = tmp / "multi.ob.lua"
    if out.exists():
        out.unlink()
    proc = obfuscate(lua, src, out, 9090)
    problems = []
    if proc.returncode != 2:
        problems.append("error run exited %d, expected 2" % proc.returncode)
    if out.exists():
        problems.append("output file was written despite syntax errors")
    diagnostics = re.findall(r"multi\.lua:\d+:\d+: ", proc.stderr)
    if len(diagnostics) < 2:
        problems.append("expected at least 2 diagnostics, got %d" % len(diagnostics))
    if proc.stderr.count("^") < 2:
        problems.append("expected a source caret for each diagnostic")
    if "error:" not in proc.stderr:
        problems.append("missing summary error line")

    allowed = obfuscate(lua, src, out, 9090, ("--allow-errors",))
    if allowed.returncode != 0:
        problems.append("--allow-errors exited %d, expected 0" % allowed.returncode)
    elif "warning:" not in allowed.stderr:
        problems.append("--allow-errors did not report a warning")
    elif not out.exists():
        problems.append("--allow-errors wrote no output")
    else:
        rc, text = runtime.run(out)
        if rc != 0 or text.strip() != "survivor":
            problems.append("recovered build did not run: rc=%d out=%r" % (rc, text))
    return problems


def check_determinism(lua, tmp):
    src = CASES / "core.lua"
    first, second, third = tmp / "det1.lua", tmp / "det2.lua", tmp / "det3.lua"
    problems = []
    for path in (first, second, third):
        if path.exists():
            path.unlink()
    obfuscate(lua, src, first, 1234)
    obfuscate(lua, src, second, 1234)
    obfuscate(lua, src, third, 1235)
    if not (first.exists() and second.exists() and third.exists()):
        return ["determinism: obfuscation failed"]
    a, b, c = (hashlib.sha256(p.read_bytes()).hexdigest() for p in (first, second, third))
    if a != b:
        problems.append("same seed produced different files")
    if a == c:
        problems.append("different seeds produced identical files")
    return problems


def check_single_file(lua, source, out_dir):
    out = out_dir / "single.ob.lua"
    proc = obfuscate(lua, source, out, 31337)
    if proc.returncode != 0:
        return ["single-file: obfuscation failed: " + proc.stderr.strip()]
    text = out.read_text(errors="replace")
    problems = []
    for needle in ("require(", "loadfile(", "dofile("):
        if needle in text:
            problems.append("single-file output contains " + needle)
    return problems


def compact_file(lua, source, output):
    script = r'''
local U = require("src.util")
local input = assert(io.open(arg[1], "rb"))
local code = U.compact(input:read("*a"))
input:close()
assert(not code:find("[\r\n\128-\255]"), "output is not one ASCII line")
local out = assert(io.open(arg[2], "wb"))
out:write(code)
out:close()
'''
    return subprocess.run(
        [lua, "-", str(source), str(output)], input=script,
        cwd=str(ROOT), capture_output=True, text=True, timeout=120,
    )


def check_packing(lua):
    script = r'''
local U = require("src.util")
local VMGen = require("src.vmgen")
local key = {0x03020100,0x07060504,0x0b0a0908,0x0f0e0d0c,
  0x13121110,0x17161514,0x1b1a1918,0x1f1e1d1c,0x09000000,0x4a000000,0}
local expected = {0xe4e7f110,0x15593bd1,0x1fdd0f50,0xc47120a3,
  0xc7f4d1c7,0x0368c033,0x9aaa2204,0x4e6cd4c3,0x466482d2,0x09aa9f07,
  0x05d7c214,0xa2028bd9,0xd19c12b5,0xb94e16de,0xe883d0cb,0x4e3c50a2}
local actual = VMGen.cipherBlock(key, 1)
for i = 1, 16 do assert(actual[i] == expected[i], "ChaCha20 word " .. i) end
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
local fixtures = {
  "return " .. U.quote(table.concat(bytes)),
  [=[-- comment
local a,b=4,1 return a - -b, .5 .. "x", 1 .. .25, "nul\0001", [[a
b]]]=],
  "local function f(...) return select('#',...),... end return f(1,nil,3,nil)",
  "return 0x1.8p+2, 1e-9, -0.0, (0/0), 1/0",
  'return 0xA .. "x", 0xff .. .5, 0x1p0 .. "z"',
}
local function pack(...) return {n=select('#',...),...} end
for i, source in ipairs(fixtures) do
  local code = U.compact(source)
  assert(not code:find("[\r\n\128-\255]"), "minifier shape " .. i)
  assert(U.compact(code) == code, "minifier idempotence " .. i)
  local original = pack(assert(load(source))())
  local result = pack(assert(load(code))())
  assert(original.n == result.n, "minifier return arity " .. i)
  for j = 1, original.n do
    local a,b = original[j],result[j]
    assert(type(a) == type(b) and (a == b or (a ~= a and b ~= b)), "minifier value " .. i .. "/" .. j)
    if type(a) == "number" and a == 0 then assert(1/a == 1/b, "minifier zero sign") end
  end
end
local Parser = require("src.parser")
local Transforms = require("src.transforms")
local Resolver = require("src.resolver")
local Compiler = require("src.compiler")
local marker = "private_constant_7D4BE981C2A6"
local constants = {987654321012345, -0.0, 1.0, math.huge, -math.huge, 0/0, false, true}
local raw = {protos={{params=0,vararg=false,updesc={},k=constants,code={}}}, strings={marker,table.concat(bytes)}}
for i = 1, #constants do raw.protos[1].code[i]={op="LOADK",a=i,b=i} end
raw.protos[1].code[#constants+1]={op="LOADSTR",a=#constants+1,b=1}
raw.protos[1].code[#constants+2]={op="LOADSTR",a=#constants+2,b=2}
raw.protos[1].code[#constants+3]={op="RETURN",a=1,b=#constants+2}
for seed = 1, 16 do
  U.seed(seed)
  local code = VMGen.generate(raw, {decoys=32})
  assert(not code:find(marker,1,true) and not code:find("987654321012345",1,true), "constant text leak")
  local got = pack(assert(load(code))())
  assert(got.n == #constants+2 and got[#constants+1] == marker and got[#constants+2] == table.concat(bytes), "encrypted values")
  for i,v in ipairs(constants) do
    assert(type(v)==type(got[i]) and (v==got[i] or (v~=v and got[i]~=got[i])), "constant " .. i)
    if type(v)=="number" then
      if v==0 then assert(1/v==1/got[i], "negative zero") end
      if math.type then assert(math.type(v)==math.type(got[i]), "numeric subtype") end
    end
  end
  local name = assert(code:match("local ([%w_]+)={}"))
  local start = assert(code:find("if " .. name .. ".h()~=",1,true))
  local function reject(edit)
    local changed = code:sub(1,start-1) .. edit .. "\n" .. code:sub(start)
    local fn = assert(load(changed))
    local ok,first = pcall(fn)
    -- Trips are silent by design (healthy executors must never see console
    -- errors), so a rejected chunk returns nothing instead of raising.
    assert(not ok or first == nil, "tamper not rejected: " .. tostring(first))
  end
  reject(name .. ".P[1].t[1]=" .. name .. ".P[1].t[1]+1")
  reject(name .. ".P[1].k[1]=" .. name .. ".P[1].k[1]+1")
  reject(name .. ".P[1].n=" .. name .. ".P[1].n+1")
  reject(name .. ".sk[1]=" .. name .. ".sk[1]+1")
  reject("for _,e in ipairs(" .. name .. ".S) do e[3]=e[3]+1 end")
  local dispatch = assert(code:find(name .. ".f=function",1,true))
  local altered = code:sub(1,dispatch-1) .. name .. ".i=function() return {-1,0,0,0,0} end\n" .. code:sub(dispatch)
  local ok,err = pcall(assert(load(altered)))
  assert(not ok and tostring(err):find("invalid bytecode opcode",1,true), "unknown opcode not rejected")
end
local badJump={protos={{code={{op="JMP",b=100}},k={},updesc={}}}}
local badJumpCode=VMGen.generate(badJump,{})
local okJump,errJump=pcall(assert(load(badJumpCode)))
assert(not okJump and tostring(errJump):find("invalid bytecode position",1,true), "invalid jump not rejected")
for _,operand in ipairs({2147483648,-2147483649,1.5,math.huge,0/0}) do
  local bad={protos={{code={{op="RETURN",a=operand,b=0}},k={},updesc={}}}}
  local ok,err=pcall(VMGen.generate,bad,{})
  assert(not ok and tostring(err):find("32-bit",1,true), "invalid operand accepted")
end
local smallest,largest = math.huge,0
for seed = 1, 64 do
  local code
  -- Same budget rule as the shipped driver: a density-3 pad can overshoot
  -- the 17 KB ceiling on a lucky roll, and the build replays the seed with a
  -- lighter pad instead of shipping an oversized artifact.
  for _,density in ipairs({3,1,0}) do
    U.seed(seed)
    local ast,errors = Parser.parse('print("h")', "tiny.lua")
    assert(#errors == 0)
    Transforms.deadcode(ast, {density=density})
    local compiled = Compiler.compile(Resolver.resolve(ast), {})
    code = U.compact(VMGen.generate(compiled, {seed=seed,decoys=32}))
    if #code <= 17000 then break end
  end
  assert(not code:find("[\r\n\128-\255]"), "seed output shape " .. seed)
  assert(code:match("^return%(function%([%a%d_,%.]+%)[%a][%a%d]*={};return%(function%(%.%.%."),
    "seed prefix " .. seed)
  local output = {}
  local env = setmetatable({print=function(x) output[#output+1]=x end}, {__index=_G})
  assert(load(code, "tiny", "t", env))()
  assert(#output == 1 and output[1] == "h", "seed output " .. seed)
  smallest,largest = math.min(smallest,#code),math.max(largest,#code)
  assert(#code >= 10000 and #code <= 17000, "tiny size " .. seed .. ": " .. #code)
end
print("PACKING_PASS seeds=64 bytes=" .. smallest .. ".." .. largest)
'''
    proc = subprocess.run(
        [lua, "-"], input=script, cwd=str(ROOT),
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0 or "PACKING_PASS" not in proc.stdout:
        return ["packing: " + (proc.stderr.strip() or proc.stdout.strip())]
    print(proc.stdout.strip())
    return []


# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua", help="native lua 5.4 executable")
    parser.add_argument("--luau", help="luau executable")
    parser.add_argument("--keep", action="store_true", help="keep generated files")
    args = parser.parse_args()

    runtimes, lua = build_runtimes(args)
    if not lua:
        print("fatal: no native Lua found; the obfuscator itself needs Lua to run")
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="obf-tests-"))
    failures = []
    results = {}

    for case in CASES_LIST:
        source = CASES / case["file"]
        obf = tmp / (case["name"] + ".ob.lua")
        extra = ()
        if case.get("strength"):
            extra = ("--strength", str(case["strength"]))
        proc = obfuscate(lua, source, obf, case["seed"], extra)
        if proc.returncode != 0 or not obf.exists():
            failures.append("%s: obfuscation failed: %s" % (case["name"], proc.stderr.strip()))
            results[case["name"]] = {}
            continue
        if proc.stderr.strip():
            failures.append("%s: unexpected warnings: %s" % (case["name"], proc.stderr.strip()))
        results[case["name"]] = {}
        minified = tmp / (case["name"] + ".min.lua")
        packed = compact_file(lua, obf, minified)
        if packed.returncode != 0:
            failures.append("%s: minification failed: %s" % (case["name"], packed.stderr.strip()))
            continue
        for runtime in runtimes:
            key = runtime_key(runtime)
            if key not in case["runtimes"]:
                continue
            base_rc, base_out = runtime.run(source)
            sub_rc, sub_out = runtime.run(obf)
            problem = compare(case["name"], runtime, base_rc, base_out, sub_rc, sub_out)
            min_rc, min_out = runtime.run(minified)
            min_problem = compare(case["name"], runtime, base_rc, base_out, min_rc, min_out)
            if min_problem:
                problem = (problem + "; " if problem else "") + "minified: " + min_problem
            results[case["name"]][runtime.label] = "FAIL" if problem else "PASS"
            if problem:
                failures.append("%s: %s" % (case["name"], problem))

    banned = ["Core feature coverage", "Hello, Lua!", "Derived", "counter",
              "fact", "makeCounter", "range"]
    leak = check_symbol_leak("core", tmp / "core.ob.lua", banned)
    if leak:
        failures.append(leak)

    checks = {
        "error-recovery": check_error_recovery(lua, runtimes[0], tmp),
        "determinism": check_determinism(lua, tmp),
        "single-file": check_single_file(lua, CASES / "core.lua", tmp),
        "packing": check_packing(lua),
    }
    for problems in checks.values():
        failures.extend(problems)

    print("\nCross-runtime matrix")
    ordered = [rt.label for rt in runtimes]
    for case in CASES_LIST:
        row = results.get(case["name"], {})
        cells = ["%s=%s" % (rt, row.get(rt, "-")) for rt in ordered if rt in row]
        print("  %-8s %s" % (case["name"], "  ".join(cells)))

    print("\nBuild checks")
    for name, problems in checks.items():
        print("  %-14s %s" % (name, "FAIL" if problems else "PASS"))

    if failures:
        print("\nFailures")
        for item in failures:
            print("  - " + item)
        print("\nFAILED (%d problem(s)); artifacts in %s" % (len(failures), tmp))
        return 1

    if not args.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
