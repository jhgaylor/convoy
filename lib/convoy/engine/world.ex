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

  @type entity :: %{
          id: pos_integer(),
          owner: player_id(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          cargo: non_neg_integer(),
          cargo_max: pos_integer(),
          last_action: atom()
        }

  defstruct region_id: "alpha",
            seed: 1,
            width: 16,
            height: 12,
            tick: 0,
            base: {0, 0},
            resources: %{},
            entities: [],
            scores: %{},
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
          resources: %{pos() => non_neg_integer()},
          entities: [entity()],
          scores: %{player_id() => non_neg_integer()},
          next_entity_id: pos_integer(),
          replenished: non_neg_integer(),
          events: [String.t()]
        }

  @resource_nodes 6
  @resource_amount 40
  @harvesters 3
  @cargo_max 5
  @default_player "p1"
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

    {resources, _rng} = place_resources(seed, width, height, base)

    %World{
      region_id: region_id,
      seed: seed,
      width: width,
      height: height,
      tick: 0,
      base: base,
      resources: resources,
      entities: [],
      scores: %{},
      next_entity_id: 1,
      events: ["Region #{region_id} initialized from seed #{seed}."]
    }
    # Seed a default player so solo play (and tests) start with harvesters.
    |> add_player(@default_player)
  end

  @doc "The default player id (the one the in-browser editor controls)."
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

  def add_player(%World{scores: scores} = world, player_id, _count)
      when is_map_key(scores, player_id),
      do: world

  def add_player(%World{} = world, player_id, count) do
    {bx, by} = world.base

    {new_entities, next_id} =
      Enum.map_reduce(1..count, world.next_entity_id, fn _i, id ->
        entity = %{
          id: id,
          owner: player_id,
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
        scores: Map.put(world.scores, player_id, 0),
        next_entity_id: next_id,
        events: ["Player #{player_id} joined with #{count} harvesters." | world.events]
    }
  end

  @doc "Credit ore to a player's score."
  @spec credit(t(), player_id(), non_neg_integer()) :: t()
  def credit(%World{} = world, player_id, amount) do
    %{world | scores: Map.update(world.scores, player_id, amount, &(&1 + amount))}
  end

  @doc "A player's delivered total (0 if unknown)."
  @spec score(t(), player_id()) :: non_neg_integer()
  def score(%World{scores: scores}, player_id), do: Map.get(scores, player_id, 0)

  @doc "Ore delivered across all players."
  @spec total_delivered(t()) :: non_neg_integer()
  def total_delivered(%World{scores: scores}), do: scores |> Map.values() |> Enum.sum()

  @doc "Player ids present in the world."
  @spec players(t()) :: [player_id()]
  def players(%World{scores: scores}), do: Map.keys(scores)

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
