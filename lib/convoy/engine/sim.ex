defmodule Convoy.Engine.Sim do
  @moduledoc """
  The deterministic tick loop (primer §6).

  `tick/2` is a **pure function**: `(world, decider) -> world`. Given the same
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

  alias Convoy.Engine.World

  @max_events 40

  @typedoc """
  An arity-2 decider closure turning an entity + read-only world into an intent.
  This is how the WASM backend (`Convoy.Engine.Wasm`) plugs in without `Sim`
  knowing which language produced the intent.
  """
  @type decider :: (World.entity(), World.t() -> term())

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

  @doc """
  Step (2) of the loop: run the decider for each entity, in deterministic
  entity-id order, against the read-only snapshot. Returns `[{id, intent}]`.

  Split out so a caller (e.g. `Region` with the WASM backend) can run the
  decider with fuel accounting before handing intents back to `apply_intents/2`.
  """
  @spec collect_intents(World.t(), (World.entity(), World.t() -> term())) :: [
          {pos_integer(), term()}
        ]
  def collect_intents(%World{} = world, decide_fun) when is_function(decide_fun, 2) do
    world.entities
    # Convoys are auto-piloted by the Sim (see move_convoys/1), so only
    # harvesters run player code.
    |> Enum.filter(&(&1.kind == :harvester))
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

    world
    # Convoys (primer §1, §4): auto-pilot every convoy one step toward the
    # market, then resolve the contested market — PvP capture on shared cells,
    # then delivery. All deterministic (id-order / commutative per cell).
    |> move_convoys()
    |> resolve_market()
    # The Forge: every base refines stockpiled ore into goods at its tech rate.
    # Rate-based and deterministic, so warm regions stay fast-forwardable (§5).
    |> World.refine_all()
    |> Map.update!(:tick, &(&1 + 1))
    |> replenish()
    |> Map.update!(:events, &Enum.take(&1, @max_events))
  end

  # Keep each player's room from being mined to a dead end: spawn a fresh deposit
  # in any room that drops to its last one (deterministic, per room — see
  # World.maybe_spawn_resource/2). Each room replenishes independently.
  defp replenish(world) do
    Enum.reduce(World.room_ids(world), world, fn room, acc ->
      case World.maybe_spawn_resource(acc, room) do
        {acc, nil} ->
          acc

        {acc, pos} ->
          note(
            acc,
            "A new ore deposit (#{World.resource_amount()}) appeared in #{room}'s room at #{fmt(pos)}."
          )
      end
    end)
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
    # A harvester only ever sees ore in its OWN private room (primer: players
    # can't enter each other's spaces). `e.room` is the owner's room id.
    available = World.resource_at(world, e.room, pos)
    space = e.cargo_max - e.cargo

    cond do
      available <= 0 ->
        note(update_entity(world, id, &%{&1 | last_action: :idle}), nil)

      space <= 0 ->
        update_entity(world, id, &%{&1 | last_action: :idle})

      true ->
        taken = min(available, space)

        world
        |> World.deplete_resource(e.room, pos, taken)
        |> update_entity(id, &%{&1 | cargo: &1.cargo + taken, last_action: :harvest})
        |> note("#{e.owner}/H#{id} mined #{taken} ore at #{fmt(pos)}.")
    end
  end

  defp resolve(world, id, :unload) do
    e = entity(world, id)

    if {e.x, e.y} == world.base and e.cargo > 0 do
      delivered = e.cargo
      stockpile = World.base(world, e.owner).ore + delivered

      world
      |> World.deposit_ore(e.owner, delivered)
      |> update_entity(id, &%{&1 | cargo: 0, last_action: :unload})
      |> note(
        "#{e.owner}/H#{id} delivered #{delivered} ore to the forge. (stockpile: #{stockpile})"
      )
    else
      update_entity(world, id, &%{&1 | last_action: :idle})
    end
  end

  # Build / upgrade a tech tier at the base, spending the player's goods. Only
  # valid standing on the base with the goods to afford it (resolved against the
  # accumulating world, so two harvesters can't both spend the same goods).
  defp resolve(world, id, {:build, tech}) do
    e = entity(world, id)

    if {e.x, e.y} == world.base and World.can_build?(world, e.owner, tech) do
      cost = World.build_cost(world, e.owner, tech)

      world
      |> World.build(e.owner, tech)
      |> update_entity(id, &%{&1 | last_action: :build})
      |> note(
        "#{e.owner} forged #{tech} L#{World.tech_level(World.base(world, e.owner), tech) + 1} (−#{cost} goods)."
      )
    else
      update_entity(world, id, &%{&1 | last_action: :idle})
    end
  end

  # Load a convoy at the base and send it to the market (primer §1). Only valid
  # standing on the base with the goods for a shipment.
  defp resolve(world, id, :launch) do
    e = entity(world, id)

    if {e.x, e.y} == world.base and World.can_launch?(world, e.owner) do
      world
      |> World.launch_convoy(e.owner)
      |> update_entity(id, &%{&1 | last_action: :launch})
      |> note("#{e.owner} loaded a convoy — #{World.shipment_size()} goods bound for market.")
    else
      update_entity(world, id, &%{&1 | last_action: :idle})
    end
  end

  defp resolve(world, id, :idle) do
    update_entity(world, id, &%{&1 | last_action: :idle})
  end

  # --- convoys + contested market (primer §1, §4) ---

  # Auto-pilot every convoy one cell toward the market. Convoys aren't player-
  # controlled; the run itself is automatic, the strategy is when to launch.
  defp move_convoys(world) do
    market = World.market(world)

    entities =
      Enum.map(world.entities, fn e ->
        if World.convoy?(e) do
          {dx, dy} = World.step_toward({e.x, e.y}, market)
          %{e | x: e.x + dx, y: e.y + dy, last_action: :move}
        else
          e
        end
      end)

    %{world | entities: entities}
  end

  # The contested moment (primer §1, §4): capture first (an ambush takes the
  # shipment before it can sell), then deliver. Bases are never touched — combat
  # only ever happens to a convoy out on the run.
  defp resolve_market(world) do
    world |> capture_convoys() |> sell_convoys()
  end

  # On any cell holding convoys of two or more owners, the lowest-id convoy
  # seizes the others' shipments and they're destroyed. Per-cell captures are
  # independent (disjoint entities), so the result is order-independent and
  # bit-identical regardless of map iteration order.
  defp capture_convoys(world) do
    world
    |> World.convoys()
    |> Enum.group_by(fn e -> {e.x, e.y} end)
    |> Enum.reduce(world, fn {cell, group}, acc -> capture_cell(acc, cell, group) end)
  end

  defp capture_cell(world, cell, group) do
    distinct_owners = group |> Enum.map(& &1.owner) |> Enum.uniq()

    if length(distinct_owners) >= 2 do
      [winner | losers] = Enum.sort_by(group, & &1.id)
      seized = losers |> Enum.map(& &1.cargo) |> Enum.sum()

      world
      |> update_entity(winner.id, &%{&1 | cargo: &1.cargo + seized, last_action: :seize})
      |> drop_entities(Enum.map(losers, & &1.id))
      |> note(
        "#{winner.owner}/C#{winner.id} ambushed #{length(losers)} convoy(s) at #{fmt(cell)}, seizing #{seized} credits' worth."
      )
    else
      world
    end
  end

  # Convoys reaching the market either sell (a self-contained region) or cross
  # the border into the neighbor region (primer §4). Each is independent, so
  # order doesn't matter. Cross-region effects are queued onto the world's
  # outbox for the Region to send; the Sim itself stays pure.
  defp sell_convoys(world) do
    market = World.market(world)
    neighbor = World.neighbor(world)

    world
    |> World.convoys()
    |> Enum.filter(fn e -> {e.x, e.y} == market end)
    |> Enum.reduce(world, fn c, acc -> arrive(acc, c, neighbor) end)
  end

  # No neighbor: terminal market. Sell — crediting the shipment's origin region.
  defp arrive(world, c, nil) do
    origin = Map.get(c, :origin_region) || world.region_id

    if origin == world.region_id do
      world
      |> World.credit_market(c.owner, c.cargo)
      |> World.remove_entity(c.id)
      |> note("#{c.owner}/C#{c.id} delivered a shipment to market (+#{c.cargo} credits).")
    else
      # A shipment that crossed in from elsewhere: queue a credit-back to its
      # home region, and take it off the board here.
      world
      |> Map.update!(:pending_credits, &[%{region: origin, owner: c.owner, amount: c.cargo} | &1])
      |> World.remove_entity(c.id)
      |> note("#{c.owner}/C#{c.id} sold at market (#{c.cargo} credits → #{origin}).")
    end
  end

  # This region borders another: the convoy crosses instead of selling. Queue
  # the handoff and take it off the board (phase 1 of the two-phase handoff;
  # the Region delivers it to the neighbor, phase 2).
  defp arrive(world, c, neighbor) do
    payload = %{
      owner: c.owner,
      cargo: c.cargo,
      origin_region: Map.get(c, :origin_region) || world.region_id
    }

    world
    |> Map.update!(:departing, &[%{to: neighbor, convoy: payload} | &1])
    |> World.remove_entity(c.id)
    |> note("#{c.owner}/C#{c.id} crossed the border toward #{neighbor}.")
  end

  defp drop_entities(world, ids), do: Enum.reduce(ids, world, &World.remove_entity(&2, &1))

  # --- helpers ---

  defp entity(world, id), do: Enum.find(world.entities, &(&1.id == id))

  defp update_entity(world, id, fun) do
    entities =
      Enum.map(world.entities, fn e ->
        if e.id == id, do: fun.(e), else: e
      end)

    %{world | entities: entities}
  end

  defp clamp(v, _size) when v < 0, do: 0
  defp clamp(v, size) when v >= size, do: size - 1
  defp clamp(v, _size), do: v

  defp note(world, nil), do: world
  defp note(world, msg), do: %{world | events: [msg | world.events]}

  defp fmt({x, y}), do: "(#{x},#{y})"
end
