# Forge & Convoy — v1

A persistent-world programming game where **your code is your only interface**.
You write a behaviour program for autonomous harvester agents and watch a
deterministic simulation execute it. This is v1: a playable browser UI over a
working deterministic engine.

See [`Forge_and_Convoy_Engineering_Primer.md`](./Forge_and_Convoy_Engineering_Primer.md)
for the full architecture vision. This repo implements the load-bearing core of
it in Elixir / Phoenix LiveView.

## Run it

```bash
mix setup        # deps + assets (already done if you scaffolded)
mix phx.server   # http://localhost:4000
```

Then open the page, edit the harvester program on the left, press **Run**, and
watch your agents harvest ore and deliver it to base on the grid.

## What v1 implements (and how it maps to the primer)

| Primer concept | Where it lives |
|---|---|
| **Deterministic tick loop** (§6): snapshot → run code → intents → validate → resolve in entity-id order → apply → commit | `Convoy.Engine.Sim` — pure functions (`tick/2`, `collect_intents/2`, `apply_intents/2`) |
| **Intents, never mutations** (§3): player code returns declarative intents; the sim owns all state change | both backends return intents; `Sim` resolves them authoritatively |
| **WASM execution tier + fuel metering** (§7): untrusted code in Wasmtime, instruction-counted budget, zero ambient authority | `Convoy.Engine.Wasm` via `wasmex`; per-entity fuel budget, traps contained |
| **Player language story** (§7): bring Rust/Go/AssemblyScript/C, or an easy SDK | `Convoy.Compile` (in-game single-file compile) + `.wasm` upload; templates per language |
| **Seeded determinism / free replays** (§6, §11): same seed + same program → bit-identical result | `World.generate/1` (LCG), `:erlang.phash2` for `wander`; proven for *both* backends in tests |
| **Region = single-writer process** (§4, §9) advancing autonomously | `Convoy.Engine.Region` GenServer; ticks on a timer, owns the WASM instance |
| **Region registry / scale-to-zero** (§10): regions started on demand, located by id | `Registry` + `DynamicSupervisor` in `application.ex`; `Convoy.Engine.ensure_region/2` |
| **Route a session to its region** (§9) | `ConvoyWeb.SimLive` subscribes over PubSub and sends commands |

## The program language

A program is a list of `condition → action` rules, evaluated top-to-bottom;
the first matching condition wins and produces one intent per entity per tick.

```
when can_unload  unload      # at base AND carrying cargo
when cargo_full  to_base
when on_resource harvest
otherwise        to_resource
```

- **Conditions:** `cargo_full`, `cargo_empty`, `has_cargo`, `on_resource`,
  `at_base`, `can_unload`, `always` (alias `otherwise`).
- **Actions:** `harvest`, `unload`, `to_base`, `to_resource`, `wander`, `idle`.

## Bringing your own code

Pick a language from the dropdown in the UI. There are six paths, and they all
end at the same place — the sim only ever instantiates a finished `.wasm`:

| Language | How it runs |
|---|---|
| **Rules DSL** | The sandboxed `condition → action` language above. No toolchain. |
| **WAT** | WebAssembly text, pasted in the editor. Wasmtime compiles it directly. |
| **AssemblyScript** | Compiled in-game by the pure-JS `asc` compiler (no native toolchain). |
| **Rust** | Compiled in-game, single-file, via `rustc --target wasm32-unknown-unknown`. |
| **TinyGo** | Compiled in-game via `tinygo build -target=wasm` (if TinyGo is installed). |
| **Upload .wasm** | Bring a precompiled module from *any* language (Rust/TinyGo/AS/C/Zig…). |

All WASM paths run in **Wasmtime via `wasmex`** with a per-entity **fuel budget**
(instruction count), **zero ambient authority** (empty import set), and return an
intent code the sim resolves. Every module must export `decide` (see ABI below).
Starter templates for each language are loaded automatically when you pick it.

### Compilation lives *outside* the sim (the safety model)

Compiling untrusted source is its own remote-code-execution surface (a malicious
Rust `build.rs`, an `npm` post-install hook…). `Convoy.Compile` shrinks it:

