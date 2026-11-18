#!/usr/bin/env python3
"""Assemble the layer 12 web console into the root index.html.

Everything runs in the browser: wasmoon (Lua 5.4 compiled to wasm) plus every
v2 module is inlined as base64, so the page has no network dependencies.
"""

import base64
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
SRC = ROOT / "v2" / "src"
DIST = ROOT / ".tools" / "wasmoon" / "package" / "dist"

MODULES = [
    "src.ast",
    "src.lexer",
    "src.parser",
    "src.scope",
    "src.consts",
    "src.flatten",
    "src.opaque",
    "src.strings",
    "src.compiler",
    "src.vmgen",
    "src.selfmod",
    "src.bytecode",
    "src.split",
    "src.big",
    "src.antidebug",
    "src.integrity",
    "src.envlog",
    "src.tamper",
    "src.seal",
    "src.obfuscate",
    "src.autofix",
]

V1_ROOT = ROOT / "obfuscator" / "src"
V1_MODULES = [
    "util",
    "lexer",
    "parser",
    "resolver",
    "transforms",
    "strings",
    "compiler",
    "vmgen",
    "tamper",
]


def read_text(path):
    return path.read_text(encoding="utf-8")


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def main():
    template = read_text(WEB / "v3template.html")
    engine = read_text(DIST / "index.js")
    wasm_bytes = (DIST / "glue.wasm").read_bytes()
    driver = read_text(WEB / "v2driver.lua")
    worker = read_text(WEB / "v2worker.js")
    banner = base64.b64encode((WEB / "dc-banner.jpg").read_bytes()).decode("ascii")

    for label, text in (("engine", engine), ("worker", worker)):
        if "</script" in text.lower():
            sys.exit("inline %s source contains a closing script tag" % label)

    missing = [m for m in MODULES if not (SRC / (m.split(".", 1)[1] + ".lua")).is_file()]
    if missing:
        sys.exit("missing module source: " + ", ".join(missing))

    entries = []
    for name in MODULES:
        path = SRC / (name.split(".", 1)[1] + ".lua")
        entries.append('"%s": "%s"' % (name, b64(read_text(path))))
    # The compact engine shares module names with the VM pipeline, so its
    # internal requires are rewritten into the v1.* namespace on the way in.
    for name in V1_MODULES:
        path = V1_ROOT / (name + ".lua")
        if not path.is_file():
            sys.exit("missing compact module: " + str(path))
        text = read_text(path).replace('require("src.', 'require("v1.src.')
        entries.append('"%s": "%s"' % ("v1.src." + name, b64(text)))
    module_map = "{\n  " + ",\n  ".join(entries) + "\n}"

    html = template
    html = html.replace("/*__ENGINE__*/", engine)
    html = html.replace("/*__WASM__*/", '"%s"' % base64.b64encode(wasm_bytes).decode("ascii"))
    html = html.replace("/*__MODULES__*/", module_map)
    html = html.replace("/*__DRIVER__*/", '"%s"' % b64(driver))
    html = html.replace("/*__WORKER__*/", '"%s"' % b64(worker))
    html = html.replace("__DCART__", banner)

    for placeholder in ("__ENGINE__", "__WASM__", "__MODULES__",
                        "__DRIVER__", "__WORKER__", "__DCART__"):
        if placeholder in html:
            sys.exit("template placeholder left unfilled: " + placeholder)

    out = ROOT / "index.html"
    out.write_text(html, encoding="utf-8")
    print("wrote %s (%.1f KB)" % (out, out.stat().st_size / 1024.0))


if __name__ == "__main__":
    main()
