# Isolation & the sandbox model (primer §7, §10)

Forge & Convoy runs **arbitrary code from strangers** — every bot is an
untrusted WebAssembly module, and (on the hosted instance) untrusted *source*
that gets compiled. Two distinct surfaces, isolated independently. This is the
primer's §7/§10 defense-in-depth, and where each layer stands.

## Two untrusted surfaces

| Surface | Where it runs | Threat |
|---------|---------------|--------|
| **Running a bot** (`tick`) | the app pod, in-BEAM via Wasmtime | CPU/memory abuse, escape, taking down the node |
| **Compiling a bot** (`rustc`, `tinygo`, `asc`, `clang`, `zig`) | the **builder** pod | malicious `build.rs` / post-install hooks / egress |

Keeping them apart is the whole point: the compile step never runs in the app
pod, and the run step never reaches a toolchain, the database, or the network.

## Layer 1 — the WASM runner (in-BEAM, done)

`Convoy.Engine.ColonyWasm` runs each module through Wasmtime (via `wasmex`) with:

- **Zero ambient authority** — an empty import set. A module reads the read-only
  colony view we write into its `inbuf` and returns a list of commands from its
  `outbuf`. That is the entire capability surface; there is no host call to abuse.
- **Fuel metering** — Wasmtime counts instructions; one per-tick budget per colony
  bounds CPU. An infinite loop exhausts fuel and **traps**; `wasmex` surfaces the
  trap as `{:error, _}` and the runner contains it as `{:ok, [], budget}` — the
  colony forfeits its turn (issues no commands) and nothing more.
- **`StoreLimits`** — a 16 MB linear-memory cap plus table/instance limits. A
  memory bomb is rejected at instantiation or denied the growth, never OOMing
  the node.
- **Crash containment** — wasm instances run under a dedicated `WasmSupervisor`,
  not linked to their region, so an instantiation crash is contained and
  surfaced as an error instead of taking the region down.

Proven, not asserted: see `test/convoy/colony_wasm_test.exs` (constrained
instantiation, deterministic fuel, infinite-loop containment, memory-bomb
rejection, unbounded-growth containment — and that the BEAM survives each).

## Layer 1 — the compile service (separate pod, done)

Compiling untrusted source is its own RCE surface. `Convoy.Compile` shrinks it
(single source file → `rustc`/`asc` with no manifest → no dependency fetches, no
build scripts; throwaway temp dir; hard timeout), and in production delegates to
a **separate, locked-down builder** (`CONVOY_BUILDER_URL` → `builder/`):

- `k8s/builder-deployment.yaml`: non-root (uid 10001), `seccompProfile:
  RuntimeDefault`, `capabilities: drop: [ALL]`, `allowPrivilegeEscalation:
  false`, `automountServiceAccountToken: false` (no cluster API), `emptyDir`
  build scratch with a size limit, CPU/memory limits.
- `k8s/builder-networkpolicy.yaml`: **egress denied** (`egress: []`). The compile
  is offline, so the builder never needs the network — and compiled untrusted
  code can't phone home, fetch dependencies, or pivot into the cluster.

Blast radius of a malicious compile = one throwaway pod with no secrets, no
token, and no network.

## Layer 2 — OS-level isolation for the runner (the seam)

The in-BEAM layer bounds CPU and allocation, but a NIF-level escape (a Wasmtime
or `wasmex` bug) would land inside the app pod. The primer's answer (§7/§10) is
to also wrap the runner in OS-level isolation: a **separate, locked-down node
pool** running a hardened sandbox runtime (gVisor or Firecracker), with strict
per-pod limits and no egress, autoscaled to active-player count.

What's in place toward it, and what remains:

- **Done:** the app pod is hardened like the builder — `automountServiceAccountToken:
  false`, `runAsNonRoot`, `capabilities: drop: [ALL]`, `seccompProfile:
  RuntimeDefault`, resource limits (`k8s/deployment.yaml`).
- **The seam:** `k8s/deployment.yaml` carries a commented `runtimeClassName:
  gvisor` + a `nodeSelector` for a `runner` pool. To turn it on:
  1. Install gVisor on a node pool and create a `RuntimeClass` named `gvisor`
     (or use Firecracker via Kata).
  2. Label those nodes `convoy.inevitable.fyi/pool=runner`.
  3. Uncomment the two stanzas and let Flux roll it.
  It's left commented so the app still schedules on a cluster without gVisor —
  uncommenting it on a cluster that lacks the RuntimeClass would leave the pod
  unschedulable.
- **Further (architectural):** the primer's strongest form splits the runner
  into its own process/pool that the sim core talks to over a pipe (so a NIF
  crash can't even touch the sim). `Convoy.Engine.ColonyWasm` is the seam for that;
  it's not split today.

## Other notes

- **Secrets** are runtime-injected via self-hosted Infisical; only the operator
  creds are SOPS-encrypted in the repo. The builder pod holds none.
- **No auth yet** on the hosted instance — `convoy.inevitable.fyi` is public on
  purpose. `/admin` should go behind auth before it's exposed more widely.
