# Forge & Convoy — Engineering Primer

**Core Architecture**

*Persistent-world programming game · WASM execution · Elixir/BEAM · scale-to-zero regions*

---

**Purpose of this document.** This is a build-spec primer for the engineer(s) standing up the core engine of Forge & Convoy. It captures the architecture decisions already made — a persistent world, WASM sandboxing with fuel metering, and a hot/warm/cold region activation model — and the reasoning behind them. It is deliberately opinionated about what to prototype first. Game content (resource balancing, tech-tree tuning, cosmetics) is explicitly out of scope here; this is about the engine those things will run on.

## 1. The Game in One Paragraph

You write code; your code is your only interface. Autonomous agents harvest resources, refine them, climb a tech ladder, and build out a base. Periodically you load goods onto a **convoy** and run it across contested territory to a **market**. The base-building loop is private, safe, and optimization-driven. The convoy run is the only contested moment — PvP is opt-in, scheduled by the act of sending a convoy, and decided by behavior programs written in advance. Bases are never attacked. The stake of a fight is the shipment, never your progress.

## 2. The Three Demands in Tension

A persistent programming game forces three goals that actively fight each other. Every architecture decision below is in service of resolving this tension.

1. **Determinism & fairness.** Every player gets equal compute; the sim must be reproducible for replays and dispute resolution.
2. **Continuous liveness.** The world must advance even when a player is logged out.
3. **Cost.** Naively simulating thousands of always-on bases at full tick rate is financially fatal.

The resolution: the world is **spatially partitioned**, **tick-deterministic**, and **selectively activated**. That last property — only spending compute where something meaningful is happening — is the load-bearing idea of the whole system.

## 3. Layered Architecture

Three layers must stay cleanly decoupled so each can be scaled and secured independently:

- **Simulation core** — authoritative world physics, tick loop, combat resolution. Owns all state mutation.
- **Code execution** — runs untrusted player WASM modules in a locked-down, separately-scaled tier. Never touches the database.
- **Persistence** — durable region state via snapshot + event log; doubles as the replay system.

**Hard rule:** player code never mutates the world. It receives a read-only snapshot and returns **intents** (MOVE, HARVEST, BUILD, FIRE…). The sim validates and resolves them authoritatively. This single rule is simultaneously the determinism foundation and the anti-cheat foundation.

## 4. Spatial Partitioning — Regions

