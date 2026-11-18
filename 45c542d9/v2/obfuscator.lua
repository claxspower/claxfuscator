#!/usr/bin/env lua
-- obfuscator.lua -- CLI entry point for the layer 12 pipeline.
--
--   lua v2/obfuscator.lua input.lua                    -> input.obf.lua
--   lua v2/obfuscator.lua input.lua out.lua --auto-fix
--   lua v2/obfuscator.lua --help
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/src/?.lua;" .. package.path

local Cli = require("src.cli")
os.exit(Cli.main(arg or {}))
