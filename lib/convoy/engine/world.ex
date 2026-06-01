defmodule Convoy.Engine.World do
  @moduledoc """
  Authoritative, fully-deterministic world state for one region.

  A `World` is a plain immutable data structure. The simulation core
  (`Convoy.Engine.Sim`) owns all mutation of it; player code only ever
  receives a read-only view and returns intents (primer §3).

  Everything about a world is reproducible from `{seed}`: given the same
  seed and the same player program, the tick loop produces bit-identical
  results, which is the determinism / replay foundation (primer §6, §11).
  """

  alias Convoy.Engine.World

  @type pos :: {non_neg_integer(), non_neg_integer()}

  @type player_id :: String.t()

  @typedoc """
  A grid entity. `kind` is `:harvester` (player-controlled, mines/forges) or
  `:convoy` (auto-piloted shipment that runs to the market — see the Convoy
  section). A convoy's `cargo` is the goods it carries; `cargo_max` is unused
  for it.
  """
  @type entity :: %{
          id: pos_integer(),
          owner: player_id(),
          kind: :harvester | :convoy,
          x: non_neg_integer(),
          y: non_neg_integer(),
          cargo: non_neg_integer(),
          cargo_max: pos_integer(),
          last_action: atom()
        }

  @typedoc """
  A player's **base** — the Forge economy (primer §1). Delivered ore lands in
  `ore` (raw stockpile), the base refines it into `goods` at a tech-driven rate
  each tick, and `goods` are spent to climb the tech ladder or **loaded onto a
  convoy** and run to the market for `credits` (primer §1). `refined_total`
  (lifetime refined) and `credits` (lifetime shipment payoff) are both monotonic
  scores, untouched by spending.
  """
  @type tech :: :refine | :cargo | :fuel
  @type base :: %{
          ore: non_neg_integer(),
          goods: non_neg_integer(),
          refined_total: non_neg_integer(),
          credits: non_neg_integer(),
          tech: %{tech() => non_neg_integer()}
        }

  defstruct region_id: "alpha",
            seed: 1,
            width: 16,
            height: 12,
            tick: 0,
            base: {0, 0},
            market: {15, 11},
            resources: %{},
            entities: [],
            bases: %{},
            next_entity_id: 1,
            replenished: 0,
            events: []

  @type t :: %World{
          region_id: String.t(),
          seed: integer(),
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          base: pos(),
          market: pos(),
          resources: %{pos() => non_neg_integer()},
          entities: [entity()],
          bases: %{player_id() => base()},
          next_entity_id: pos_integer(),
          replenished: non_neg_integer(),
          events: [String.t()]
        }

  @resource_nodes 6
  @resource_amount 40
  @harvesters 3
  @cargo_max 5
  @default_player "p1"

  # --- convoys + the contested market (primer §1, §4) ---
  #
  # Goods can be loaded onto a convoy and run across the map to the market. A
  # convoy is an auto-piloted entity; reaching the market sells its shipment for
  # `credits`. The market is the only contested ground — when two players'
  # convoys meet on a cell, the lower-id one seizes the other's shipment (PvP).
  # Bases are never attacked; the stake of a fight is only the shipment (§1).
  @shipment_size 20
  # Successful delivery pays a premium over the goods spent — the reward for
  # risking the contested run instead of hoarding at base.
  @shipment_value 30

  # --- the Forge: refining + tech ladder (primer §1) ---
  #
  # All balancing knobs live here so retuning the economy never touches a bot:
  # the WASM ABI hands player code precomputed affordability flags, not costs.
  @base_refine_rate 1
  @cargo_step 5
  @base_fuel_budget 50_000
  @fuel_step 25_000
  @max_fuel_level 4
  # cost(level) = base * (level + 1): each tier costs more, so refine/cargo are
  # self-limiting; fuel is also hard-capped at @max_fuel_level (never pay-to-win).
  @build_cost %{refine: 10, cargo: 15, fuel: 25}
  @max_level %{fuel: @max_fuel_level}
  # Spawn a fresh deposit when the map drops to this many nodes (or fewer), so
  # a region can never be mined to a dead end.
  @replenish_threshold 1

  @doc """
  Build a fresh world deterministically from a seed.

  Resource placement uses a small LCG seeded only by `seed`, so the same
  seed always lays out the same map — a prerequisite for replay.
  """
  @spec generate(keyword()) :: t()
  def generate(opts \\ []) do
    seed = Keyword.get(opts, :seed, 1)
    region_id = Keyword.get(opts, :region_id, "alpha")
    width = Keyword.get(opts, :width, 16)
    height = Keyword.get(opts, :height, 12)
    base = {0, 0}
    # The market sits at the opposite corner from base — the far end of the
    # contested run. Deterministic, so replays and layouts stay reproducible.
    market = {width - 1, height - 1}

    {resources, _rng} = place_resources(seed, width, height, base)

    # A fresh world has NO players — they join explicitly via add_player/3
    # (a CLI/API submission, or the in-browser editor's Run). The browser is a
    # spectator until then.
    %World{
      region_id: region_id,
      seed: seed,
      width: width,
      height: height,
      tick: 0,
      base: base,
      market: market,
      resources: resources,
      entities: [],
      bases: %{},
      next_entity_id: 1,
      events: ["Region #{region_id} initialized from seed #{seed}."]
    }
  end

  @doc "The default player id used when a submission doesn't name one."
  @spec default_player() :: player_id()
  def default_player, do: @default_player

  @doc "How many harvesters a player gets when they join."
  @spec harvesters_per_player() :: pos_integer()
  def harvesters_per_player, do: @harvesters

  @doc """
  Add a player to the world: spawn their harvesters at base and start their
  score at 0. Idempotent — re-adding an existing player is a no-op (so a player
  resubmitting code keeps their entities).
  """
  @spec add_player(t(), player_id(), pos_integer()) :: t()
  def add_player(world, player_id, count \\ @harvesters)

  def add_player(%World{bases: bases} = world, player_id, _count)
      when is_map_key(bases, player_id),
      do: world

  def add_player(%World{} = world, player_id, count) do
    {bx, by} = world.base

    {new_entities, next_id} =
      Enum.map_reduce(1..count, world.next_entity_id, fn _i, id ->
        entity = %{
          id: id,
          owner: player_id,
          kind: :harvester,
          x: bx,
          y: by,
          cargo: 0,
          cargo_max: @cargo_max,
          last_action: :idle
        }

        {entity, id + 1}
      end)

    %{
      world
      | entities: world.entities ++ new_entities,
        bases: Map.put(world.bases, player_id, new_base()),
        next_entity_id: next_id,
        events: ["Player #{player_id} joined with #{count} harvesters." | world.events]
    }
  end

  # A freshly-joined player's base: empty stockpile, no goods/credits, tech L0.
  defp new_base,
    do: %{ore: 0, goods: 0, refined_total: 0, credits: 0, tech: %{refine: 0, cargo: 0, fuel: 0}}

  @doc """
  Remove a player from the world: drop their harvesters and their score.
  `next_entity_id` is left as-is so ids are never reused. No-op if absent.
  """
  @spec remove_player(t(), player_id()) :: t()
  def remove_player(%World{} = world, player_id) do
    if Map.has_key?(world.bases, player_id) do
      %{
        world
        | entities: Enum.reject(world.entities, &(&1.owner == player_id)),
          bases: Map.delete(world.bases, player_id),
          events: ["Player #{player_id} was kicked." | world.events]
      }
    else
      world
    end
  end

  @doc """
  A player's base (the empty base if they're unknown, so callers never crash on
  a missing or nil player — e.g. synthetic entities in unit tests).
  """
  @spec base(t(), player_id() | nil) :: base()
  def base(%World{bases: bases}, player_id), do: Map.get(bases, player_id, new_base())

  @doc """
  Deliver `amount` ore into a player's raw stockpile (`base.ore`). This is what
  `unload` does — the base refines it into goods over the following ticks.
  """
  @spec deposit_ore(t(), player_id(), non_neg_integer()) :: t()
  def deposit_ore(%World{} = world, player_id, amount) do
    update_base(world, player_id, fn b -> %{b | ore: b.ore + amount} end)
  end

  @doc "A player's leaderboard score = lifetime ore refined (0 if unknown)."
  @spec score(t(), player_id()) :: non_neg_integer()
  def score(%World{} = world, player_id), do: base(world, player_id).refined_total

  @doc "Per-player leaderboard map, `%{player => refined_total}`."
  @spec scoreboard(t()) :: %{player_id() => non_neg_integer()}
  def scoreboard(%World{bases: bases}), do: Map.new(bases, fn {p, b} -> {p, b.refined_total} end)

  @doc "Lifetime ore refined across all players (the headline number)."
  @spec total_refined(t()) :: non_neg_integer()
  def total_refined(%World{bases: bases}),
    do: bases |> Map.values() |> Enum.map(& &1.refined_total) |> Enum.sum()

  @doc "Raw ore sitting in every base's stockpile, not yet refined."
  @spec total_stockpile(t()) :: non_neg_integer()
  def total_stockpile(%World{bases: bases}),
    do: bases |> Map.values() |> Enum.map(& &1.ore) |> Enum.sum()

  @doc "Player ids present in the world."
  @spec players(t()) :: [player_id()]
  def players(%World{bases: bases}), do: Map.keys(bases)

  # --- the Forge: refining + tech ladder ---

  @doc """
  Refine every base by one tick: convert up to `refine_rate` ore into goods.

  Pure and **rate-based** (primer §5) — over N idle ticks the output is the
  closed form `min(stockpile, N · rate)`, which is exactly what makes a warm
  region fast-forwardable. The sim calls this once per tick after resolving
  intents; no events (it would flood the log every tick).
  """
  @spec refine_all(t()) :: t()
  def refine_all(%World{bases: bases} = world) do
    %{world | bases: Map.new(bases, fn {p, b} -> {p, refine_one(b)} end)}
  end

  defp refine_one(b) do
    n = min(b.ore, refine_rate(b))
    %{b | ore: b.ore - n, goods: b.goods + n, refined_total: b.refined_total + n}
  end

  defp refine_rate(b), do: @base_refine_rate + tech_level(b, :refine)

  @doc "The goods cost of a player's NEXT level in `tech`."
  @spec build_cost(t(), player_id(), tech()) :: pos_integer()
  def build_cost(%World{} = world, player_id, tech) when is_map_key(@build_cost, tech) do
    level = tech_level(base(world, player_id), tech)
    @build_cost[tech] * (level + 1)
  end

  @doc """
  Can `player_id` afford and is allowed to build the next level of `tech`?
  False if they lack the goods or the tech is capped (see `@max_level`). This
  is precomputed and handed to player code as a flag, so bots never need to
  know the cost formula.
  """
  @spec can_build?(t(), player_id() | nil, tech()) :: boolean()
  def can_build?(%World{} = world, player_id, tech) when is_map_key(@build_cost, tech) do
    b = base(world, player_id)
    level = tech_level(b, tech)
    capped? = match?(%{^tech => max} when level >= max, @max_level)
    not capped? and b.goods >= @build_cost[tech] * (level + 1)
  end

  def can_build?(_world, _player, _tech), do: false

  @doc """
  Build the next level of `tech` for a player: spend the goods and raise the
  level. Raising `cargo` also bumps `cargo_max` on every one of that player's
  harvesters. Assumes affordability was already checked (`can_build?/3`) — the
  sim validates before calling, so this is a pure state transition.
  """
  @spec build(t(), player_id(), tech()) :: t()
  def build(%World{} = world, player_id, tech) when is_map_key(@build_cost, tech) do
    cost = build_cost(world, player_id, tech)

    world
    |> update_base(player_id, fn b ->
      %{b | goods: b.goods - cost, tech: Map.update(b.tech, tech, 1, &(&1 + 1))}
    end)
    |> apply_tech(player_id, tech)
  end

  # cargo upgrades change the world (every owned harvester's capacity); refine
  # and fuel are read live from the base each tick, so nothing else to apply.
  defp apply_tech(world, player_id, :cargo) do
    cap = cargo_max_for(base(world, player_id))

    entities =
      Enum.map(world.entities, fn e ->
        if e.owner == player_id, do: %{e | cargo_max: cap}, else: e
      end)

    %{world | entities: entities}
  end

  defp apply_tech(world, _player_id, _tech), do: world

  @doc "A player's per-harvester cargo capacity given their cargo tech level."
  @spec cargo_max_for(base()) :: pos_integer()
  def cargo_max_for(b), do: @cargo_max + tech_level(b, :cargo) * @cargo_step

  @doc """
  A player's per-tick fuel budget (primer §7: compute as a tech reward, capped).
  Derived from their `fuel` tech level so replays stay deterministic.
  """
  @spec fuel_budget(t(), player_id() | nil) :: pos_integer()
  def fuel_budget(%World{} = world, player_id),
    do: @base_fuel_budget + tech_level(base(world, player_id), :fuel) * @fuel_step

  @doc "The floor (level-0) fuel budget, for display."
  @spec base_fuel_budget() :: pos_integer()
  def base_fuel_budget, do: @base_fuel_budget

  @doc "A base's level in `tech` (0 if absent)."
  @spec tech_level(base(), tech()) :: non_neg_integer()
  def tech_level(b, tech), do: Map.get(b.tech, tech, 0)

  defp update_base(%World{} = world, player_id, fun) do
    %{world | bases: Map.update(world.bases, player_id, fun.(new_base()), fun)}
  end

  # --- convoys + the contested market (primer §1, §4) ---

  @doc "The market sell-point — the far end of the contested run."
  @spec market(t()) :: pos()
  def market(%World{market: m}), do: m

  @doc "Goods cost to launch a convoy."
  @spec shipment_size() :: pos_integer()
  def shipment_size, do: @shipment_size

  @doc "Credits a delivered shipment is worth (a premium over the goods spent)."
  @spec shipment_value() :: pos_integer()
  def shipment_value, do: @shipment_value

  @doc "Can a player afford to load a convoy (enough goods for one shipment)?"
  @spec can_launch?(t(), player_id() | nil) :: boolean()
  def can_launch?(%World{} = world, player_id), do: base(world, player_id).goods >= @shipment_size

  @doc """
  Launch a convoy for a player: spend `@shipment_size` goods and spawn an
  auto-piloted convoy entity at base carrying a shipment worth `@shipment_value`
  credits. Assumes affordability was checked (`can_launch?/2`).
  """
  @spec launch_convoy(t(), player_id()) :: t()
  def launch_convoy(%World{} = world, player_id) do
    {bx, by} = world.base

    convoy = %{
      id: world.next_entity_id,
      owner: player_id,
      kind: :convoy,
      x: bx,
      y: by,
      cargo: @shipment_value,
      cargo_max: @shipment_value,
      last_action: :launch
    }

    world
    |> update_base(player_id, fn b -> %{b | goods: b.goods - @shipment_size} end)
    |> Map.update!(:entities, &(&1 ++ [convoy]))
    |> Map.update!(:next_entity_id, &(&1 + 1))
  end

  @doc "Credit a delivered shipment to a player's lifetime `credits`."
  @spec credit_market(t(), player_id(), non_neg_integer()) :: t()
  def credit_market(%World{} = world, player_id, amount) do
    update_base(world, player_id, fn b -> %{b | credits: b.credits + amount} end)
  end

  @doc "A player's lifetime market credits (0 if unknown)."
  @spec credits(t(), player_id()) :: non_neg_integer()
  def credits(%World{} = world, player_id), do: base(world, player_id).credits

  @doc "Lifetime credits earned across all players."
  @spec total_credits(t()) :: non_neg_integer()
  def total_credits(%World{bases: bases}),
    do: bases |> Map.values() |> Enum.map(& &1.credits) |> Enum.sum()

  @doc "Is this entity a convoy?"
  @spec convoy?(entity()) :: boolean()
  def convoy?(%{kind: :convoy}), do: true
  def convoy?(_), do: false

  @doc "All convoy entities, sorted by id (deterministic)."
  @spec convoys(t()) :: [entity()]
  def convoys(%World{entities: es}), do: es |> Enum.filter(&convoy?/1) |> Enum.sort_by(& &1.id)

  @doc "Remove an entity by id (a convoy that sold or was seized)."
  @spec remove_entity(t(), pos_integer()) :: t()
  def remove_entity(%World{} = world, id),
    do: %{world | entities: Enum.reject(world.entities, &(&1.id == id))}

  @doc "The ore amount a freshly-spawned (or generated) deposit holds."
  @spec resource_amount() :: pos_integer()
  def resource_amount, do: @resource_amount

  @doc "How many distinct deposits still hold ore."
  @spec resource_node_count(t()) :: non_neg_integer()
  def resource_node_count(%World{resources: r}), do: map_size(r)

  @doc """
  If the map has dwindled to its last deposit (or fewer), add a fresh one at a
  deterministic free cell and return `{world, spawned_pos}`. Otherwise return
  `{world, nil}` unchanged.

  Placement derives from `{seed, tick}` so replays stay bit-identical (§6) — no
  wall-clock, no `:rand`. The sim calls this each tick after resolving intents.
  """
  @spec maybe_spawn_resource(t()) :: {t(), pos() | nil}
  def maybe_spawn_resource(%World{} = world) do
    if map_size(world.resources) <= @replenish_threshold do
      pos = spawn_cell(world)

      world = %{
        world
        | resources: Map.put(world.resources, pos, @resource_amount),
          replenished: world.replenished + 1
      }

      {world, pos}
    else
      {world, nil}
    end
  end

  @doc "Total ore still sitting in the ground."
  @spec ore_remaining(t()) :: non_neg_integer()
  def ore_remaining(%World{resources: r}), do: r |> Map.values() |> Enum.sum()

  @doc "Resource amount at a cell (0 if none)."
  @spec resource_at(t(), pos()) :: non_neg_integer()
  def resource_at(%World{resources: r}, pos), do: Map.get(r, pos, 0)

  @doc "Nearest cell still holding ore, by Manhattan distance (deterministic tie-break)."
  @spec nearest_resource(t(), pos()) :: pos() | nil
  def nearest_resource(%World{} = world, pos), do: pick_resource(world, pos, &Enum.min_by/3)

  @doc "Farthest cell still holding ore, by Manhattan distance (deterministic tie-break)."
  @spec farthest_resource(t(), pos()) :: pos() | nil
  def farthest_resource(%World{} = world, pos), do: pick_resource(world, pos, &Enum.max_by/3)

  defp pick_resource(%World{resources: r}, {x, y}, chooser) do
    r
    |> Enum.filter(fn {_pos, amt} -> amt > 0 end)
    |> Enum.map(fn {pos, _amt} -> pos end)
    |> Enum.sort()
    |> chooser.(fn {rx, ry} -> abs(rx - x) + abs(ry - y) end, fn -> nil end)
  end

  @doc """
  Greedy Manhattan step from one cell toward another: close the x gap first,
  then y. Returns a `{dx, dy}` unit step. Deterministic — shared by every
  code backend so navigation is identical regardless of language.
  """
  @spec step_toward(pos(), pos()) :: {-1..1, -1..1}
  def step_toward({x, y}, {tx, ty}) do
    cond do
      x < tx -> {1, 0}
      x > tx -> {-1, 0}
      y < ty -> {0, 1}
      y > ty -> {0, -1}
      true -> {0, 0}
    end
  end

  @doc """
  Deterministic pseudo-random move direction keyed by `{seed, tick, entity_id}`.
  Never wall-clock or `:rand`, so replays stay bit-identical (primer §6).
  """
  @spec wander_dir(integer(), non_neg_integer(), term()) :: {-1..1, -1..1}
  def wander_dir(seed, tick, entity_id) do
    case rem(:erlang.phash2({seed, tick, entity_id}), 4) do
      0 -> {1, 0}
      1 -> {-1, 0}
      2 -> {0, 1}
      _ -> {0, -1}
    end
  end

  # --- deterministic spawn placement ---

  # Pick a free cell (not the base, not an existing deposit) deterministically
  # from {seed, tick}, probing forward until one is free.
  defp spawn_cell(%World{} = world) do
    base_hash = :erlang.phash2({world.seed, world.tick})
    find_free_cell(world, base_hash, 0)
  end

  defp find_free_cell(%World{width: w, height: h, base: base} = world, base_hash, attempt)
       when attempt < w * h do
    n = :erlang.phash2({base_hash, attempt})
    pos = {rem(n, w), rem(div(n, w), h)}

    if pos == base or Map.has_key?(world.resources, pos) do
      find_free_cell(world, base_hash, attempt + 1)
    else
      pos
    end
  end

  # Grid is entirely full of deposits — can't happen below the threshold, but
  # fall back to the base cell rather than loop forever.
  defp find_free_cell(%World{base: base}, _base_hash, _attempt), do: base

  # --- deterministic generation helpers ---

  defp place_resources(seed, width, height, base) do
    # Linear congruential generator — fully deterministic from seed.
    Enum.reduce(1..@resource_nodes, {%{}, seed_state(seed)}, fn _i, {acc, rng} ->
      {pos, rng} = pick_free_cell(acc, base, width, height, rng)
      {Map.put(acc, pos, @resource_amount), rng}
    end)
  end

  defp pick_free_cell(acc, base, width, height, rng) do
    {rng, x} = next(rng, width)
    {rng, y} = next(rng, height)
    pos = {x, y}

    if pos == base or Map.has_key?(acc, pos) do
      pick_free_cell(acc, base, width, height, rng)
    else
      {pos, rng}
    end
  end

  defp seed_state(seed), do: rem(abs(seed) * 2_654_435_761 + 1, 2_147_483_647)

  defp next(state, bound) do
    state = rem(state * 1_103_515_245 + 12_345, 2_147_483_648)
    {state, rem(state, bound)}
  end
end