- **Single source file**, so `rustc` (not `cargo`) and `asc` run with no manifest
  → no dependency fetches, no build scripts.
- **Throwaway temp dir, hard timeout**, output read back as bytes.

That's the in-process layer, good enough to play with. **Production should move
compilation to the separate, locked-down build service from §10** (gVisor /
Firecracker, no egress, ephemeral) — `Convoy.Compile.to_wasm/2` is the seam that
would point at it. Missing toolchains degrade gracefully: the UI shows an install
hint and suggests compiling locally + uploading the `.wasm` instead.

#### Toolchains

- **AssemblyScript**: `cd priv/asc && npm install assemblyscript` (bundled here).
- **Rust**: `curl https://sh.rustup.rs -sSf | sh` then `rustup target add wasm32-unknown-unknown`.
- **TinyGo**: `brew install tinygo`.
- **Upload** needs nothing server-side — compile wherever you like:
  - Rust: `rustc --target wasm32-unknown-unknown -O --crate-type cdylib -o bot.wasm bot.rs`
  - TinyGo: `tinygo build -o bot.wasm -target=wasm bot.go`
  - AssemblyScript: `asc bot.ts -o bot.wasm --runtime stub --optimize`

### The WASM ABI

The host hands the module a read-only per-entity view; the module returns an
intent code (full table in `Convoy.Engine.Wasm`):

```
decide(cargo, cargo_max, at_base, on_resource,
       res_dx, res_dy, base_dx, base_dy, tick) -> code
```

### Why fuel + traps matter (proven, not asserted)

`wasmex` exposes Wasmtime's fuel API, which counts instructions — more
deterministic than wall-clock CPU, so it's the right basis for fairness *and*
bit-identical replay (§7). A module that loops forever exhausts its fuel and
**traps**; `wasmex` surfaces the trap as an `{:error, _}` tuple, so the runner
degrades that entity to `idle` for the tick. The misbehaving program wastes its
own turn and nothing more — **the BEAM scheduler and region process are never
taken down**. You can watch this in the UI: paste an infinite loop, hit Run, and
the fuel meter pins at budget while delivery freezes and ticks keep advancing.

Memory is bounded too: each store is created with `Wasmex.StoreLimits` (16 MB
linear-memory cap, plus table/instance limits). A module that declares or grows
past the cap is rejected or denied rather than OOMing the node, and because
wasm instances run under a dedicated `WasmSupervisor` (not linked to their
region), an instantiation crash is contained and surfaced as an error instead
of taking the region down. Fuel bounds CPU; StoreLimits bounds allocation.

OS-level isolation (gVisor / Firecracker, no network egress, ephemeral pods)
from §7 is the *next* defense layer; fuel + caps + trap containment is the in-BEAM
layer, and it's done.

## Not yet built (next milestones, per the primer)

- Warm/cold fast-forward + snapshot/event-log persistence (§5, §8).
- Convoys and border-crossing handoff between regions (§4) — the only PvP moment.
- OS-level sandbox around both the WASM runner *and* the compile service (§7, §10).
- Persistent player "Memory" between ticks (§8) and per-player module storage.

## Tests

```bash
mix test
```

`test/convoy/engine_test.exs` proves the core guarantees: deterministic layout
from seed, bit-identical tick loop across independent runs (the §11 acceptance
test in miniature), ore conservation, and that player code cannot move an entity
off the grid (the anti-cheat foundation).

`test/convoy/wasm_test.exs` proves the §9 de-risking checklist for the WASM
tier: constrained instantiation (and rejection of modules missing `decide` or
with invalid WAT), deterministic fuel consumption, infinite-loop containment
(trap → idle, BEAM survives), bit-identical wasm-driven replay, and that the
default WAT harvester delivers ore *identically* to the equivalent rule program.

`test/convoy/compile_test.exs` covers the compile pipeline: WAT passthrough,
per-language templates, and that an AssemblyScript / Rust module compiled from
its template delivers ore *identically* to the rule program (ABI correctness,
end to end). Tests for a language whose toolchain isn't installed self-skip, so
the suite stays portable.
