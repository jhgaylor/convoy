# Writing a Convoy bot

Your bot is a small **WebAssembly module** that exports one function, `decide`.
Each tick, for each of your harvesters, the sim calls `decide` with a read-only
view of that harvester's situation, and you return a single **intent code**. The
sim resolves intents authoritatively — you can't move a harvester or take ore
directly, you can only *decide*.

Two hard rules make any language work (or not):

1. The module must export `decide` with the exact signature below.
2. The module must have **zero host imports** — no WASI, no JS runtime, nothing.
   It runs in a locked-down sandbox under a per-tick fuel (instruction) budget.

That second rule is why some languages are a great fit and others aren't (see
[Language support](#language-support)).

## The `decide` ABI

`decide` takes nine `i32` parameters and returns one `i32`:

```
decide(cargo, cargo_max, at_base, on_resource,
       res_dx, res_dy, base_dx, base_dy, tick) -> code
```

| param | meaning |
|-------|---------|
| `cargo`, `cargo_max` | ore you're carrying / your capacity |
| `at_base` | 1 if you're on the base cell, else 0 |
| `on_resource` | 1 if you're on a cell with ore, else 0 |
| `res_dx`, `res_dy` | direction (−1/0/1) to the nearest ore |
| `base_dx`, `base_dy` | direction (−1/0/1) to base |
| `tick` | the current tick number |

Return one of these intent codes:

| code | intent |
|------|--------|
| `1` | harvest |
| `2` | unload |
| `3` | move toward base |
| `4` | move toward nearest resource |
| `5` | wander (deterministic) |
| `6` | move toward the resource farthest from base |
| `10` / `11` / `12` / `13` | move +x / −x / +y / −y |
| anything else (incl. `0`) | idle |

Codes `3`/`4`/`6` let the sim do the pathfinding; `10`–`13` move one step in a
direction you choose (using `res_dx`/`base_dx`/etc.). `decide` is a **pure
function** — same inputs, same output — so there's no per-bot memory yet.

## Running your bot

There are two surfaces, and the right path depends on which you're using.

### Local dev (`mix convoy.run`)

If you've cloned the repo and have the toolchains installed, the CLI compiles
and runs in one step — and `--watch` re-runs on every save:

```bash
mix phx.server                                   # terminal 1
mix convoy.run examples/harvester.rs --watch     # terminal 2, then open the browser
```

The language is inferred from the file extension (`.rs .go .ts .wat .rules
.wasm`). Add `--player NAME --region arena` to join a shared world. See the
[README](../README.md#local-dev-workflow-write-code-in-your-editor-watch-it-in-the-sim).

### The hosted instance (and the universal path): upload a `.wasm`

The hosted instance does **not** run language toolchains (no `rustc`/`tinygo`/
`asc` server-side). The path that always works, anywhere, in any language:

1. Compile your bot to a `.wasm` **locally** (commands per language below).
2. In the browser, pick **Upload .wasm** in the language dropdown, set your
   player name, and **Upload & Run**.

WAT and the Rules DSL need no toolchain at all — you can type them straight into
the editor and hit Run.

## Language support

| Language | Fit | How |
|----------|-----|-----|
| **Rust** | ✅ first-class | `wasm32-unknown-unknown`, zero imports |
| **Go (TinyGo)** | ✅ | `wasm-unknown` target, zero imports |
| **AssemblyScript** | ✅ (the "JS/TS" path) | `asc --runtime stub`, zero imports |
| **WAT** | ✅ (no toolchain) | paste it in the editor |
| Plain JavaScript | ❌ | needs an embedded JS engine — see below |
| Ruby | ❌ | same — `ruby.wasm` is a whole VM |
| Python | ❌ | same — CPython-on-WASI is a whole VM |

### Rust

Install the target once: `rustup target add wasm32-unknown-unknown`.

Starter: [`examples/harvester.rs`](../examples/harvester.rs). Compile:

```bash
rustc --target wasm32-unknown-unknown -O --crate-type cdylib -o bot.wasm bot.rs
```

`#![no_std]` + `#[no_mangle] pub extern "C" fn decide(...)` keeps it import-free.
In local dev, `mix convoy.run bot.rs` does the compile for you.

### Go (TinyGo)

Install: `brew install tinygo-org/tools/tinygo` (pulls LLVM). Plain `go build`
won't work — you need TinyGo's freestanding **`wasm-unknown`** target so the
module has no WASI/JS imports.

Starter: [`examples/harvester.go`](../examples/harvester.go). Compile:

```bash
tinygo build -target=wasm-unknown -scheduler=none -gc=leaking -no-debug -o bot.wasm bot.go
```

Export with `//export decide`; keep a `func main() {}`. In local dev,
`mix convoy.run bot.go` runs the same command.

### AssemblyScript (the JavaScript/TypeScript path)

AssemblyScript is a TypeScript-like language that compiles straight to WASM —
the closest thing to "write your bot in JS." Install: `npm i -g assemblyscript`
(or `npx asc`).

Starter: [`examples/harvester.ts`](../examples/harvester.ts). Compile:

```bash
asc bot.ts -o bot.wasm --runtime stub --optimize
```

`--runtime stub` is what drops the runtime imports so the module instantiates.
In local dev, `mix convoy.run bot.ts` does this for you.

### WAT (WebAssembly text)

No toolchain, no compile step — paste it into the editor and Run. Great for
learning the ABI. See the default WASM program in the editor, or compile to a
binary with `wat2wasm bot.wat` (from [wabt](https://github.com/WebAssembly/wabt))
if you'd rather upload.

### Why not plain JS, Ruby, or Python?

These don't compile to a small, zero-import `decide` function. To run them you'd
have to ship an entire language interpreter compiled to WASM (QuickJS, `ruby.wasm`,
CPython-on-WASI) and run your source as *data* inside it. That:

- pulls in WASI imports (filesystem, clock, stdio) the sandbox doesn't provide,
- is megabytes of VM per bot, and
- burns most of the fuel budget booting the interpreter, not playing.

It doesn't fit the pure-function, fuel-metered model. If you want a
dynamic/scripting feel, use **AssemblyScript** — it reads like TypeScript and
compiles to a tiny clean module. (A future "scripting tier" with an embedded
interpreter could change this, but it's not built.)
```
