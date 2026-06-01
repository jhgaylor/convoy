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

The page is a **spectator**: it shows the shared world and a "Submit a bot"
guide (language tabs + a file upload). You join by sending a bot — `curl` a
file, `mix convoy.run`, the HTTP API, or the in-page upload — and watch the
harvesters compete on the grid. There's no in-browser editor.

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
the file extension (`.rs .go .ts .wat .wasm`).

```bash
# terminal 1
mix phx.server

# terminal 2 — push your bot into region "dev" and keep re-pushing on save
mix convoy.run examples/harvester.rs --watch
```

Open `http://localhost:4000/?region=dev` and just watch. Each save recompiles
and reloads the running region. Edit `examples/harvester.rs`, save, see it change.

### Multiplayer (private rooms, one shared market)

Submit different players into the **same region** and they run as independent
players in one common world. Each player **harvests in their own private room**
— their own deterministic ore layout, their own base, no one else allowed in —
so there's no fighting over ore. The contest is the **market**: a single shared
room every player's convoys must cross to sell. Two terminals, two strategies,
one arena:

```bash
mix convoy.run examples/harvester.ts --region arena --player alice
mix convoy.run examples/harvester.rs    --region arena --player bob
```

Open `http://localhost:4000/?region=arena` to watch the scoreboard, each
player's private harvesting room, and the shared market room where convoys
collide. When two players' convoys share a market cell the world arbitrates
authoritatively (resolved in entity-id order, single-writer), so an ambush for a
shipment is decided fairly and deterministically. The browser is a
**spectator** — it never auto-joins. You join by submitting a bot: the page's
upload, `mix convoy.run --player NAME`, or a `curl` to `/upload`.

Prefer the terminal? `--headless` runs the sim in-process and renders ASCII —
no server, no browser, the fastest loop:

```bash
mix convoy.run examples/harvester.rs --headless --ticks 300
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
(the JS/TS path), **Zig**, **C**, and **WAT**. Starters live in
[`examples/`](examples/). Plain
JS, Ruby, and Python aren't supported (they'd need a whole interpreter in WASM —
the doc explains why; use AssemblyScript for a scripting feel).

## What v1 implements (and how it maps to the primer)

| Primer concept | Where it lives |
|---|---|
| **Deterministic tick loop** (§6): snapshot → run code → intents → validate → resolve in entity-id order → apply → commit | `Convoy.Engine.Sim` — pure functions (`tick/2`, `collect_intents/2`, `apply_intents/2`) |
| **Intents, never mutations** (§3): player code returns declarative intents; the sim owns all state change | the WASM `decide` returns an intent code; `Sim` resolves them authoritatively |
| **WASM execution tier + fuel metering** (§7): untrusted code in Wasmtime, instruction-counted budget, zero ambient authority | `Convoy.Engine.Wasm` via `wasmex`; per-entity fuel budget, traps contained |
| **Player language story** (§7): bring Rust/Go/AssemblyScript/C, or an easy SDK | `Convoy.Compile` (in-game single-file compile) + `.wasm` upload; templates per language |
| **Seeded determinism / free replays** (§6, §11): same seed + same program → bit-identical result | `World.generate/1` (LCG); each player's private room laid out from `phash2({seed, player_id})`; `:erlang.phash2` for `wander`; proven in tests |
| **Private harvesting rooms + a shared market**: each player mines alone, everyone ships to one contested market | `World.rooms` (per-player deposits, keyed by player id) + the `:market` room; entities carry a `room` tag; `Sim`/`Wasm` scope harvest + the per-entity view to the owner's room. The market is the only place entities from different players meet |
| **Region = single-writer process** (§4, §9) advancing autonomously | `Convoy.Engine.Region` GenServer; ticks on a timer, owns the WASM instance |
| **Region registry / scale-to-zero** (§10): regions started on demand, located by id | `Registry` + `DynamicSupervisor` in `application.ex`; `Convoy.Engine.ensure_region/2` |
| **Hot/warm activation** (§5): spend compute where something's happening | a running region with no spectators is **warm** — it still advances but ticks `@warm_factor`× slower; a connecting spectator (`Engine.observe/2`, called by `SimLive`) snaps it **hot** (full rate). **Cold** = the admin Stop (process killed, snapshot kept). `activation` shows in the header + stats |
| **Snapshot persistence / freeze-thaw** (§8, §11): a region resumes at the tick it stopped across a restart/deploy | `Convoy.Persistence` (file-backed snapshots) + `Region` restore-on-init + `Engine.restore_all/0` on boot |
| **Event log** (§8): the durable event stream beside the snapshots | `Convoy.EventLog` — append-only, framed control events (submit/kick/reset) per region with their tick; combined with the seed + deterministic loop this is the recovery + free-replay substrate (§6, §8). `Engine.history/2` reads it |
| **Local dev loop**: edit a file, watch in the sim | `mix convoy.run` + `POST /api/region/:id/program` (or `/upload`) + named regions (`/?region=NAME`) |
| **Ops/overview**: every running sim + utilization, stop/delete/kick | `ConvoyWeb.AdminLive` (`/admin`) + `Engine.list_regions/0`, `region_stats/1`, `stop_region/1`, `delete_region/1`, `kick_player/2` |
| **Route a session to its region** (§9) | `ConvoyWeb.SimLive` (spectator) subscribes over PubSub; submits go through `Convoy.Loader` → `Engine.submit_player/5` |
| **The Forge** (§1): refine harvested ore, climb a rate-based tech ladder | each player has a `base` (`World.bases`): `unload` stocks raw ore, `Sim` refines it to goods each tick (`World.refine_all/1`), and `build` intents (codes 20/21/22) spend goods on **refine / cargo / fuel** tech |
| **Player Memory** (§8): persistent scratch state between ticks | the wasm instance is reused across ticks, so a bot's linear memory persists live; `Wasm.snapshot_memory/1` + `restore_memory/2` serialize a capped page with the region so it survives freeze/thaw (bit-identical replay) |
| **Convoys + the contested market** (§1): ship goods across contested ground for credits; PvP | `build`-style intent (code 30) loads a convoy (`World.launch_convoy/2`); the `Sim` auto-pilots it to the market and sells it for `credits`; when enemy convoys share a cell the lower-id one seizes the shipment (`Sim.resolve_market/1`). Bases are never attacked — the stake is only the shipment (§1) |
| **Cross-region border handoff** (§4): a convoy migrates between region processes | opt-in via `ensure_region(id, neighbor: "market")`. A convoy reaching a bordered region's edge is removed and cast to the neighbor (`Region.receive_convoy/2`); selling there casts a credit-back to the origin region (`Region.credit/3`). Two-phase, async (no Region→Region calls → no deadlock). The default (neighbor-less) region keeps the fully-deterministic in-world market, preserving bit-identical replay |

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

## Bringing your own code

Your bot is a WebAssembly module that exports `decide`. Several languages get
you there, and they all end at the same place — the sim only ever instantiates
a finished `.wasm`:

| Language | How it runs |
|---|---|
| **WAT** | WebAssembly text. Wasmtime compiles it directly — no toolchain. |
| **Rust** | Compiled, single-file, via `rustc --target wasm32-unknown-unknown`. |
| **Go (TinyGo)** | Compiled via `tinygo build -target=wasm-unknown`. |
| **AssemblyScript** | Compiled by the pure-JS `asc` compiler (the JS/TS path). |
| **Zig** | Compiled via `zig build-exe -target wasm32-freestanding`. |
| **C** | Compiled via `clang --target=wasm32 -nostdlib`. |
| **Upload .wasm** | Bring a precompiled module from *any* language. |

See [docs/writing-bots.md](docs/writing-bots.md) for the `decide` ABI and
per-language getting-started.

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
- **Zig**: `brew install zig`.
- **C**: `brew install llvm` (a wasm-capable clang + `wasm-ld`; Apple's stock clang won't link wasm).
- **Upload** needs nothing server-side — compile wherever you like:
  - Rust: `rustc --target wasm32-unknown-unknown -O --crate-type cdylib -o bot.wasm bot.rs`
  - TinyGo: `tinygo build -o bot.wasm -target=wasm bot.go`
  - AssemblyScript: `asc bot.ts -o bot.wasm --runtime stub --optimize`
  - Zig: `zig build-exe bot.zig -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic -femit-bin=bot.wasm`
  - C: `clang --target=wasm32 -O3 -nostdlib -Wl,--no-entry -Wl,--export=decide -o bot.wasm bot.c`

### The WASM ABI

The host hands the module a read-only per-entity view — including your base's
economy and what tech you can afford — and the module returns an intent code
(full table in `Convoy.Engine.Wasm`):

```
decide(cargo, cargo_max, at_base, on_resource,
       res_dx, res_dy, base_dx, base_dy, tick,
       base_ore, base_goods, can_refine, can_cargo, can_fuel) -> code
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