Shard by **geography, not by player**. The map divides into regions (think of Screeps' rooms, but larger and fewer). A region is the atomic unit of three things at once:

- **Simulation ownership** — exactly one process is authoritative for a region at a time. No distributed consensus on physics; single-writer semantics for free.
- **Tick coordination** — entities interact only within a region or across an explicit border-crossing event, which bounds the interaction graph.
- **Activation state** — a region is hot, warm, or cold (see §5).

The convoy mechanic maps onto this cleanly: a convoy is an entity that **migrates across region boundaries**. Crossing into a contested market region is exactly when that region goes hot and PvP becomes possible. Border crossing is the one place needing a careful two-phase handoff between sim processes — everything else stays local.

## 5. Scale-to-Zero — the Cost-Killer

**Principle:** a region's simulation cost is proportional to whether anything meaningful is happening in it. Most of the map is idle at any given moment, so most of the map should cost nearly nothing.

| Tier | When | Behavior |
|------|------|----------|
| **Hot** | Owner is watching, a convoy is in transit, or combat is live. | Full tick rate (1–4 ticks/sec). Player code runs every tick within fuel budget. |
| **Warm** | Base runs autonomously; nobody watching, no conflict near. | Fast-forward analytically. Don't simulate 10,000 ticks of a harvester — compute the closed-form output when the region is next observed. |
| **Cold** | No activity, no pending convoys. | State serialized, process killed. Reactivation = deserialize + replay elapsed time analytically. Literal scale-to-zero. |

**The constraint this imposes on game design:** mechanics must be mostly **rate-based** (produce X per tick) so warm regions are fast-forwardable, with full tick-by-tick simulation reserved for hot moments (convoy runs, combat). This is an architecture decision driving a game-design decision — flag it to design early. Chaotic, event-dependent production chains that can't be solved in closed form break the cost model.

## 6. The Deterministic Tick Loop

Each hot region runs a fixed-step loop. Order and seeding are what make it fair and replayable:

```
for each tick:
  1. snapshot world state  (read-only view for player code)
  2. for each player entity in region:
       run WASM program with fuel budget  ->  collect intents
  3. validate all intents against current state
  4. resolve intents in deterministic order (e.g. by entity ID)
  5. apply physics / combat / resource changes
  6. emit events (replay log + clients)
  7. commit new state
```

- **Intents, never mutations.** Step 2 produces declarative desired actions; steps 3–5 resolve them authoritatively. A player can't teleport because the sim owns position.
- **Seeded determinism.** Any randomness derives from a per-tick seed of (region, tick number). Same inputs → same outputs, always.
- **Replays come free.** Store inputs + seed, re-run the loop. This is the convoy-ambush review experience and the dispute-resolution tool, at no extra cost.

## 7. WASM Sandbox & Fuel Metering

Player code is arbitrary, from strangers, running continuously at scale. The execution tier is **WASM via Wasmtime**, chosen over V8 isolates for two reasons:

- **Exact capability surface.** You control every host import, so player code has zero ambient authority — it can do precisely what you expose and nothing else.
- **Deterministic budgeting.** Wasmtime's fuel API counts instructions, which is more deterministic than wall-clock CPU time. Instruction-counting is the right basis for fairness and for bit-identical replays.

**Language story.** Players bring Rust, Go (TinyGo), AssemblyScript, or C — anything that compiles to WASM. To protect onboarding, ship a polished SDK for at least one easy language (AssemblyScript / JS-like) so a new player gets a working harvester in a handful of lines.

**Defense in depth.** The WASM fuel limit is the budget/ergonomics layer. Wrap the execution pool in OS-level isolation too (gVisor or Firecracker microVMs, seccomp, no network egress, hard CPU/memory caps, ephemeral). Player code only ever sees a serialized read-only snapshot and returns intents over a pipe — it never reaches the database or the sim core directly.

### Fuel budget as a game resource

- Per-tick fuel caps how much "thinking" each entity does — the real skill ceiling. Elegant code does more within budget.
- It can be a tech-tree reward (higher infrastructure → more budget) — but cap it or tie it strictly to in-game achievement. Never tie compute to money, or it becomes pay-to-win.
- Decide whether unused budget banks. Banking enables a thinking-burst saved for an ambush — an interesting convoy mechanic if intentional, a hoarding exploit if not.

## 8. Persistence

- **Snapshot + event log.** Periodic full region snapshots plus the intent/event stream between them. Recovery = load snapshot, replay events. This is also the replay system — same data, two uses.
- **Region = consistency boundary.** One process owns a hot region → single-writer, no distributed transactions within a region. The only cross-region coordination is convoy handoff.
- **Player memory.** Programs need persistent scratch state between ticks (Screeps' Memory object). Cap its size hard, serialize it with the region, treat it as untrusted bytes.
- **Store choice.** Region blobs are large-value, region-keyed, bursty writes. Start simple: object store for snapshots + fast KV for hot-region metadata. Reach for wide-column (Cassandra-style) only when region count and write fan-out actually demand it — not before.

## 9. Building on Elixir / BEAM

Elixir is a strong fit and the chosen platform. The BEAM's cheap processes, supervision trees, and built-in distribution map almost one-to-one onto this architecture.

| Architecture concept | BEAM mapping |
|----------------------|--------------|
| **Region sim** | A GenServer (or a small supervised process tree) owning one region's state and tick loop. Single-writer falls out naturally. |
| **Hot / warm / cold lifecycle** | Supervision + a region registry. Cold = process not started; state in the store. Warm = process alive, slow/analytical tick. Hot = full-rate tick. |
| **Entities** | Either plain data inside the region process, or their own processes if you want per-entity isolation. Start with data-in-region; promote only if needed. |
| **Sharding across nodes** | Distributed Erlang + a registry (Horde / `:global` / a custom registry) to locate the process owning a region. Convoy handoff = message to the destination region's process. |
| **Routing players** | Connect a player session to the process owning their currently-active region; reroute on border crossing. Conceptually the route-to-the-right-instance problem. |

### The one dependency to de-risk first: WASM in Elixir

Elixir runs WASM through a NIF binding to a host runtime — **wasmex**, which wraps Wasmtime and exposes fuel metering. This is the single load-bearing third-party dependency in the stack, so it must be the first thing proven. Verify, in this order:

1. You can instantiate a module with a constrained import set.
2. Fuel metering enforces a budget and is deterministic across runs.
3. A misbehaving module (infinite loop, OOM, fuel exhaustion) is contained without taking down the BEAM scheduler or the region process.

NIF crashes can take down the node, so confirm the failure-isolation story explicitly — consider running the WASM tier in separate OS processes / nodes from the sim core for that reason.

## 10. Mapping onto k8s (homelab-friendly)

- **Region sim = workload that scales to zero.** A controller watches a queue of regions-needing-activation and schedules sim pods; cold regions have no pod. This is an operator/reconciler pattern with a Region CRD bringing regions hot/warm/cold — the same namespace-as-unit pattern as agent "companies," applied to geography.
- **Code-runner pool = separate, locked-down node pool.** gVisor/Firecracker, autoscaled to active-player count, strict per-pod resource limits.
- **Observability.** Prometheus on tick latency, fuel-consumption distribution, region activation churn, and handoff success rate. Tick-budget-overrun rate is the key engine-health metric.

## 11. Prototype First — the Non-Negotiable Milestone

Before any game content, build and prove the core: the deterministic tick loop + one sandboxed WASM runtime (via wasmex) + region serialize / deserialize / replay. The acceptance test is concrete:

> **A region can go hot → cold → hot and produce bit-identical replays across the freeze.**

If that core is solid and reproducible, the rest is content on top. If it's flaky, no amount of game design saves the project. It is also the riskiest and least-reversible part of the system, which is exactly why it goes first.

## 12. Open Decisions to Resolve Early

1. **Tick rate & fuel budget numbers.** Pick starting values for hot tick rate and per-tick fuel; these set the whole feel and the cost envelope.
2. **Region size.** Larger regions = fewer handoffs but more per-process load. Tune against expected entity counts.
3. **Banking of unused fuel.** Decide deliberately — it's a real mechanic, not just a knob (see §7).
4. **Warm-state fast-forward coverage.** Enumerate which mechanics must be closed-form solvable. This bounds what design can ship.
5. **WASM failure isolation boundary.** In-BEAM NIF vs. separate OS process/node for the runner tier. Decide before scaling.

---

*Build order, distilled: prove WASM-in-Elixir + deterministic replay across a freeze, then the region lifecycle, then border-crossing handoff, then content.*
