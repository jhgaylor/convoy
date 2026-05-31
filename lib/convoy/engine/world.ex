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

  @type entity :: %{
          id: pos_integer(),
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
            delivered: 0,
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
          delivered: non_neg_integer(),
          events: [String.t()]
        }

  @resource_nodes 6
  @resource_amount 40
  @harvesters 3
  @cargo_max 5

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

    entities =
      for i <- 1..@harvesters do
        %{id: i, x: 0, y: 0, cargo: 0, cargo_max: @cargo_max, last_action: :idle}
      end

    %World{
      region_id: region_id,
      seed: seed,
      width: width,
      height: height,
      tick: 0,
      base: base,
      resources: resources,
      entities: entities,
      delivered: 0,
      events: ["Region #{region_id} initialized from seed #{seed}."]
    }
  end

  @doc "Total ore still sitting in the ground."
  @spec ore_remaining(t()) :: non_neg_integer()
  def ore_remaining(%World{resources: r}), do: r |> Map.values() |> Enum.sum()

  @doc "Resource amount at a cell (0 if none)."
  @spec resource_at(t(), pos()) :: non_neg_integer()
  def resource_at(%World{resources: r}, pos), do: Map.get(r, pos, 0)

  @doc "Nearest cell still holding ore, by Manhattan distance (deterministic tie-break)."
  @spec nearest_resource(t(), pos()) :: pos() | nil
  def nearest_resource(%World{resources: r}, {x, y}) do
    r
    |> Enum.filter(fn {_pos, amt} -> amt > 0 end)
    |> Enum.map(fn {pos, _amt} -> pos end)
    |> Enum.sort()
    |> Enum.min_by(fn {rx, ry} -> abs(rx - x) + abs(ry - y) end, fn -> nil end)
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
