# Clax VM Obfuscator

A self-contained Lua obfuscator: source is parsed into an AST, renamed and
transformed, compiled to a custom register bytecode, encrypted, and emitted as
a single dependency-free Lua file that runs the payload inside a generated
virtual machine.

Supported hosts: Lua 5.1, 5.2, 5.3, 5.4 and Luau (Roblox). The output file is
deliberately written in the Lua 5.1 subset, so one build runs on every host.

```
input.lua -> lexer -> parser -> dead-code/MBA -> resolver -> bytecode -> VMGen -> output.lua
             (recovery)  (AST)     (AST)          (_0x names)  (55 opcodes) (one file)
```

## Usage

```bash
lua obfuscator.lua input.lua output.lua
lua obfuscator.lua input.lua output.lua --seed 12345 --strength 3
lua obfuscator.lua input.lua output.lua --seed 12345 --quiet
```

| Option | Meaning |
| --- | --- |
| `--seed N` | Deterministic build seed (opcode map, string keys, junk code). |
| `--strength N` | Protection level `1` (default), `2` or `3`: scales junk density and decoy opcodes (12 / 24 / 40). |
| `--no-deadcode` | Disable unreachable-block injection. |
| `--allow-errors` | Emit a best-effort build from the part of the AST that parsed. |
| `--quiet` | Suppress the statistics banner. |
| `-h`, `--help` | Show usage. |

Valid input produces no warnings. Syntax errors are reported as
`file:line:col: message` with the offending source line and a caret; they never
crash the front-end. Without `--allow-errors` the run exits with status `2` and
writes no output. A failed emitter self-check is written to
`<output>.invalid.lua` for inspection instead of a broken output file.

## Layers

### 1. Front-end (`src/lexer.lua`, `src/parser.lua`)
- Hand-written lexer plus recursive-descent / Pratt parser.
- Lua 5.1-5.4: labels/goto, numeric and generic `for`, varargs, method syntax,
  long strings/comments, hex floats, all operators.
- Luau: type aliases and generics, typed parameters/returns, `continue`,
  compound assignment, string interpolation, if-expressions, `::` assertions.
- Recovery: every statement is parsed under `pcall`; on failure the error is
  recorded and the token stream is synchronized to the next statement boundary.

### 2. AST transforms (`src/transforms.lua`)
- Dead-code injection: never-true guard branches containing generated locals,
  a fake closure, a side-effect-free assignment and an unreachable loop. Junk
  blocks reference only generated names, so they cannot change behavior.
- Constant hiding: integer literals are rewritten with MBA-style arithmetic
  identities (`(n+b)-b`, `a*b+c`, nested sums) during serialization.

### 3. Scope resolution (`src/resolver.lua`)
- Lexical scopes, shadowing, per-iteration capture, label resolution and
  goto validation.
- Captured locals are compiled to one-element cells, so closures share the
  variable exactly like real upvalues.
- Every binding gets a generated `_0x...` name; originals are gone from the
  output.

### 4. Bytecode compiler (`src/compiler.lua`)
- Register/stack hybrid ISA with 55 logical opcodes.
- Exact Lua multi-value semantics: call/vararg expansion, assignment padding,
  `select`, multiple returns, generic-for state preservation.
- Metamethod-preserving operators (`ADD`, `EQ`, `LT`, ...), `SELF`, table
  constructors with `SETLIST`, numeric/generic loops, closures and upvalue
  descriptors (`{stack, slot}` / `{outer, index}`).
- Real Lua closures wrap VM entry points, so coroutines, `type(f) ==
  "function"`, `pcall` and recursion behave normally.

### 5. VM generation (`src/vmgen.lua`)
- Opcode numbers are a random permutation of 55 real + 12/24/40 decoy opcodes
  per build (`--strength`); the dispatcher order is shuffled independently.
- Upvalues are one-element tables, matching the compiler's cell model.
- 53-bit arithmetic bitwise emulation (no host bitwise operators in the output,
  which keeps it 5.1/Luau compatible).

