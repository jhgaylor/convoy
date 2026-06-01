# Writing a Convoy bot

Your bot is a small **WebAssembly module** that is your colony's *brain*. Each
tick, the sim writes a read-only view of your whole colony (and the shared
market) into your module's memory, calls your `tick` function once, and reads back
a list of **commands** — one per unit or building you want to act. The sim
resolves those commands authoritatively: you can't move a harvester or seize a
shipment directly, you can only *command* it, and an illegal command degrades to a
no-op. One brain runs your entire colony — there is no per-unit callback.

You play in your **own private colony** — your harvesters, buildings, and ore
deposits, with no other player allowed in. Everyone shares exactly one thing: the
**market**, the space your convoys run to and where they can be ambushed (see
[Convoys & the contested market](#convoys--the-contested-market)).

Two hard rules make any language work (or not):

1. The module must export the **colony ABI**: `inbuf`, `outbuf`, and `tick` (plus
   its `memory`). The exact byte layout is below.
2. The module must have **zero host imports** — no WASI, no JS runtime, nothing.
   It runs in a locked-down sandbox under a per-tick fuel (instruction) budget.

That second rule is why some languages are a great fit and others aren't (see
[Language support](#language-support)).

## The colony loop

What your `tick` is steering, in one breath:

1. **Mine.** Harvesters move onto ore deposits and `harvest` ore into their cargo.
2. **Haul & forge.** A full harvester `transfer`s its cargo into an adjacent
   building. Your spawner has a small built-in forge, and **refineries** multiply
   the rate — each tick, ore turns into **goods** (bounded by your storage cap).
3. **Build & grow.** Spend goods to `build` refineries and storage, and `spawn`
   more harvesters. Construction and spawning take time — the pace is deliberate.
4. **Ship.** `launch` a convoy: it loads goods and runs across the single shared
   **contested market** to sell for **credits** — the score.
5. **Fight.** PvP is a **stance triangle** on the shared market — your base is
   never attacked, the stake is only the shipment in transit. When enemy convoys
   share a cell: a `hunt`er **seizes** a passive (advancing) shipment, a
   `defend`er (escort) seizes a `hunt`er that lands on it, and a `defend`er lets
   passive traffic pass. So you can't camp the drop point to farm — to rob a
   shipment you must `hunt` and land on its cell; to protect one, shadow it with a
   `defend`ing escort. Two passive convoys crossing don't fight.

## The ABI: a memory handshake

The module has zero host imports, so I/O happens through **linear memory** at two
buffers your module exposes. Each tick the host does:

```
host: write encode_view(view) into the bytes at inbuf()
host: call tick(view_len) -> command_count
host: read command_count * 16 bytes starting at outbuf()
host: decode each 16-byte record as a command
```

Your `tick` reads its colony out of the IN buffer, decides, and writes a packed
array of fixed-size command records into the OUT buffer, returning how many.
Everything is **fixed-stride little-endian** — trivial to read/write with no
allocator (the guest is typically `no_std`/freestanding), and bit-identical so
replays stay deterministic. The single source of truth for the layout is
[`lib/convoy/engine/colony_abi.ex`](../lib/convoy/engine/colony_abi.ex); the
in-file boilerplate in [`examples/colony.rs`](../examples/colony.rs) mirrors it
byte for byte.

### The view (host → guest), all little-endian

A 28-byte header, then four packed arrays back to back:

```
header (28 bytes):
  tick:u32 @0   width:u16 @4   height:u16 @6
  ore:u32 @8    goods:u32 @12  credits:u32 @16
  n_units:u16 @20  n_buildings:u16 @22  n_deposits:u16 @24  n_market:u16 @26
units[n_units]      12B each: id:u32 kind:u8 x:u8 y:u8 cargo:u16 cargo_max:u16 _pad:u8
buildings[n_bld]    10B each: id:u32 kind:u8 x:u8 y:u8 level:u8 progress:u8 _pad:u8
deposits[n_dep]      4B each: x:u8 y:u8 amount:u16
market[n_market]    10B each: id:u32 owner:u8 x:u8 y:u8 cargo:u16 _pad:u8
```

The arrays start at offset 28. Walk them in order: units begin at `28`, buildings
at `28 + n_units*12`, deposits after that, the market last.

- **units** — your units. `kind` 0 = harvester. `cargo`/`cargo_max` is what it
  carries vs. its capacity.
- **buildings** — your buildings. `kind` 0 = spawner (pre-built at your base),
  1 = refinery, 2 = storage. `progress` 255 means finished; less means still
  under construction. `level` is its upgrade level.
- **deposits** — ore on the map: `amount` is how much is left at `(x,y)`.
- **market** — every convoy currently in transit on the shared market.
  `owner` is **0 for your own convoys, 1 for a rival's** — that's how you tell
  friend from foe. This is the only place you see other players.

### The commands (guest → host)

Each command is a 16-byte record:

```
command (16 bytes): op:u8  _pad:u8  _pad:u16  target:u32  a:i32  b:i32
```

`target` is usually the id of the unit/building the order applies to. `a`/`b` are
signed arguments whose meaning depends on the op:

| op | command | target | a / b |
|----|---------|--------|-------|
| `0` | idle | — | — |
| `1` | **harvest** | unit id | mine the ore under this unit into its cargo |
| `2` | **move** | unit/convoy id | `a`=dx, `b`=dy — step one cell by the sign of each |
| `3` | **transfer** | unit id | `a`=building id — dump cargo into that adjacent building |
| `4` | **build** | — | `a`=building kind, `b`=packed coords `x*256 + y` (spends goods) |
| `5` | **spawn** | — | `a`=unit kind — queue a unit at the spawner (spends goods, pop-capped) |
| `7` | **launch** | — | load a convoy and run it to the market |
| `8` | **defend** | convoy id | escort stance: hold this cell; seizes a hunter that lands on it (lets passive convoys pass) |
| `9` | **hunt** | convoy id | raider stance: `a`=dx, `b`=dy steer one cell (or `0,0` to auto-home onto the nearest rival); seizes a passive convoy you land on |

Building kinds: `0` spawner · `1` refinery · `2` storage. Unit kinds: `0`
harvester. (Op `6` `upgrade` is reserved in the wire format but not yet resolved
by the sim.) Invalid placements, over-cap spawns, and commands aimed at units you
don't own are rejected as no-ops — you don't have to be perfect, just intentful.

## Convoys & the contested market

`launch` (op 7) loads goods onto a **convoy** and sends it off. By default a
convoy auto-pilots: it leaves your base, enters the shared market, crosses it, and
on arrival its shipment **sells for credits** — a premium over the goods you
spent, the reward for the run. Your basic choice is **when** to ship vs. hoard,
build, or grow.

The market is the **only contested ground**, and capture is a **stance triangle**.
Each tick a convoy's stance is whatever you ordered it to do — `hunt` (raider),
`defend` (escort), or passive (`move`/auto-advance). When enemy convoys share a
cell, a convoy is robbed only when an enemy there holds a stance that **beats** it:

```
hunt  ⊳ passive   a raider plunders an unguarded shipment
defend ⊳ hunt     an escort turns the tables on the raider, taking its haul
defend ⊳ passive  NO — a defender lets peaceful traffic pass
```

Nothing dominates: `passive → hunt → defend → (beats nothing else)`. Two passive
convoys crossing the same cell **don't fight** — raiding is a deliberate, opt-in
act, not an accident of geometry. You steer your *own* convoys (the ones with
`owner == 0` in the market array) every tick:

- **`hunt`** (op 9) — the raider stance. `a`/`b` steer one cell (sign only), so
  you can **intercept**: predict where a rival will step (rivals advance greedily
  toward the market at `(W-1, H-1)`) and land on that cell to seize its cargo.
  `0,0` auto-homes onto the nearest rival — fine for chasing, weak against a moving
  target. A hunter that lands on a defending escort **loses its own cargo** to it.
- **`defend`** (op 8) — the escort stance. Hold the cell and seize any hunter that
  lands on it, regardless of id. It does **not** rob passive convoys, so a lone
  defender can't farm the drop point — its job is to protect (shadow your own
  shipment so a raider that pounces gets robbed instead).
- **`move`** (op 2, targeting a convoy id) — steer it a cell yourself (passive).
- emit nothing for a convoy and it **auto-advances** to the market and banks.

The counterplay loop: to rob, `hunt` and intercept; to protect, run a `defend`ing
escort alongside your shipment. [`examples/raider.rs`](../examples/raider.rs) is a
worked bot built around the hunt-and-intercept side.

## Persistent memory

`tick` is called fresh each tick, but your module's **linear memory persists
between ticks** — anything you keep in a `static`/global buffer is still there next
tick. That's your scratch state (Screeps' `Memory`): remember a target, a mode, a
tick counter, the last tick you shipped (to space convoys out so they don't bunch
up and get ambushed together).

```rust
static mut LAST_SHIP: u32 = 0;     // survives across ticks

// inside tick(): read the current tick from the view header, compare to
// LAST_SHIP, and only launch when enough ticks have passed.
```

It also survives a **freeze/thaw** — a deploy or stop/resume re-instantiates your
module, and the engine restores a capped slice of your linear memory, so your
state carries across and replays stay bit-identical. Two caveats:

- Persistence across freeze/thaw needs your module to **export its memory**.
  Rust (`cdylib`) and AssemblyScript (`--runtime stub`) do by default; for
  Zig / C / TinyGo the export-memory behaviour comes from the freestanding
  targets below (live tick-to-tick memory works regardless).
- It's deterministic and untrusted: keep state in **linear memory**, not in
  mutable wasm globals (those aren't snapshotted). In Rust, prefer a
  `static mut [T; N]` accessed via `read_volatile`/`write_volatile` (a plain
  `static mut` scalar can be promoted to a global under `-O`). The engine glue in
  [`examples/colony.rs`](../examples/colony.rs) already reads/writes the IN/OUT
  buffers this way.

## Running your bot

There are two surfaces; the right path depends on which you're using.

### Local dev (`mix convoy.run`)

If you've cloned the repo and have the toolchains installed, the CLI compiles and
runs in one step — and `--watch` re-runs on every save:

```bash
mix phx.server                                   # terminal 1
mix convoy.run examples/colony.rs --watch        # terminal 2, then open the browser
```

The language is inferred from the file extension (`.rs .go .ts .zig .c .wat
.wasm`). Add `--player NAME --region arena` to join a shared world:

```bash
mix convoy.run alice.rs --region arena --player alice
mix convoy.run bob.rs   --region arena --player bob
```

### The hosted instance: ship us your source

The hosted instance compiles **server-side** — just send the file.

**curl it** (the request body *is* the source):

```bash
curl --data-binary @bot.rs -H 'Content-Type: application/octet-stream' \
  'https://convoy.inevitable.fyi/api/region/arena/upload?player=bob&lang=rust'
```

- `region` is in the path (`arena` above); `player` and `lang` are query params.
- Drop `lang` if you pass `?file=bot.rs` — the language is inferred from the
  extension.
- Already have a compiled module? `lang=wasm` and the binary is the body:
  `curl --data-binary @bot.wasm '...?player=bob&lang=wasm'`.

Rust / Go / AssemblyScript / Zig / C are compiled by an isolated builder service
(no secrets, no network egress); WAT compiles in-process. The response is JSON:
`{"status":"ok","player":"bob","backend":"wasm",...}`.

**In the browser:** the spectator page at `/` has a getting-started panel with a
per-language starter template, the curl/CLI commands, and a command reference, plus
an upload form (pick a file, set a player name, Submit) and an example-bot library
you can read and one-click field.

## Language support

Anything that compiles to a small, **zero-import** WASM module exporting
`inbuf`/`outbuf`/`tick` works. Each language has a starter template on the `/`
getting-started panel; the fully-worked Rust reference is
[`examples/colony.rs`](../examples/colony.rs).

| Language | Fit | How |
|----------|-----|-----|
| **Rust** | ✅ first-class | `wasm32-unknown-unknown`, zero imports |
| **Go (TinyGo)** | ✅ | `wasm-unknown` target, zero imports |
| **AssemblyScript** | ✅ (the "JS/TS" path) | `asc --runtime stub`, zero imports |
| **Zig** | ✅ | `wasm32-freestanding`, zero imports |
| **C** | ✅ | `clang --target=wasm32 -nostdlib`, zero imports |
| **WAT** | ✅ (no toolchain) | Wasmtime compiles the text directly |
| Plain JavaScript | ❌ | needs an embedded JS engine — see below |
| Ruby / Python | ❌ | same — `ruby.wasm` / CPython-on-WASI is a whole VM |

In local dev, `mix convoy.run bot.<ext>` runs the matching command for you. The
hosted builder runs the same commands. To compile by hand:

**Rust** — `rustup target add wasm32-unknown-unknown` once, then:

```bash
rustc --target wasm32-unknown-unknown -O --crate-type cdylib -o bot.wasm bot.rs
```

`#![no_std]` + `#[no_mangle] pub extern "C" fn tick/inbuf/outbuf` keeps it
import-free.

**Go (TinyGo)** — `brew install tinygo-org/tools/tinygo` (pulls LLVM). Plain
`go build` won't work; you need the freestanding `wasm-unknown` target:

```bash
tinygo build -o bot.wasm -target=wasm-unknown -scheduler=none -gc=leaking -no-debug bot.go
```

Export with `//export tick` (and `inbuf`/`outbuf`); keep a `func main() {}`.

**AssemblyScript** — TypeScript-like, the closest thing to "write your bot in JS."
`npm i -g assemblyscript` (or `npx asc`):

```bash
asc bot.ts -o bot.wasm --runtime stub --optimize
```

`--runtime stub` drops the runtime imports so the module instantiates.

**Zig** — `brew install zig` (or a build from
[ziglang.org/download](https://ziglang.org/download)):

```bash
zig build-exe bot.zig -target wasm32-freestanding -O ReleaseSmall \
  -fno-entry -rdynamic -femit-bin=bot.wasm
```

`export fn tick(...)` gives the C ABI; `-fno-entry` drops `_start` and
`wasm32-freestanding` keeps it import-free.

**C** — `brew install llvm` for a wasm-capable `clang` + `wasm-ld` (Apple's stock
clang can't link wasm):

```bash
clang --target=wasm32 -O3 -nostdlib -Wl,--no-entry \
  -Wl,--export=inbuf -Wl,--export=outbuf -Wl,--export=tick -o bot.wasm bot.c
```

**WAT** — no toolchain; Wasmtime compiles the text directly. Submit it as
`?lang=wat`, or `wat2wasm bot.wat` (from
[wabt](https://github.com/WebAssembly/wabt)) and upload the `.wasm`.

## Example bots

All four live in [`examples/`](../examples) and run the same loop with different
strategies — read them, then field one from the `/` page:

- [`colony.rs`](../examples/colony.rs) — the **reference** bot. Balanced: builds up
  to two refineries before shipping, then runs convoys while growing the fleet.
  Start here; the engine glue is clearly separated from the colony logic you edit.
- [`colony_shipper.rs`](../examples/colony_shipper.rs) — one refinery, then ships
  aggressively to flood the market with cheap early convoys.
- [`colony_builder.rs`](../examples/colony_builder.rs) — stacks three refineries
  before shipping; slow to start, dominant on throughput late.
- [`raider.rs`](../examples/raider.rs) — runs a lean economy and steers its convoys
  to `hunt`/`defend`, seizing rivals' shipments instead of banking its own.

## Why not plain JS, Ruby, or Python?

These don't compile to a small, zero-import module. To run them you'd ship an
entire language interpreter compiled to WASM (QuickJS, `ruby.wasm`,
CPython-on-WASI) and run your source as *data* inside it. That pulls in WASI
imports the sandbox doesn't provide, is megabytes of VM per bot, and burns most of
the fuel budget booting the interpreter instead of playing. If you want a
scripting feel, use **AssemblyScript** — it reads like TypeScript and compiles to a
tiny, clean module.