A region is a shared world with many players, but **space is partitioned into
rooms** (`World.rooms`). Each player gets a **private harvesting room** — its ore
laid out deterministically from `{seed, player_id}`, its base, and only that
player's harvesters; no other player's entity can ever be there. There's a
single **shared market room** (`:market`) that every player's convoys travel
through to sell. Each entity carries a `room` tag (`owner_id` for harvesters,
`:market` for convoys), and two entities in different rooms never interact even
at the same `{x, y}`.

The upshot: harvesting is solitaire (no ore contention), and the **only**
contested ground is the market road, where convoys from different players can
collide and the lower-id one seizes the shipment (resolved in entity-id order,
single-writer — fair and deterministic). The tick loop runs each harvester's
*owner's* program against a read-only view of that player's own room. Scoring is
per-player (`World.scoreboard`). The browser only spectates until you submit;
you join as a named player via the page's upload, `mix convoy.run --player
NAME`, or the HTTP API. Players, their rooms, programs, and scores are all part
of the persisted snapshot, so a shared game survives deploys.

## Not yet built (next milestones, per the primer)

- Wiring the cross-region handoff into the default browser flow. The mechanism
  is built + tested (above), but enabling a `main → market` topology would make
  the main game's timeline cross-region (and so only replayable from its event
  log, not bit-identically from seeds). Left opt-in deliberately; closing that
  gap means leaning on the event log (§8) as the replay source of record.
- Analytical fast-forward of warm regions (§5): warm regions currently tick
  slowly rather than computing a closed-form jump. The Forge's refining is
  rate-based (closed-form) so the *production* side is fast-forwardable; the
  black-box bot side is the open problem.
- OS-level (gVisor/Firecracker) isolation for the WASM *runner* (§7, §10). The
  compile service is already a separate, egress-denied, non-root, no-token pod;
  the app pod is hardened the same way; the remaining piece is scheduling the
  runner onto a gVisor node pool (the commented seam in `k8s/deployment.yaml`).
  See **[docs/security.md](docs/security.md)** for the full isolation model.

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
default WAT harvester delivers ore *identically* to a reference Elixir decider
(`test/support/bots.ex`).

`test/convoy/compile_test.exs` covers the compile pipeline: WAT passthrough,
per-language templates, and that an AssemblyScript / Rust / TinyGo / Zig / C
module compiled from its template delivers ore *identically* to the reference decider
(ABI correctness, end to end). Tests for a language whose toolchain isn't installed self-skip, so
the suite stays portable.
