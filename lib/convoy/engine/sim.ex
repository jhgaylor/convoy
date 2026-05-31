defmodule Convoy.Engine.Sim do
  @moduledoc """
  The deterministic tick loop (primer §6).

  `tick/2` is a **pure function**: `(world, rules) -> world`. Given the same
  starting world and program it always yields the same next world, which is
  what makes replays free and disputes resolvable (primer §6, §11).

  Each tick follows the fixed-step order from the primer:

      1. snapshot world state          (the read-only view player code sees)
      2. run player code per entity    (in entity-id order) -> collect intents
      3. & 4. validate + resolve       (authoritatively, in entity-id order)
      5. apply resource/position change
      6. emit events
      7. commit new state (tick + 1)

  Player code never mutates `world`; it only returns intents resolved here.
  """

  alias Convoy.Engine.{World, Program}

  @max_events 40

  @typedoc """
  Anything that turns an entity + read-only world into an intent. Either a
  compiled rule list (`Program.t/0`) or an arity-2 decider closure — the latter
  is how the WASM backend (`Convoy.Engine.Wasm`) plugs in without `Sim` knowing
  which language produced the intent.
  """
  @type decider :: Program.t() | (World.entity(), World.t() -> term())

  @doc """
  Advance the world by one tick: run player code, then resolve its intents.
  """
  @spec tick(World.t(), decider()) :: World.t()
  def tick(%World{} = world, decide_fun) when is_function(decide_fun, 2) do
    # (1) snapshot is the immutable `world`; (2) run player code per entity.
    intents = collect_intents(world, decide_fun)
    # (3)-(7) resolve authoritatively + commit.
    apply_intents(world, intents)
  end

  def tick(%World{} = world, rules) when is_list(rules) do
    tick(world, &Program.eval(rules, &1, &2))
  end

  @doc """
  Step (2) of the loop: run the decider for each entity, in deterministic
  entity-id order, against the read-only snapshot. Returns `[{id, intent}]`.

  Split out so a caller (e.g. `Region` with the WASM backend) can run the
  decider with fuel accounting before handing intents back to `apply_intents/2`.
  """
  @spec collect_intents(World.t(), (World.entity(), World.t() -> term())) :: [{pos_integer(), term()}]
  def collect_intents(%World{} = world, decide_fun) when is_function(decide_fun, 2) do
    world.entities
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn entity -> {entity.id, decide_fun.(entity, world)} end)
  end

  @doc """
  Steps (3)-(7): validate & resolve intents authoritatively, in id order,
  against the *accumulating* world so single-writer semantics hold (two
  harvesters can't both take the last ore), then advance the tick.
  """
  @spec apply_intents(World.t(), [{pos_integer(), term()}]) :: World.t()
  def apply_intents(%World{} = world, intents) do
    world = Enum.reduce(intents, world, fn {id, intent}, acc -> resolve(acc, id, intent) end)
    %{world | tick: world.tick + 1, events: Enum.take(world.events, @max_events)}
  end

  @doc "Run `n` ticks. Used for replay / fast-forward verification (primer §11)."
  @spec run(World.t(), decider(), non_neg_integer()) :: World.t()
  def run(world, decider, n) when n > 0 do
    Enum.reduce(1..n, world, fn _i, w -> tick(w, decider) end)
  end

  def run(world, _decider, _n), do: world

  # --- intent resolution (the sim owns all mutation) ---

  defp resolve(world, id, {:move, {dx, dy}}) do
    update_entity(world, id, fn e ->
      nx = clamp(e.x + dx, world.width)
      ny = clamp(e.y + dy, world.height)
      %{e | x: nx, y: ny, last_action: :move}
    end)
  end

  defp resolve(world, id, :harvest) do
    e = entity(world, id)
    pos = {e.x, e.y}
    available = World.resource_at(world, pos)
    space = e.cargo_max - e.cargo

    cond do
      available <= 0 ->
        note(update_entity(world, id, &%{&1 | last_action: :idle}), nil)

      space <= 0 ->
        update_entity(world, id, &%{&1 | last_action: :idle})

      true ->
        taken = min(available, space)
        resources = Map.update!(world.resources, pos, &(&1 - taken)) |> drop_empty(pos)

        world
        |> Map.put(:resources, resources)
        |> update_entity(id, &%{&1 | cargo: &1.cargo + taken, last_action: :harvest})
        |> note("Harvester #{id} mined #{taken} ore at #{fmt(pos)}.")
    end
  end

  defp resolve(world, id, :unload) do
    e = entity(world, id)

    if {e.x, e.y} == world.base and e.cargo > 0 do
      delivered = e.cargo

      world
      |> Map.put(:delivered, world.delivered + delivered)
      |> update_entity(id, &%{&1 | cargo: 0, last_action: :unload})
      |> note("Harvester #{id} delivered #{delivered} ore to base. (total: #{world.delivered + delivered})")
    else
      update_entity(world, id, &%{&1 | last_action: :idle})
    end
  end

  defp resolve(world, id, :idle) do
    update_entity(world, id, &%{&1 | last_action: :idle})
  end

  # --- helpers ---

  defp entity(world, id), do: Enum.find(world.entities, &(&1.id == id))

  defp update_entity(world, id, fun) do
    entities =
      Enum.map(world.entities, fn e ->
        if e.id == id, do: fun.(e), else: e
      end)

    %{world | entities: entities}
  end

  defp drop_empty(resources, pos) do
    if Map.get(resources, pos, 0) <= 0, do: Map.delete(resources, pos), else: resources
  end

  defp clamp(v, _size) when v < 0, do: 0
  defp clamp(v, size) when v >= size, do: size - 1
  defp clamp(v, _size), do: v

  defp note(world, nil), do: world
  defp note(world, msg), do: %{world | events: [msg | world.events]}

  defp fmt({x, y}), do: "(#{x},#{y})"
end