### 6. String encryption (`src/strings.lua`)
- Four schemes per build, with per-string random selection:
  1. rotating-key XOR,
  2. Base64 over a shuffled custom alphabet,
  3. Huffman coding with a per-string serialized tree,
  4. chunked/multi-layer encoding.
- Scheme IDs are remapped per build. Decoders live in the generated runtime
  and decode on access; the pool itself is a plain table of encoded blobs.
- A random canary string is decoded at startup and periodically; a mismatch
  raises a misleading runtime error.

### 7. Integrity and anti-debug
- Instruction checksum over every encoded word, re-verified periodically.
- `debug` hook detection with a misleading error; `game` is used as an
  environment probe where present (Roblox), and the check is skipped elsewhere.
- All failures surface as the same generic `attempt to index a nil value`, so
  a patched build does not reveal which check fired.

## Output guarantees
- One file, no `require`/`loadfile`/`dofile`.
- No source comments, local names, function names, or literal strings in
  plaintext.
- Encrypted string bytes are emitted as decimal escapes, so the file stays
  ASCII apart from identifiers that legitimately came from the input.
- Generated source passes `load`/`loadstring` before it is written.
- Identical seed -> byte-identical file; different seed -> different opcode
  map, string keys and junk layout.

## Tests

```bash
python tests/run.py            # full matrix
python tests/run.py --keep     # keep generated artifacts
```

The harness obfuscates each case, runs the original and the obfuscated build on
every applicable interpreter, and compares stdout byte for byte. It also checks
error recovery, determinism and source-symbol leakage.

| Case | Coverage | Hosts |
| --- | --- | --- |
| `core` | arithmetic, strings/patterns, tables, multi-return, varargs, closures, recursion, methods, metatables, loops, coroutines, pcall/xpcall, coercion | 5.1, 5.2, 5.3, 5.4, Luau |
| `core-s3` | the same program at `--strength 3` | 5.1, 5.2, 5.3, 5.4, Luau |
| `goto` | labels, forward/backward goto, nested continue-labels | 5.2, 5.3, 5.4 |
| `bitwise` | `&`, `\|`, `~`, `<<`, `>>`, `//`, float operands | 5.3, 5.4 |
| `luau` | type aliases/generics, `continue`, compound assignment, interpolation, if-expressions, `::` assertions | Luau |

Python `lupa` provides the 5.1-5.4 runtimes; a native `lua` and `luau` binary
are used when available (override with `--lua` / `--luau`).

## Web UI

`index.html` in the repository root is a single self-contained file (about
390 KB) that runs the whole pipeline in the browser. The Lua modules and the
driver execute on [Fengari](https://fengari.io/), a Lua 5.3 VM compiled to
JavaScript, so there is no backend and no network request: the source never
leaves the page.

Rebuild it after editing any module or template:

```bash
python web/build.py
```

The builder inlines `web/fengari-web.js`, base64-encodes `obfuscator/src/*.lua`
and `web/driver.lua`, and fills `web/template.html`.

### Cloudflare Pages

1. Push the repository (or just the folder with `index.html`) to GitHub.
2. In Cloudflare Pages choose **Upload assets** / connect the repo.
3. Build command: none. Output directory: the folder containing `index.html`.
4. Deploy; the page is served from `<project>.pages.dev`.

A plain static host is enough: no Worker, KV, or build step is required.

## Known limitations
- Bitwise operators are emulated with doubles: operands/results are exact up to
  53 bits, unlike Lua 5.3+'s 64-bit integers.
- Luau `::` assertions are recognized on the same line as the expression, and
  not when the token sequence looks like a label (`:: name ::`).
- Nested backtick interpolation is rejected with a syntax diagnostic.
- `<close>`/`<const>` attributes are parsed but treated as plain locals.
- `local _ENV` cannot change the environment seen by globals; global access
  always goes through the host environment captured at startup.
- `#` on tables with holes follows each host's own implementation, which may
  differ between Lua and Luau.

## Security note
Obfuscation raises the cost of reading and patching a build; it is not a
cryptographic guarantee. All keys and decoders necessarily ship inside the
output, so a determined analyst with the same tools can recover the program.
