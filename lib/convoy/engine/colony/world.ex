defmodule Convoy.Engine.Colony.World do
  @moduledoc """
  Authoritative state for one **colony** (Forge & Convoy v2 — see
  `docs/colony-v2-design.md`). This is the v2 counterpart to
  `Convoy.Engine.World`: instead of three reflex harvesters, a colony is units +
  spatially-placed buildings + a build queue, all commanded by one brain.

  Pure, deterministic data: the brain returns commands, `Convoy.Engine.Colony.Sim`
  resolves them authoritatively (intents-never-mutations, primer §3). Reproducible
  from `{seed, config}` so replays stay bit-identical (primer §6).

  Scope of this slice: a single colony's economy loop — mine ore, haul it into a
  refinery, refine ore→goods over time, spend goods to build more buildings and
  spawn more units, all time-and-cost gated. The shared contested market + convoys
  + multiplayer are a later chunk (the v1 engine already proves those patterns).
  """

  alias Convoy.Engine.Colony.World

  # Unit + building kinds — MUST match Convoy.Engine.ColonyAbi (the wire format).
  @unit_harvester 0
  @bld_spawner 0
  @bld_refinery 1
  @bld_storage 2

  @default_config %{
    width: 16,
    height: 12,
    start_units: 2,
    cargo_max: 5,
    # buildings: goods cost + construction time (ticks) — the time+cost pacing engine
    build_cost_refinery: 40,
    build_time_refinery: 30,
    build_cost_storage: 25,
    build_time_storage: 20,
    # the Forge: a small built-in base rate (the spawner's minimal forge) so a
    # colony can bootstrap goods with zero refineries — otherwise you'd need goods
    # to build the refinery that makes goods (deadlock). Refineries multiply it.
    base_refine_rate: 1,
    # extra ore→goods per (refinery level+1) per tick (rate-based, §5)
    refine_rate: 2,
    # storage: goods you can hold; +step per finished storage building
    storage_base: 60,
    storage_step: 80,
    # spawning: goods cost + time (ticks); pop cap scales with spawner level
    spawn_cost_harvester: 20,
    spawn_time_harvester: 8,
    pop_cap_base: 4,
    pop_cap_step: 2,
    # convoys: goods spent to load one, credits a delivered shipment earns
    shipment_size: 20,
    shipment_value: 30,
    # resource layout / replenishment
    resource_nodes: 6,
    resource_amount: 40,
    replenish_threshold: 1
  }

  defstruct seed: 1,
            tick: 0,
            config: @default_config,
            ore: 0,
            goods: 0,
            credits: 0,
            refined_total: 0,
            units: [],
            buildings: [],
            # %{ {x,y} => amount }
            deposits: %{},
            # in-flight spawns: [%{kind, remaining}]
            spawn_queue: [],
            # transient outbox: convoys launched this tick for the Region to inject
            # into the shared market (drained + cleared each tick). [%{cargo}]
            launches: [],
            next_id: 1,
            events: []

  @type unit :: %{id: pos_integer(), kind: non_neg_integer(), x: non_neg_integer(), y: non_neg_integer(), cargo: non_neg_integer(), cargo_max: pos_integer()}
  @type building :: %{id: pos_integer(), kind: non_neg_integer(), x: non_neg_integer(), y: non_neg_integer(), level: non_neg_integer(), built: boolean(), remaining: non_neg_integer()}

  @max_events 40

  def default_config, do: @default_config
  defp cfg(%World{config: c}, k), do: Map.get(c, k, Map.fetch!(@default_config, k))

  @doc "Merge current defaults under a (possibly older) config, so a restored colony gains any new knobs."
  def ensure_config(%World{config: c} = w), do: %{w | config: Map.merge(@default_config, c || %{})}

  @doc "Build a fresh colony deterministically from a seed: a built spawner at (0,0), `start_units` harvesters, and a deterministic ore layout."
  @spec generate(keyword()) :: t :: %World{}
  def generate(opts \\ []) do
    seed = Keyword.get(opts, :seed, 1)
    config = Map.merge(@default_config, Map.take(Map.new(Keyword.get(opts, :config, %{})), Map.keys(@default_config)))

    w0 = %World{seed: seed, config: config, deposits: %{}}
    cargo_max = config.cargo_max

    spawner = %{id: 1, kind: @bld_spawner, x: 0, y: 0, level: 0, built: true, remaining: 0}

    {units, next} =
      Enum.map_reduce(1..config.start_units, 2, fn _i, id ->
        {%{id: id, kind: @unit_harvester, x: 0, y: 0, cargo: 0, cargo_max: cargo_max}, id + 1}
      end)

    deposits =
      place_resources(seed, config.width, config.height, {0, 0}, config.resource_nodes, config.resource_amount)

    %{
      w0
      | buildings: [spawner],
        units: units,
        deposits: deposits,
        next_id: next,
        events: ["Colony initialized from seed #{seed}."]
    }
  end

  # --- queries ---

  def unit(%World{units: us}, id), do: Enum.find(us, &(&1.id == id))
  def building(%World{buildings: bs}, id), do: Enum.find(bs, &(&1.id == id))
  def finished_buildings(%World{buildings: bs}, kind), do: Enum.filter(bs, &(&1.built and &1.kind == kind))
  def building_at(%World{buildings: bs}, pos), do: Enum.find(bs, &({&1.x, &1.y} == pos))
  def deposit_at(%World{deposits: d}, pos), do: Map.get(d, pos, 0)
  def ore_remaining(%World{deposits: d}), do: d |> Map.values() |> Enum.sum()

  @doc "Total goods this colony can hold = base + step per finished storage."
  def storage_cap(%World{} = w) do
    cfg(w, :storage_base) + length(finished_buildings(w, @bld_storage)) * cfg(w, :storage_step)
  end

  @doc "Population cap = base + step per spawner level (finished spawners)."
  def pop_cap(%World{} = w) do
    levels = finished_buildings(w, @bld_spawner) |> Enum.map(&(&1.level + 1)) |> Enum.sum()
    cfg(w, :pop_cap_base) + max(levels - 1, 0) * cfg(w, :pop_cap_step)
  end

  @doc "Current population = live units + in-flight spawns (both count toward the cap)."
  def population(%World{units: us, spawn_queue: q}), do: length(us) + length(q)

  @doc "Goods cost + build time for a building kind (nil if unknown to v2.0)."
  def build_spec(%World{} = w, @bld_refinery), do: {cfg(w, :build_cost_refinery), cfg(w, :build_time_refinery)}
  def build_spec(%World{} = w, @bld_storage), do: {cfg(w, :build_cost_storage), cfg(w, :build_time_storage)}
  def build_spec(_w, _kind), do: nil

  @doc "Goods cost + spawn time for a unit kind (nil if unknown to v2.0)."
  def spawn_spec(%World{} = w, @unit_harvester), do: {cfg(w, :spawn_cost_harvester), cfg(w, :spawn_time_harvester)}
  def spawn_spec(_w, _kind), do: nil

  @doc "Goods to load a convoy + credits a delivered shipment earns."
  def shipment_size(%World{} = w), do: cfg(w, :shipment_size)
  def shipment_value(%World{} = w), do: cfg(w, :shipment_value)

  @doc "Can this colony afford to load a convoy?"
  def can_launch?(%World{} = w), do: w.goods >= cfg(w, :shipment_size)

  @doc "Spend goods to load a convoy; queue it in `launches` for the Region to inject into the market."
  def launch(%World{} = w) do
    %{spend_goods(w, cfg(w, :shipment_size)) | launches: [%{cargo: cfg(w, :shipment_value)} | w.launches]}
    |> note("Loaded a convoy — #{cfg(w, :shipment_size)} goods bound for market.")
  end

  @doc "Take and clear this tick's launched convoys (the Region drains them into the market)."
  def take_launches(%World{launches: ls} = w), do: {ls, %{w | launches: []}}

  @doc "Credit a delivered shipment to this colony's lifetime credits (the score)."
  def credit(%World{} = w, amount) when amount > 0, do: %{w | credits: w.credits + amount}
  def credit(%World{} = w, _), do: w

  # --- mutations (called by the Sim, in resolution order) ---

  def add_ore(%World{} = w, amount) when amount > 0, do: %{w | ore: w.ore + amount}
  def add_ore(w, _), do: w

  def update_unit(%World{units: us} = w, id, fun), do: %{w | units: Enum.map(us, &if(&1.id == id, do: fun.(&1), else: &1))}
  def update_building(%World{buildings: bs} = w, id, fun), do: %{w | buildings: Enum.map(bs, &if(&1.id == id, do: fun.(&1), else: &1))}

  @doc "Remove `amount` ore from a deposit, dropping it when empty."
  def deplete(%World{deposits: d} = w, pos, amount) do
    left = Map.get(d, pos, 0) - amount
    deposits = if left <= 0, do: Map.delete(d, pos), else: Map.put(d, pos, left)
    %{w | deposits: deposits}
  end

  @doc "Place a new building under construction (built=false). Caller already validated cost/cell."
  def place_building(%World{} = w, kind, pos, time) do
    {x, y} = pos
    b = %{id: w.next_id, kind: kind, x: x, y: y, level: 0, built: false, remaining: time}
    %{w | buildings: w.buildings ++ [b], next_id: w.next_id + 1}
  end

  @doc "Enqueue a unit spawn (built after `time` ticks). Caller already validated cost/cap."
  def enqueue_spawn(%World{} = w, kind, time), do: %{w | spawn_queue: w.spawn_queue ++ [%{kind: kind, remaining: time}]}

  def spend_goods(%World{} = w, n), do: %{w | goods: max(w.goods - n, 0)}

  def note(%World{} = w, nil), do: w
  def note(%World{events: e} = w, msg), do: %{w | events: Enum.take([msg | e], @max_events)}

  # --- per-tick world advancement (timers + refining), called after commands ---

  @doc """
  Advance construction + spawn timers and refine ore→goods. Pure and mostly
  rate-based (refining), so a colony with no pending commands is fast-forwardable
  for cold regions (primer §5).
  """
  def advance(%World{} = w) do
    w |> tick_construction() |> tick_spawns() |> refine()
  end

  defp tick_construction(%World{buildings: bs} = w) do
    {bs2, done} =
      Enum.map_reduce(bs, [], fn b, acc ->
        cond do
          b.built -> {b, acc}
          b.remaining <= 1 -> {%{b | built: true, remaining: 0}, [b | acc]}
          true -> {%{b | remaining: b.remaining - 1}, acc}
        end
      end)

    w = %{w | buildings: bs2}
    Enum.reduce(done, w, fn b, acc -> note(acc, "#{kind_name(b.kind)} finished at (#{b.x},#{b.y}).") end)
  end

  defp tick_spawns(%World{spawn_queue: q} = w) do
    {ready, pending} = Enum.split_with(q, &(&1.remaining <= 1))
    w = %{w | spawn_queue: Enum.map(pending, &%{&1 | remaining: &1.remaining - 1})}
    {sx, sy} = spawner_pos(w)
    cargo_max = cfg(w, :cargo_max)

    Enum.reduce(ready, w, fn s, acc ->
      u = %{id: acc.next_id, kind: s.kind, x: sx, y: sy, cargo: 0, cargo_max: cargo_max}
      %{acc | units: acc.units ++ [u], next_id: acc.next_id + 1}
      |> note("#{unit_kind_name(s.kind)} spawned.")
    end)
  end

  # Each finished refinery converts up to rate*(level+1) ore→goods/tick, bounded
  # by the stockpile and remaining storage. Lifetime refined is the score.
  defp refine(%World{} = w) do
    rate = cfg(w, :refine_rate)
    refineries = finished_buildings(w, @bld_refinery) |> Enum.map(&(rate * (&1.level + 1))) |> Enum.sum()
    total = cfg(w, :base_refine_rate) + refineries
    room = max(storage_cap(w) - w.goods, 0)
    n = Enum.min([w.ore, total, room])

    if n > 0 do
      %{w | ore: w.ore - n, goods: w.goods + n, refined_total: w.refined_total + n}
    else
      w
    end
  end

  defp spawner_pos(%World{} = w) do
    case finished_buildings(w, @bld_spawner) do
      [s | _] -> {s.x, s.y}
      [] -> {0, 0}
    end
  end

  @doc "A view map for `Convoy.Engine.ColonyAbi.encode_view/1` (host → brain)."
  def to_view(%World{} = w) do
    %{
      tick: w.tick,
      width: cfg(w, :width),
      height: cfg(w, :height),
      ore: w.ore,
      goods: w.goods,
      credits: w.credits,
      units: Enum.map(w.units, &Map.take(&1, [:id, :kind, :x, :y, :cargo, :cargo_max])),
      buildings:
        Enum.map(w.buildings, fn b ->
          %{id: b.id, kind: b.kind, x: b.x, y: b.y, level: b.level, progress: if(b.built, do: 255, else: 0)}
        end),
      deposits: for({{x, y}, amt} <- w.deposits, do: %{x: x, y: y, amount: amt}),
      market: []
    }
  end

  @doc "Human name for a BUILDING kind."
  def kind_name(@bld_spawner), do: "spawner"
  def kind_name(@bld_refinery), do: "refinery"
  def kind_name(@bld_storage), do: "storage"
  def kind_name(_), do: "building"

  @doc "Human name for a UNIT kind (distinct id space from buildings — both start at 0)."
  def unit_kind_name(@unit_harvester), do: "harvester"
  def unit_kind_name(1), do: "hauler"
  def unit_kind_name(2), do: "builder"
  def unit_kind_name(3), do: "convoy"
  def unit_kind_name(_), do: "unit"

  # --- deterministic resource placement (small LCG, seed-only) ---

  defp place_resources(seed, width, height, base, nodes, amount) do
    {map, _rng} =
      Enum.reduce(1..nodes, {%{}, seed_state(seed)}, fn _i, {acc, rng} ->
        {pos, rng} = pick_free(acc, base, width, height, rng)
        {Map.put(acc, pos, amount), rng}
      end)

    map
  end

  defp pick_free(acc, base, width, height, rng) do
    {rng, x} = next(rng, width)
    {rng, y} = next(rng, height)
    pos = {x, y}
    if pos == base or Map.has_key?(acc, pos), do: pick_free(acc, base, width, height, rng), else: {pos, rng}
  end

  defp seed_state(seed), do: rem(abs(seed) * 2_654_435_761 + 1, 2_147_483_647)

  defp next(state, bound) do
    state = rem(state * 1_103_515_245 + 12_345, 2_147_483_648)
    {state, rem(state, bound)}
  end
end
