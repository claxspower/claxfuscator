#!/usr/bin/env python3
"""Assemble the self-contained index.html served by Cloudflare Pages.

Everything runs in the browser: fengari-web (Lua 5.3 in JS), the obfuscator
modules and the driver are inlined, so the page has no network dependencies.
"""

import base64
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
SRC = ROOT / "obfuscator" / "src"

MODULES = [
    "src.util",
    "src.lexer",
    "src.parser",
    "src.resolver",
    "src.transforms",
    "src.strings",
    "src.compiler",
    "src.vmgen",
]


def read_text(path):
    return path.read_text(encoding="utf-8")


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def main():
    template = read_text(WEB / "template.html")
    fengari = read_text(WEB / "fengari-web.js")
    driver = read_text(WEB / "driver.lua")

    if "</script" in fengari.lower():
        sys.exit("fengari-web.js contains a closing script tag; inline it via base64")

    missing = [m for m in MODULES if not (SRC / (m.split(".", 1)[1] + ".lua")).is_file()]
    if missing:
        sys.exit("missing module source: " + ", ".join(missing))

    entries = []
    for name in MODULES:
        path = SRC / (name.split(".", 1)[1] + ".lua")
        entries.append('"%s": "%s"' % (name, b64(read_text(path))))
    module_map = "{\n  " + ",\n  ".join(entries) + "\n}"

    html = template
    html = html.replace("/*__FENGARI__*/", fengari)
    html = html.replace("/*__MODULES__*/", module_map)
    html = html.replace("/*__DRIVER__*/", '"%s"' % b64(driver))

    if "__FENGARI__" in html or "__MODULES__" in html or "__DRIVER__" in html:
        sys.exit("template placeholder left unfilled")

    out = ROOT / "index.html"
    out.write_text(html, encoding="utf-8")
    print("wrote %s (%.1f KB)" % (out, out.stat().st_size / 1024.0))


if __name__ == "__main__":
    main()
