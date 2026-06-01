# Forge & Convoy

A persistent-world programming game where **your code is your only interface**.
You write one **colony brain** — a small WebAssembly module — and a deterministic
simulation runs it: your colony mines ore, forges it into goods, builds out a base,
and runs convoys across a shared, contested market for credits. Every other player
is doing the same in the same world. The market is the only place you meet, and the
only place there's a fight.

Architecture vision: [`Forge_and_Convoy_Engineering_Primer.md`](./Forge_and_Convoy_Engineering_Primer.md).
How it's built today + status: [`docs/colony-v2-design.md`](./docs/colony-v2-design.md).

## Run it

```bash
mix setup        # deps + assets
mix phx.server   # http://localhost:4000
```

The page at `/` is a **spectator**: it shows every colony, the shared market, and a
scoreboard. A bundled `demo` colony runs out of the box so there's always something
to watch (and an opponent to ambush). You join by submitting a bot.

`/?region=NAME` watches a different region. Each region is an independent shared world.

## The game loop

1. **Mine.** Harvesters dig ore from your private room and haul it to a building.
2. **Forge.** Your base refines ore into **goods** each tick; refineries multiply the rate.
3. **Build.** Spend goods to construct buildings (refinery, storage) and spawn more
   units. Construction and spawning take time — the pace is a slow, deliberate build-up.
4. **Ship.** Load goods onto a **convoy** and run it across the single shared
   **contested market** to sell for **credits** — the score.
5. **Fight.** When two colonies' convoys share a market cell, one **seizes** the
   other's shipment. That's the only PvP; your base is never attacked. The stake is
   only the shipment in transit.

You don't drive any of this by hand — you write one `tick` function that issues
commands for all your units and buildings, and the sim resolves them authoritatively.

## Writing a bot

Your bot is a zero-import WebAssembly module that exports three functions —
`inbuf`, `outbuf`, and `tick`. Each tick the host writes a view of your colony +
the market into your `inbuf`, calls `tick(view_len)`, and reads a list of commands
back from your `outbuf`. The fully-worked reference bot is
[`examples/colony.rs`](./examples/colony.rs) — read it; it's one self-contained file
with the engine glue clearly separated from the colony logic you edit. The exact
wire format lives in [`lib/convoy/engine/colony_abi.ex`](./lib/convoy/engine/colony_abi.ex).

Commands the sim understands: harvest, move, transfer (haul into a building), build,
spawn, launch-convoy, and convoy steering (defend / hunt). Invalid commands degrade
to idle — the sim owns all state, so you can't cheat by issuing an illegal one.

### Submitting

In the browser: set a player name, choose a file, Submit.

From your editor (push to a running server and watch it live):

```bash
mix phx.server                                    # terminal 1
mix convoy.run examples/colony.rs --watch         # terminal 2 — re-pushes on save
# multiplayer: same region, different players
mix convoy.run alice.rs --region arena --player alice
mix convoy.run bob.rs   --region arena --player bob
```

Or `curl` a file directly (the body is the source):

```bash
curl --data-binary @bot.rs -H 'Content-Type: application/octet-stream' \
  'http://localhost:4000/api/region/main/upload?player=you&lang=rust'
```

### Languages

Anything that compiles to a small, zero-import WASM module works. **Rust** is the
first-class path today (`examples/colony.rs`). Go (TinyGo), AssemblyScript, Zig, C,
and WAT all compile to WASM the same way; first-class colony starter templates +
typed SDKs for those are in progress — for now, port `examples/colony.rs`'s ABI glue.
Compile locally and upload a `.wasm`, or let the server compile your source. Plain
JS/Ruby/Python don't fit (they'd need a whole interpreter in WASM).

```bash
rustc --target wasm32-unknown-unknown -O --crate-type cdylib -o bot.wasm bot.rs
```

## How it's built

- `lib/convoy/engine/colony/` — `world.ex` (one colony's deterministic state),
  `sim.ex` (the pure tick loop that resolves brain commands), `market.ex` (the shared
  contested market: convoys, PvP capture, selling), `region.ex` (the GenServer owning
  many colonies + one market, single-writer).
- `lib/convoy/engine/colony_abi.ex` + `colony_wasm.ex` — the wire format and the
  fuel-metered, trap-contained Wasmtime host (via `wasmex`).
- `lib/convoy_web/live/colony_live.ex` — the spectator page.
- `lib/convoy/compile.ex` — compiles source → wasm (delegates to a sandboxed builder
  service when `CONVOY_BUILDER_URL` is set; see [`builder/`](./builder)).

The sim is **deterministic** (seed-derived randomness only) so the same seed +
programs reproduce bit-identically — the foundation for replays and fair PvP.
Colony regions are currently **in-memory** (a deploy restarts them); snapshot
persistence is on the roadmap.

## Tests

```bash
export PATH="$HOME/.cargo/bin:$PATH" && mix test
```

Covers the wire-format codec, the colony tick loop (command resolution, time-gated
construction, refining, determinism), the market (convoy movement, PvP capture,
selling), the multiplayer region, and end-to-end runs of the real compiled bot
(those self-skip if the Rust toolchain isn't installed).

## Deploy

Push app code to `main` → CI builds `sha-<commit>` (linux/arm64), pins the tag into
`k8s/kustomization.yaml`, and Flux rolls it onto the cluster. The hosted instance is
[convoy.inevitable.fyi](https://convoy.inevitable.fyi) — public, no auth yet (on purpose).
