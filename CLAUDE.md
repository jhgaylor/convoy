# CLAUDE.md

Forge & Convoy — a persistent-world programming game in Elixir / Phoenix LiveView.
Each player submits ONE **WebAssembly** "colony brain" that commands a base
(harvesters, buildings, convoys); a deterministic sim runs every colony in a
shared world and they contest one market. Vision:
`Forge_and_Convoy_Engineering_Primer.md`. Design + status: `docs/colony-v2-design.md`.

The game loop: program one brain (`tick`) → mine ore → forge it into goods →
build refineries/storage + spawn units (time+cost gated) → load convoys → run them
across the single shared **contested market** for credits (the score); convoys
from different colonies collide and seize each other's shipments (the only PvP).

> **History:** this replaced a v1 game (per-harvester `decide` reflex bots). v1 was
> deleted in full. Do NOT reintroduce `decide`, `Convoy.Engine.{Region,World,Sim,Wasm}`,
> `SimLive`, `Persistence`, or `EventLog` — they're gone on purpose.

## Layout
- `lib/convoy/engine/colony/` — `world.ex` (one colony's state: units, buildings,
  deposits, build/spawn queues, refining), `sim.ex` (pure tick loop, resolves the
  brain's commands), `market.ex` (the shared contested market: convoys, PvP capture,
  sell→credits), `region.ex` (GenServer: many colonies + one market, one brain/tick).
- `lib/convoy/engine/colony_abi.ex` — the colony wire format (view + commands codec).
- `lib/convoy/engine/colony_wasm.ex` — Wasmtime host (via wasmex): instantiate +
  run one `tick`, fuel-metered, trap-contained.
- `lib/convoy/compile.ex` — source→wasm (rust/tinygo/asc/zig/c; WAT passthrough);
  delegates to the builder when `CONVOY_BUILDER_URL` is set.
- `lib/convoy/loader.ex` — `prepare(lang, source) -> {:ok, :wasm, exec, display}`.
- `lib/convoy_web/live/colony_live.ex` — the spectator page at `/` (scoreboard,
  shared market, per-colony grids, join-as-player upload).
- `lib/convoy_web/controllers/region_controller.ex` — `/api/region/:id/program` + `/upload`.
- `lib/mix/tasks/convoy.run.ex` — CLI (pushes a bot to a running server).
- `priv/colony/default.wasm` — the bundled `demo` colony bot (compiled `examples/colony.rs`).
- `k8s/` — app manifests (deployed via Flux from home-cloud).

## Conventions / gotchas
- **Bots are WASM only**, and the colony ABI is memory-based: a module exports
  `inbuf`/`outbuf`/`tick` (zero host imports). See `colony_abi.ex` + `examples/colony.rs`.
- **Determinism is sacred.** No wall-clock / `:rand` in the sim — seed-derived
  only (`:erlang.phash2`, LCG). Replays must stay bit-identical.
- **Intents, never mutations.** The brain returns commands; `Colony.Sim` / `Market`
  resolve them authoritatively. **Set wasm fuel BEFORE any guest call** (even
  `inbuf`/`outbuf` trap on a zero budget).
- **Colony regions persist** to disk (`Convoy.Engine.Colony.Persistence`,
  `data/colony/<id>.snapshot`): colonies + market + each player's program bytes &
  bot memory, snapshotted every 50 ticks + on submit/reset/shutdown, restored on
  boot (`Region.restore_all`). Keyed in their own `Convoy.Engine.ColonyRegistry`.
  `main` auto-seeds `demo`/`shipper`/`builder` on first boot; `/admin` is the ops page.
- **Run tests with toolchains on PATH:** `export PATH="$HOME/.cargo/bin:$PATH" && mix test`.
  Tests that compile a real bot self-skip if Rust is absent.
- **The cluster is arm64** (Apple Silicon). Images build `linux/arm64`.
- **Deploys auto-roll:** push app code to `main` → CI builds `sha-<commit>` and
  commits the pinned tag into `k8s/kustomization.yaml` → Flux rolls. No manual
  `kubectl rollout restart`. (Non-app changes are skipped by the build `paths`.)
- **Secrets** are runtime via self-hosted Infisical (magpie); only the operator
  creds are SOPS-encrypted. See the deploy notes in project memory.
- No auth yet — the hosted instance (convoy.inevitable.fyi) is public on purpose.

Commit messages end with the Co-Authored-By trailer; commit/push only when asked.
