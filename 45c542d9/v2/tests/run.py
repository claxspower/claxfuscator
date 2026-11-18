#!/usr/bin/env python3
"""Run the v2 module acceptance tests on every available PUC Lua host.

    python v2/tests/run.py
    python v2/tests/run.py --module 1
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class LupaRuntime:
    def __init__(self, flavor):
        self.flavor = flavor
        self.label = "Lua " + flavor[3] + "." + flavor[4:]

    def run(self, test_path):
        module = __import__("lupa." + self.flavor, fromlist=["LuaRuntime"])
        runtime = module.LuaRuntime(unpack_returned_tuples=True)
        setup = (
            "__out = {} "
            "print = function(...) "
            "  local t = {} "
            "  for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end "
            "  __out[#__out + 1] = table.concat(t, '\\t') "
            "end"
        )
        root = str(ROOT).replace("\\", "/")
        os.chdir(str(ROOT))
        runtime.execute(setup)
        runtime.execute(
            'package.path = "%s/?.lua;%s/src/?.lua;" .. package.path'
            % (root, root)
        )
        try:
            runtime.execute(test_path.read_text(encoding="utf-8"))
        except Exception as exc:
            captured = runtime.eval("table.concat(__out, '\\n')") or ""
            return 1, str(exc) + "\n" + str(captured)
        return 0, runtime.eval("table.concat(__out, '\\n')") or ""


class SubprocessRuntime:
    def __init__(self, label, exe):
        self.label = label
        self.exe = str(exe)

    def run(self, test_path):
        env = dict(**__import__("os").environ)
        root = str(ROOT).replace("\\", "/")
        env["LUA_PATH"] = "%s/?.lua;%s/src/?.lua;;" % (root, root)
        proc = subprocess.run(
            [self.exe, str(test_path)], cwd=str(ROOT), env=env,
            capture_output=True, text=True, timeout=120,
        )
        out = proc.stdout
        if proc.returncode != 0:
            out += "\n[stderr] " + proc.stderr.strip()
        return proc.returncode, out


def find_native():
    candidates = [
        shutil.which("lua"),
        r"C:/Users/user/AppData/Local/Programs/Lua/bin/lua.exe",
    ]
    for cand in candidates:
        if cand and Path(cand).exists():
            return cand
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", type=int, default=1)
    args = parser.parse_args()

    test_path = ROOT / "tests" / ("module%d.lua" % args.module)
    if not test_path.is_file():
        sys.exit("missing test: %s" % test_path)

    runtimes = [LupaRuntime(f) for f in ("lua51", "lua52", "lua53", "lua54")]
    native = find_native()
    if native:
        runtimes.insert(0, SubprocessRuntime("Lua 5.4 (native)", native))

    print("v2 MODULE %d" % args.module)
    marker = "MODULE%d_RESULT PASS" % args.module
    prefix = "MODULE%d_" % args.module
    all_ok = True
    for runtime in runtimes:
        code, out = runtime.run(test_path)
        ok = code == 0 and marker in out
        all_ok = all_ok and ok
        status = "PASS" if ok else "FAIL"
        print("  %-20s %s" % (runtime.label, status))
        if not ok:
            interesting = [
                line for line in out.splitlines()
                if line.startswith("FAIL") or line.startswith(prefix)
            ]
            if not interesting:
                interesting = [line for line in out.splitlines() if line.strip()][-15:]
            for line in interesting:
                print("    " + line)
    print("MODULE %d: %s" % (args.module, "PASS" if all_ok else "FAIL"))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
