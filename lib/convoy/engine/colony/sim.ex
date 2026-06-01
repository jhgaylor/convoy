defmodule Convoy.Engine.Colony.Sim do
  @moduledoc """
  The deterministic colony tick loop (Forge & Convoy v2, primer §6).

  `tick/2` is pure: `(world, brain) -> world`, where `brain` is
  `(World.t -> [command])` — a list of decoded `%{op, target, a, b}` commands
  (see `Convoy.Engine.ColonyAbi`). The brain never mutates the world; the Sim
  resolves its commands authoritatively against the *accumulating* world so
  single-writer semantics hold (two units can't take the same last ore). Same
  world + same brain → same next world (bit-identical replay).

  Resolution order is the brain's emission order, which is itself deterministic,
  so the loop is reproducible. Buildings + spawns advance on deterministic timers
  (`World.advance/1`); refining is rate-based.
  """

  import Bitwise, only: [bsr: 2, band: 2]
  alias Convoy.Engine.Colony.World

  # Command ops — match Convoy.Engine.ColonyAbi.
  @op_harvest 1
  @op_move 2
  @op_transfer 3
  @op_build 4
  @op_spawn 5
  @op_launch 7

  @doc "Advance the colony one tick: run the brain, resolve its commands, advance timers/refining."
  @spec tick(World.t(), (World.t() -> [map()])) :: World.t()
  def tick(%World{} = world, brain) when is_function(brain, 1) do
    commands = brain.(world)
    apply_commands(world, commands)
  end

  @doc "Resolve a decoded command list, then advance timers + refining + replenish + tick."
  @spec apply_commands(World.t(), [map()]) :: World.t()
  def apply_commands(%World{} = world, commands) when is_list(commands) do
    world
    |> then(fn w -> Enum.reduce(commands, w, &resolve(&2, &1)) end)
    |> World.advance()
    |> replenish()
    |> Map.update!(:tick, &(&1 + 1))
  end

  @doc "Run `n` ticks (replay / fast-forward verification)."
  def run(world, brain, n) when n > 0, do: Enum.reduce(1..n, world, fn _i, w -> tick(w, brain) end)
  def run(world, _brain, _n), do: world

  # --- command resolution (the sim owns all mutation) ---

  defp resolve(world, %{op: @op_move, target: id, a: dx, b: dy}) do
    case World.unit(world, id) do
      nil -> world
      u -> World.update_unit(world, id, &%{&1 | x: clamp(u.x + sign(dx), cfg(world, :width)), y: clamp(u.y + sign(dy), cfg(world, :height))})
    end
  end

  defp resolve(world, %{op: @op_harvest, target: id}) do
    case World.unit(world, id) do
      nil ->
        world

      u ->
        pos = {u.x, u.y}
        available = World.deposit_at(world, pos)
        space = u.cargo_max - u.cargo

        if available > 0 and space > 0 do
          taken = min(available, space)

          world
          |> World.deplete(pos, taken)
          |> World.update_unit(id, &%{&1 | cargo: &1.cargo + taken})
        else
          world
        end
    end
  end

  defp resolve(world, %{op: @op_transfer, target: id, a: dest_id}) do
    u = World.unit(world, id)
    dest = World.building(world, dest_id)

    if u && dest && dest.built && u.cargo > 0 and adjacent?({u.x, u.y}, {dest.x, dest.y}) do
      world
      |> World.add_ore(u.cargo)
      |> World.update_unit(id, &%{&1 | cargo: 0})
    else
      world
    end
  end

  defp resolve(world, %{op: @op_build, a: kind, b: packed}) do
    pos = {band(bsr(packed, 8), 0xFF), band(packed, 0xFF)}
    spec = World.build_spec(world, kind)

    cond do
      spec == nil -> world
      not in_grid?(world, pos) -> world
      World.building_at(world, pos) != nil -> world
      true ->
        {cost, time} = spec

        if world.goods >= cost do
          world
          |> World.spend_goods(cost)
          |> World.place_building(kind, pos, time)
          |> World.note("Queued #{World.kind_name(kind)} at #{fmt(pos)} (-#{cost} goods, #{time} ticks).")
        else
          world
        end
    end
  end

  defp resolve(world, %{op: @op_spawn, a: kind}) do
    spec = World.spawn_spec(world, kind)
    has_spawner = World.finished_buildings(world, 0) != []

    cond do
      spec == nil -> world
      not has_spawner -> world
      World.population(world) >= World.pop_cap(world) -> world
      true ->
        {cost, time} = spec

        if world.goods >= cost do
          world
          |> World.spend_goods(cost)
          |> World.enqueue_spawn(kind, time)
          |> World.note("Spawning #{World.unit_kind_name(kind)} (-#{cost} goods, #{time} ticks).")
        else
          world
        end
    end
  end

  defp resolve(world, %{op: @op_launch}) do
    if World.can_launch?(world), do: World.launch(world), else: world
  end

  # Unknown / idle / upgrade / convoy-steering (handled by the Region) — no-op here.
  defp resolve(world, _cmd), do: world

  # --- replenishment (keep a colony from mining itself to a dead end) ---

  defp replenish(%World{} = world) do
    if map_size(world.deposits) <= cfg(world, :replenish_threshold) do
      pos = free_cell(world)
      World.note(%{world | deposits: Map.put(world.deposits, pos, cfg(world, :resource_amount))}, "A new ore deposit appeared at #{fmt(pos)}.")
    else
      world
    end
  end

  # Deterministic free cell from {seed, tick}, probing forward (no wall-clock/:rand).
  defp free_cell(%World{} = world) do
    w = cfg(world, :width)
    h = cfg(world, :height)
    base = :erlang.phash2({world.seed, world.tick})
    Enum.reduce_while(0..(w * h), nil, fn attempt, _ ->
      n = :erlang.phash2({base, attempt})
      pos = {rem(n, w), rem(div(n, w), h)}
      if pos == {0, 0} or Map.has_key?(world.deposits, pos), do: {:cont, nil}, else: {:halt, pos}
    end) || {0, 0}
  end

  # --- helpers ---

  defp cfg(%World{config: c}, k), do: Map.fetch!(c, k)

  defp in_grid?(world, {x, y}), do: x >= 0 and y >= 0 and x < cfg(world, :width) and y < cfg(world, :height)

  defp adjacent?({x, y}, {tx, ty}), do: abs(x - tx) + abs(y - ty) <= 1

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  defp clamp(v, _size) when v < 0, do: 0
  defp clamp(v, size) when v >= size, do: size - 1
  defp clamp(v, _size), do: v

  defp fmt({x, y}), do: "(#{x},#{y})"
end
