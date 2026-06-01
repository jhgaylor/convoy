# CLAUDE.md

Forge & Convoy — a persistent-world programming game in Elixir / Phoenix LiveView.
Players submit a **WebAssembly** bot that controls harvester agents; a
deterministic sim runs it in a shared world. Vision:
`Forge_and_Convoy_Engineering_Primer.md`.

Start here: **`README.md`** (architecture map + how it all fits) and
**`docs/writing-bots.md`** (the `decide` ABI + per-language getting-started).

## Layout
- `lib/convoy/engine/` — `world.ex` (state + helpers), `sim.ex` (pure tick loop),
  `region.ex` (GenServer per region, single-writer + timer), `wasm.ex` (Wasmtime
  via wasmex: fuel, traps, limits), `render.ex` (ASCII for headless).
- `lib/convoy/compile.ex` — source→wasm (rust/tinygo/asc; WAT passthrough);
  delegates to the builder when `CONVOY_BUILDER_URL` is set.
- `lib/convoy/loader.ex` — `prepare(lang, source) -> {:ok, :wasm, exec, display}`.
- `lib/convoy_web/live/sim_live.ex` — spectator page (no editor). `admin_live.ex` — ops.
- `lib/convoy_web/controllers/region_controller.ex` — `/api/region/:id/program` + `/upload`.
- `lib/mix/tasks/convoy.run.ex` — CLI. `builder/` — the sandboxed compile service.
- `k8s/` — app manifests (deployed via Flux from home-cloud).

## Conventions / gotchas
- **Bots are WASM only.** The custom "rules DSL" was deliberately removed — do
  not reintroduce a hand-maintained language. WAT is the no-toolchain option.
- **Determinism is sacred.** No wall-clock / `:rand` in the sim — seed-derived
  only (`:erlang.phash2`, LCG). Replays must stay bit-identical.
- **Intents, never mutations.** `decide` returns an intent code; `Sim` resolves it.
- **Run tests with toolchains on PATH:** `export PATH="$HOME/.cargo/bin:$PATH" && mix test`.
  Compiled-language tests self-skip if a toolchain is absent. `test/support/bots.ex`
  has reference deciders + WAT snippets.
- **The cluster is arm64** (Apple Silicon). Images build `linux/arm64`.
- **Deploys auto-roll:** push app code to `main` → CI builds `sha-<commit>` and
  commits the pinned tag into `k8s/kustomization.yaml` → Flux rolls. No manual
  `kubectl rollout restart`. (Non-app changes are skipped by the build `paths`.)
- **Secrets** are runtime via self-hosted Infisical (magpie); only the operator
  creds are SOPS-encrypted. See the deploy notes in project memory.
- No auth yet — the hosted instance (convoy.inevitable.fyi) is public on purpose.

Commit messages end with the Co-Authored-By trailer; commit/push only when asked.
