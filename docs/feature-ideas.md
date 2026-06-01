# Forge & Convoy — Feature Ideas (running list)

> Working doc for Jake + Claude. Started 2026-06-01 while Jake was at breakfast.
> Curated, ranked, and grounded in the actual code. Top picks first; full
> catalog below. We'll dig into the starred ones together.
>
> **➡️ Direction chosen (2026-06-01):** make it engaging *to play* via a colony
> model — one brain commands a base you build out spatially, slow time+cost pacing.
> Full design (reviewed) in **`docs/colony-v2-design.md`**. The catalog below stays
> as the backlog of fun once the colony loop lands (replay viewer, ghosts, market
> depth, etc. all still apply on top of it).

## Where the game is today (so we don't re-propose what exists)

The loop, in one breath: **WASM bots → harvesters mine ore in *private* rooms →
the base forges ore into goods → spend goods on a 3-branch tech ladder
(refine / cargo / fuel) → load goods onto a *convoy* → run it across ONE *shared,
contested* market → convoys collide & seize each other's shipments (PvP) →
credits = the score.**

Already built and solid:
- Deterministic tick loop (`Sim.tick/2`), intents-not-mutations, seeded RNG.
- Event log + snapshot persistence — the **replay substrate exists** but isn't surfaced.
- Persistent bot linear-memory across ticks *and* freeze/thaw.
- Optional `convoy` steering export (defend / hunt / advance).
- Hot/warm/cold region activation; live-tunable balance config (admin panel).
- Spectator LiveView: scoreboard, trends sparklines (value/dⁿ/dt), per-room
  grids, entity cards, event log. Admin ops page.

The three biggest *gaps* (each is also a top pick below):
1. **It's a programming game you can't write code in** — the page shows read-only
   starter code and tells you to `curl`/upload. No in-browser editor.
2. **The replay substrate is built but invisible** — determinism + event log were
   designed for "the convoy-ambush review experience" (primer §6). Nothing plays it back.
3. **The one contested space is a featureless grid** — the market is just empty
   cells between an entry door and a sell point. The headline mechanic has no terrain, no economics.

---

## ★ Top picks (where I'd start)

