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

**World overview** at `/admin`: every simulation at a glance — running ones
with live system + per-sim utilization (BEAM scheduler %, VM memory, process
count; per-sim tick, players, harvesters, ore, fuel/tick, memory,
reductions/sec), and stopped-but-persisted ones (built from their snapshot).
Controls: **Stop** (free compute; snapshot kept), **Resume** (restart a stopped
one), **Delete** (remove its snapshot). Put it behind auth before exposing it
publicly.

## Local dev workflow (write code in your editor, watch it in the sim)

You don't have to write bots in the website. Develop in your editor, run one
command, and the browser becomes a live viewer. The language is inferred from
the file extension (`.rules .wat .rs .ts .go .wasm`).

```bash
# terminal 1
mix phx.server

# terminal 2 — push your bot into region "dev" and keep re-pushing on save
mix convoy.run examples/harvester.rs --watch
```

Open `http://localhost:4000/?region=dev` and just watch. Each save recompiles
and reloads the running region. Edit `examples/harvester.rs`, save, see it change.

### Multiplayer (a shared world)

Submit different players into the **same region** and they run as independent
players in one common world — each owns their own harvesters, runs their own
code, and scores separately. Two terminals, two strategies, one arena:

```bash
mix convoy.run examples/harvester.rules --region arena --player alice
mix convoy.run examples/harvester.rs    --region arena --player bob
```

Open `http://localhost:4000/?region=arena` to watch the scoreboard and the
colour-coded harvesters compete for ore. The shared world arbitrates conflicts
authoritatively (resolved in entity-id order, single-writer), so two players
reaching for the last ore in a cell is decided fairly and deterministically.
The browser is a **spectator** — it never auto-joins. You join by submitting
code: set the editor's "play as" name and Run, or `mix convoy.run --player NAME`.

Prefer the terminal? `--headless` runs the sim in-process and renders ASCII —
no server, no browser, the fastest loop:

```bash
mix convoy.run examples/harvester.rules --headless --ticks 300
```

```
B · · · · · · · · · · · · · · ·
· · · · · · · · 2 · * · · · · ·
3 · · · · · · · · · · · · · · ·
· · 1 · · · · · * · · · * · · ·
tick 120  delivered 100  in-cargo 10  ore-left 130
```

Key flags: `--region NAME` (default `dev`), `--player NAME`, `--server URL`,
`--headless`, `--ticks N`, `--seed N`, `--watch`, `--lang LANG`. Full help:
`mix help convoy.run`. Under the hood the CLI POSTs to
`POST /api/region/:id/program`, so anything that speaks HTTP can drive a region.
Or just curl a file — the body is the source:
`curl --data-binary @bot.rs -H 'Content-Type: application/octet-stream' '…/api/region/arena/upload?player=bob&lang=rust'`
(see [docs/writing-bots.md](docs/writing-bots.md)).

## Writing a bot

New here? **[docs/writing-bots.md](docs/writing-bots.md)** is the getting-started
guide: the `decide` ABI, how to run a bot (locally or by uploading a `.wasm`),
and per-language setup. Bots compile to a zero-import WASM module exporting
`decide`. First-class languages: **Rust**, **Go (TinyGo)**, **AssemblyScript**
(the JS/TS path), and **WAT**. Starters live in [`examples/`](examples/). Plain
JS, Ruby, and Python aren't supported (they'd need a whole interpreter in WASM —
the doc explains why; use AssemblyScript for a scripting feel).

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
| **Snapshot persistence / freeze-thaw** (§8, §11): a region resumes at the tick it stopped across a restart/deploy | `Convoy.Persistence` (file-backed snapshots) + `Region` restore-on-init + `Engine.restore_all/0` on boot |
| **Local dev loop**: author in your editor, watch in the sim | `mix convoy.run` + `POST /api/region/:id/program` + named regions (`/?region=NAME`) |
| **Ops/overview**: every running sim + utilization, stop/delete | `ConvoyWeb.AdminLive` (`/admin`) + `Engine.list_regions/0`, `region_stats/1`, `stop_region/1`, `delete_region/1` |

## Persistence (surviving deploys)

Every region is a durable, shared world (`/` is the default `main`; `?region=NAME`
picks another). Regions snapshot their state to disk (`data/regions/<id>.snapshot`)
periodically, on code load, on reset, and on graceful shutdown. On boot,
`Engine.restore_all/0` brings them back online and they resume **at the exact
tick they stopped**, still running whatever program was loaded — so deploying a
new version continues the simulation instead of resetting it. Reset still works:
it regenerates the world and persists the fresh state.

The player's code is treated as a **pure function of state**, so we never try to
snapshot the live WASM VM. We persist the world plus the program *bytes* and
re-instantiate a fresh module on resume — the deterministic `decide` function
behaves identically. A `version` + field-shape guard discards snapshots from an
older schema (a deploy that changes the world's shape starts that region fresh
rather than crashing).

The browser is a spectator: opening a region never creates a player, and an
empty region just shows the map until someone submits.
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

## Multiplayer model

A region is a shared world with many players. Each player submits their own
program and owns a set of harvesters; the tick loop runs each entity's *owner's*
program, then resolves all intents in entity-id order (single-writer), so
competition for ore is arbitrated fairly and deterministically. Scoring is
per-player (`World.scores`). The browser only spectates until you submit; you
join as a named player via the editor's "play as" field or `mix convoy.run
--player NAME` / the HTTP API. Players, their programs, and
scores are all part of the persisted snapshot, so a shared game survives deploys.

## Not yet built (next milestones, per the primer)

- Warm/cold fast-forward (§5) and the event-log half of persistence (§8).
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