### 1. ★ Replay viewer / "ambush theater"
**Why:** The architecture was *built for this* — deterministic loop + event log +
snapshots (primer §6 literally names "the convoy-ambush review experience"). It's
the highest payoff-to-novelty ratio: turns a live-only spectator into something
you can scrub, share, and learn from. Shareable replay links (`/replay/<region>/<from>-<to>`)
are a viral/onboarding loop too.
**Shape:** scrub bar over a tick range; re-run `Sim.tick` from a snapshot to
regenerate exact intermediate frames (it's deterministic, so we don't have to store
every frame — *feasibility agent is confirming what's stored vs. needs storing*).
Auto-jump-to-ambush ("next collision") buttons. Reuse the existing room-grid render.
**Effort:** Medium. **Impact:** High.

### 2. ★ In-browser code editor + live compile
**Why:** Biggest onboarding unlock. It's a *programming* game whose own page can't
run code — the friction from "read starter code" to "playing" is a curl command.
The compile pipeline (`Compile.to_wasm/2`, builder service) and submit path
(`Loader.prepare/2` → `Engine.submit_player/5`) already exist and are reused by upload.
**Shape:** editor (textarea → Monaco/CodeMirror) per language tab pre-filled with the
template, a Submit button, inline compile-error panel, optional "test in a private
sandbox region first." *Feasibility agent is checking if the compile call is safe to
run synchronously from the LiveView (timeouts/blocking).*
**Effort:** Medium. **Impact:** High.

### 3. ★ A living market (terrain + price dynamics)
**Why:** The market is the *only* contested ground and the headline mechanic, but
it's an empty grid — so convoy steering barely matters and launch timing only
matters for raw collision odds. Give the contested space real texture.
**Ideas (all deterministic, mostly config-driven):**
- **Terrain:** chokepoints/walls, hazard cells (lose cargo), bonus cells (+credits),
  fast lanes. Forces real pathing decisions in the `convoy` export.
- **Supply-driven price decay:** `shipment_value` falls as goods flood the market
  this window and recovers over time → punishes everyone dumping at once, rewards
  spacing and reading the board. (The strategist bots already cooldown-space convoys;
  this gives that a *reason* beyond ambush.)
- **Multiple markets / arbitrage:** a near market (cheap, safe) vs. a far market
  (lucrative, contested) — a real risk/reward steering choice.
**Effort:** Low–Medium per piece. **Impact:** High (deepens the core fight).

### 4. ★ Self-seeding "ghost" opponents (cold-start killer)
**Why:** Right now the contested market — the whole point — is empty until a
second human shows up. We already persist every player's program bytes + memory
in the snapshot, so we can re-launch *past bot versions* (yours or others') as AI
rivals in a region. A solo player instantly has someone to ambush, and can race
their own previous self. Borrowed from Screeps Arena; near-free given what's
already stored. Makes every other feature here more fun by guaranteeing the arena
is never empty.
**Effort:** Low–Medium. **Impact:** High (unblocks the core loop for solo play).

---

## Proven mechanics worth stealing (from comparable games)

Distilled from Screeps, Battlecode, Halite, Robocode, CodinGame, Bitburner, and
Screeps Arena. The ones that **exploit infrastructure we already have** are
marked ⚡ (cheapest wins given the seeded event-log + persisted-program-bytes
architecture).

- **⚡ Self-seed players' past bot versions as opponents (Screeps Arena).** The
  single best fix for our cold-start problem: a 2-player market feels dead until
  a second human shows up. We already persist each player's `{backend, exec,
  source, memory}` in the snapshot — so we can drop old bot versions (yours or
  others') into a region as ranked AI opponents. Every solo player gets a worthy
  rival immediately, and can literally race their past self. *High impact, low
  effort given what's stored.*
- **⚡ Compute-fuel "bucket" economy (Screeps' killer hook).** Turn the existing
  fuel branch from a flat per-tick cap into a **bankable resource**: unused fuel
  banks up to a cap, so a bot idles cheap while mining and **bursts** expensive
  pathfinding/decisions on a contested convoy run. This is exactly the primer §7
  "banking" open decision — and it makes the third tech branch *active strategy*
  instead of a passive number. Deterministic (it's just per-entity state).
- **⚡ Always-on ELO/TrueSkill ladder, no deadline (Halite).** "Submit anytime,
  climb forever" is the proven retention spine for async programming games, and
  scoring is already deterministic. Pairs with accounts/auth.
- **Tiered leagues with reference-bot boss gates (CodinGame).** Don't drown a
  newcomer in harvest+forge+convoy+market PvP at once. Gate by division: Wood =
  mine & refine only (PvE) → beat a reference bot → unlock convoys → top division
  unlocks the contested market. Boss bots also populate a thin ladder. Solves
  new-player overwhelm in a genuinely multi-system game.
- **Prestige / region cash-out (Bitburner).** Let a player "cash out" a region for
  a permanent multiplicative perk (+refine, cheaper tech, bigger fuel cap) that
  resets world progress **but keeps their bot code**. Thematically perfect — the
  bot *is* the asset — and each re-run is faster, giving a mastery arc beyond one
  climb. The 3-branch ladder is a natural augmentation tree.
- **Seasonal resets with rotating themes/rules (Battlecode).** Periodically reroll
  ore distribution / tech costs / a market rule so the meta churns, returning and
  new players are on even footing, and there's a recurring "new season" hook.
- **Designed-scarcity inter-agent comms (Battlecode).** A tiny limited-byte channel
  between a player's convoys and harvesters (vs. a free global) makes coordinating
  a market push a real engineering puzzle. Fits the fuel/skill-ceiling philosophy.

---

## Gameplay mechanics (catalog)

- **NPC bandits / neutral raiders.** Deterministic (tick-seeded) bandit convoys
  that prowl the market and ambush *everyone*. Gives solo players a threat and
  drama even before a second human joins — solves the "empty arena feels dead"
  problem. Difficulty as a config knob.
- **More tech branches.** The ladder is only refine/cargo/fuel. Add:
  - **Speed** (convoy moves 2 cells/tick),
  - **Armor** (survive one ambush instead of instant seizure),
  - **Stealth** (invisible to enemies' `enemy_dx/dy` until adjacent),
  - **Scan/range** (richer convoy view: see further, predict collisions).
  Each is a new intent code + a config-priced level; fits the existing `build` path.
- **Convoy HP / multi-tick combat.** Replace instant seize with a short skirmish
  (convoys trade blows over a few ticks) so escorts, armor, and disengaging matter.
  Bigger change to `resolve_market`, but turns ambushes into *fights*.
- **Escort convoys.** Launch a cheap unarmed-but-defending convoy alongside a cargo
  run; the defend mechanic already exists, this just lets you stack it intentionally.
- **Scheduled world events (deterministic, tick-keyed).** Ore rush (richer deposits),
  market boom (`shipment_value` spike), bandit season, fuel crisis (budgets cut).
  Trivial to make replay-safe since everything keys off tick/seed. Adds rhythm.
- **Fuel banking.** Primer §7 open decision: let unused per-tick fuel bank up to a
  cap, enabling a saved "thinking burst" for an ambush. Flagged as a real mechanic.
- **Alliances / team play.** Allied convoys don't seize each other; team scoreboard.
  Turns the market into politics. (Needs a player-relationship concept — bigger.)
- **Daily/weekly challenge regions.** Fixed seed + locked config + a goal
  (most credits in N ticks). Everyone competes on the identical map; leaderboard
  resets. Strong recurring-engagement hook (Battlecode/Halite-style).

## Player-facing UI (catalog)

- **Smooth movement + "market cam."** Entities snap cell-to-cell today. CSS
  transitions for harvester/convoy movement + an auto-focus on the market when
  convoys are about to collide = spectating goes from "data" to "delightful."
  Cheap, high charm.
- **Per-player dashboard.** Click a player → full economy, tech timeline, convoy
  win/loss record, their best ambushes. Today it's a single scoreboard row.
- **Market intel overlay.** Predicted convoy paths, collision forecasts, an
  ambush heatmap (where seizures historically happen). Makes the board readable.
- **Achievements / milestones.** First convoy, first ambush, first 1k credits,
  10-convoy win streak. Cheap dopamine + onboarding signposts.
- **Optional sound.** Subtle blips on harvest / sell / ambush. Toggle off by default.
- **Bot version history.** See your past submissions, diff them, roll back. Pairs
  with the in-browser editor.

## Onboarding / developer experience (catalog)

- **Interactive ABI playground / tutorial.** Guided first bot: step through what
  each intent code does on a tiny map, "make the harvester pick up ore," etc.
- **Practice/sandbox region.** Test your bot alone (own seed, reset button) before
  joining the contested arena. Pairs with the editor.
- **Per-harvester "why did it do that" inspector.** Surface the decided intent code
  per entity per tick in the UI — a debugger for your own bot's decisions.
- **Real language SDKs.** A `convoy-sdk` Rust crate / AS module with a typed `View`
  struct + `Intent` enum so people stop hand-decoding 14 i32 params. Lowers the
  single biggest authoring friction.

## Meta / social / competitive (catalog)

- **Global leaderboard + persistent identity (auth).** Currently no auth; the
  hosted instance is intentionally public. A real ladder needs accounts.
- **Tournament ladder / ranked seasons.** Auto-run submitted bots head-to-head in
  fresh regions, ELO/MMR, seasonal resets. The competitive backbone.
- **Shareable replay links + social embeds.** (Pairs with #1.)
- **Spectator reactions/chat.** Lightweight liveness on popular regions.

## Engine / advanced (catalog — lower "fun", high architectural payoff)

- **Analytical warm fast-forward (primer §5 open problem).** Closed-form refine
  jump for warm regions (the production side is already rate-based and solvable).
- **Wire the cross-region market into the main flow (primer §4 "not yet built").**
  Real multi-region topology; leans on the event log as replay source of record.

---

## Open questions for our session
- What's the **audience** right now — you + friends, or a public ladder? (Changes
  whether auth/seasons matter vs. pure single-region fun.)
- Is the near-term goal **make it fun to watch**, **fun to write bots for**, or
  **fun to compete in**? (Maps to picks 1, 2, 3 respectively.)
- Appetite for **engine-deep** work (combat model, multi-region) vs.
  **surface wins** (editor, replay, animation) this session?

## Notes / findings (filled in as research agents report back)
- **Comparable-games research: done** (Screeps, Battlecode, Halite, Robocode,
  CodinGame, Bitburner, Screeps Arena). Findings folded into "Proven mechanics
  worth stealing" above. Headline: the cheapest high-impact wins all ride our
  existing seeded-event-log + persisted-program-bytes architecture — **replay
  viewer** (Halite), **self-seeding past bot versions to kill cold-start**
  (Screeps Arena), the **fuel-bucket economy** (Screeps), and **deterministic ELO**
  (Halite). Robocode says: make the market-collision moment a first-class,
  clip-worthy spectator render — that's our hero shot.

- **Replay-viewer feasibility: CONFIRMED feasible, ~MVP in 1 focused day.**
  - The chain is all there: snapshots persist `{world@tickT, program bytes, bot
    memory, config, seed}` (every 50 ticks, `Region @snapshot_every`), the event
    log is tick-stamped control events (`submit/kick/reset/arrival/config`), and
    `Sim.tick` is pure. So **re-running from a snapshot regenerates bit-identical
    intermediate frames** — we do *not* need to store every frame.
  - **What to build:** a `Convoy.Replay` module (`load_at_tick(region, tick)` =
    nearest snapshot ≤ tick → reinstantiate WASM w/ saved memory → run
    `Sim.tick` forward, applying control events at their ticks), an
    `Engine.seek_to_tick/2`, and a scrubber component in `sim_live.ex`. Est.
    ~180–250 LOC, ~9–10h incl. tests.
  - **Gotchas to design around:** (a) a `reset` between snapshot and target means
    replay from a *later* snapshot, not just applying events — need a snapshot
    index by tick; (b) cross-region convoys (`departing`/`pending_credits`) lose
    context if replayed in isolation — but the **default main region is
    neighbor-less and fully self-contained**, so the headline replay is clean;
    (c) seeking is O(ticks since last snapshot) WASM calls — fine at 50-tick
    snapshots; cache frames or snapshot more often for buttery scrubbing.
  - **Takeaway:** lowest-risk of the three top picks — it rides rails that already
    have a passing determinism test suite. Start here for a fast, demoable win.

- **In-browser-editor feasibility: CONFIRMED feasible, mostly frontend.**
  - The whole submit path already exists and is reused by file upload:
    `Loader.prepare/2` → `Engine.submit_player/5`, and **compile errors are
    already part of region state and broadcast to spectators** (the scoreboard
    shows a per-player ⛔ with the error in its title). So a paste-and-submit
    editor mostly needs a `<textarea>` (→ Monaco/CodeMirror later), a language
    select pre-filled from `Compile.template/1`, and a `submit_code` event.
  - **The one real gotcha:** compilation is **synchronous and slow** — local
    toolchains block up to 20s, the remote builder up to 30s. Calling
    `Loader.prepare/2` straight from the LiveView handler would freeze that
    socket. **Fix:** run it in a `Task.Supervisor.async` and handle the result in
    `handle_info/2`, showing a "Compiling…" state meanwhile. Only backend change
    needed: add `{Task.Supervisor, name: Convoy.TaskSupervisor}` to the app
    supervision tree. Loader/Compile/Engine all stay untouched.
  - **Production safety is already handled:** when `CONVOY_BUILDER_URL` is set,
    compilation delegates to the isolated builder pod (no egress) — the editor
    rides the same path as the HTTP API, so it adds no new RCE surface.
  - **Takeaway:** highest *onboarding* leverage, low backend risk; the work is
    ~1 LiveView event + 1 component + 1 supervisor line, plus editor polish.
</content>
</invoke>
