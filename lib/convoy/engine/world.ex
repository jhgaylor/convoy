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
  Which room an entity occupies. A `:harvester` lives in its owner's **private
  harvesting room** (keyed by the owner's player id) — no other player can ever
  be there. A `:convoy` lives in the single **shared market room** (`:market`),
  the only contested ground in the world.
  """
  @type room :: player_id() | :market

  @typedoc """
  A grid entity. `kind` is `:harvester` (player-controlled, mines/forges) or
  `:convoy` (auto-piloted shipment that runs to the market — see the Convoy
  section). A convoy's `cargo` is the goods it carries; `cargo_max` is unused
  for it. `room` is which space the entity is in (see `room/0`): two entities
  in different rooms never interact even at the same `{x, y}`.
  """
  @type entity :: %{
          id: pos_integer(),
          owner: player_id(),
          kind: :harvester | :convoy,
          room: room(),
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
            # `base` is a room-LOCAL coordinate: the base cell within *every*
            # harvesting room (all rooms share dimensions; only their ore layout
            # differs). `market`/`market_entry` are coordinates in the shared
            # market room — where convoys sell and where they appear.
            base: {0, 0},
            market: {15, 11},
            market_entry: {0, 0},
            # Optional neighbor region id (primer §4). When set, convoys reaching
            # the market *cross the border* into that region instead of selling
            # here. nil = a self-contained, fully-deterministic region (the
            # default): convoys sell in-world.
            neighbor: nil,
            # Per-player **private harvesting rooms**: `%{player_id => %{resources:
            # %{pos => amount}}}`. Each player's deposits live only in their own
            # room, generated deterministically from `{seed, player_id}`, so no
            # one competes for (or even sees the same) ore. The shared market room
            # holds no resources — it's just the contested road to `market`.
            rooms: %{},
            entities: [],
            bases: %{},
            next_entity_id: 1,
            replenished: 0,
            # Transient per-tick outboxes the Sim fills and the Region drains
            # into cross-region messages (border handoff + credit-back). Always
            # empty for a neighbor-less region, so single-region play is pure.
            departing: [],
            pending_credits: [],
            events: []

  @type t :: %World{
          region_id: String.t(),
          seed: integer(),
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          base: pos(),
          market: pos(),
          market_entry: pos(),
          neighbor: String.t() | nil,
          rooms: %{player_id() => %{resources: %{pos() => non_neg_integer()}}},
          entities: [entity()],
          bases: %{player_id() => base()},
          next_entity_id: pos_integer(),
          replenished: non_neg_integer(),
          departing: [map()],
          pending_credits: [map()],
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
    neighbor = Keyword.get(opts, :neighbor)
    # The market sits at the opposite corner from the market-room entry — the far
    # end of the contested run. Deterministic, so replays/layouts stay reproducible.
    market = {width - 1, height - 1}

    # A fresh world has NO players and so NO rooms — players join explicitly via
    # add_player/3 (a CLI/API submission, or the in-browser editor's Run), and
    # each join carves out that player's private harvesting room. The browser is
    # a spectator until then.
    %World{
      region_id: region_id,
      seed: seed,
      width: width,
      height: height,
      tick: 0,
      base: base,
      market: market,
      market_entry: {0, 0},
      neighbor: neighbor,
      rooms: %{},
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
  Add a player to the world: carve out their **private harvesting room**
  (deterministic deposits from `{seed, player_id}`), spawn their harvesters at
  the base cell inside it, and start their score at 0. Idempotent — re-adding an
  existing player is a no-op (so a player resubmitting code keeps their room).
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
          room: player_id,
          x: bx,
          y: by,
          cargo: 0,
          cargo_max: @cargo_max,
          last_action: :idle
        }

        {entity, id + 1}
      end)

    # Each player's deposits derive from a per-player seed, so every room is
    # reproducible (replay, primer §6) and distinct (no two players get the
    # same map — but also can never touch each other's ore).
    {resources, _rng} =
      place_resources(room_seed(world.seed, player_id), world.width, world.height, world.base)

    %{
      world
      | entities: world.entities ++ new_entities,
        rooms: Map.put(world.rooms, player_id, %{resources: resources}),
        bases: Map.put(world.bases, player_id, new_base()),
        next_entity_id: next_id,
        events: ["Player #{player_id} joined with #{count} harvesters." | world.events]
    }
  end

  # A per-player room seed: deterministic from the world seed + player id, so a
  # given player always gets the same private layout under a given world seed.
  defp room_seed(seed, player_id), do: :erlang.phash2({seed, player_id})

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
          rooms: Map.delete(world.rooms, player_id),
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
    # The convoy leaves the player's base and enters the SHARED market room at
    # its entry — the contested run happens on common ground, never inside a
    # player's private room.
    {ex, ey} = world.market_entry

    convoy = %{
      id: world.next_entity_id,
      owner: player_id,
      kind: :convoy,
      room: :market,
      x: ex,
      y: ey,
      cargo: @shipment_value,
      cargo_max: @shipment_value,
      # The region to credit when this shipment finally sells — its home, even
      # if it crosses a border into a market region (primer §4).
      origin_region: world.region_id,
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

  @doc "Remove an entity by id (a convoy that sold, crossed a border, or was seized)."
  @spec remove_entity(t(), pos_integer()) :: t()
  def remove_entity(%World{} = world, id),
    do: %{world | entities: Enum.reject(world.entities, &(&1.id == id))}

  # --- cross-region border crossing (primer §4) ---

  @doc "The neighbor region convoys cross into, or nil for a self-contained region."
  @spec neighbor(t()) :: String.t() | nil
  def neighbor(%World{neighbor: n}), do: n

  @doc """
  Inject a convoy arriving from another region (primer §4). It enters at this
  region's base with a fresh local id, keeping its owner, cargo, and the origin
  region to credit when it eventually sells.
  """
  @spec receive_convoy(t(), map()) :: t()
  def receive_convoy(%World{} = world, %{owner: owner, cargo: cargo, origin_region: origin}) do
    {ex, ey} = world.market_entry

    convoy = %{
      id: world.next_entity_id,
      owner: owner,
      kind: :convoy,
      room: :market,
      x: ex,
      y: ey,
      cargo: cargo,
      cargo_max: cargo,
      origin_region: origin,
      last_action: :arrive
    }

    world
    |> Map.update!(:entities, &(&1 ++ [convoy]))
    |> Map.update!(:next_entity_id, &(&1 + 1))
  end

  @doc """
  Take and clear this tick's outbound cross-region messages. The Region drains
  these after each tick and turns them into casts: `departing` convoys go to the
  neighbor region, `pending_credits` go back to each shipment's origin region.
  Returns `{departing, pending_credits, cleared_world}`.
  """
  @spec take_outbox(t()) :: {[map()], [map()], t()}
  def take_outbox(%World{departing: d, pending_credits: c} = world),
    do: {d, c, %{world | departing: [], pending_credits: []}}

  @doc "The ore amount a freshly-spawned (or generated) deposit holds."
  @spec resource_amount() :: pos_integer()
  def resource_amount, do: @resource_amount

  @doc "Ids of the players whose private harvesting rooms exist."
  @spec room_ids(t()) :: [player_id()]
  def room_ids(%World{rooms: rooms}), do: Map.keys(rooms)

  @doc "The deposit map for a player's room (empty if the room is unknown)."
  @spec resources(t(), room()) :: %{pos() => non_neg_integer()}
  def resources(%World{rooms: rooms}, room) do
    case Map.get(rooms, room) do
      %{resources: r} -> r
      _ -> %{}
    end
  end

  @doc "How many distinct deposits still hold ore in a room."
  @spec resource_node_count(t(), room()) :: non_neg_integer()
  def resource_node_count(%World{} = world, room), do: map_size(resources(world, room))

  @doc "How many distinct deposits still hold ore across every room."
  @spec resource_node_count(t()) :: non_neg_integer()
  def resource_node_count(%World{rooms: rooms} = world),
    do: rooms |> Map.keys() |> Enum.map(&resource_node_count(world, &1)) |> Enum.sum()

  @doc """
  If a room has dwindled to its last deposit (or fewer), add a fresh one at a
  deterministic free cell and return `{world, spawned_pos}`. Otherwise return
  `{world, nil}` unchanged. No-op for a room that doesn't exist (e.g. `:market`,
  which holds no ore).

  Placement derives from `{seed, tick, room}` so replays stay bit-identical
  (§6) — no wall-clock, no `:rand`. The sim calls this each tick per room after
  resolving intents.
  """
  @spec maybe_spawn_resource(t(), room()) :: {t(), pos() | nil}
  def maybe_spawn_resource(%World{rooms: rooms} = world, room) when is_map_key(rooms, room) do
    if map_size(resources(world, room)) <= @replenish_threshold do
      pos = spawn_cell(world, room)

      world =
        world
        |> put_resources(room, Map.put(resources(world, room), pos, @resource_amount))
        |> Map.update!(:replenished, &(&1 + 1))

      {world, pos}
    else
      {world, nil}
    end
  end

  def maybe_spawn_resource(%World{} = world, _room), do: {world, nil}

  @doc "Total ore still sitting in the ground in a room."
  @spec ore_remaining(t(), room()) :: non_neg_integer()
  def ore_remaining(%World{} = world, room),
    do: world |> resources(room) |> Map.values() |> Enum.sum()

  @doc "Total ore still in the ground across every room (the headline number)."
  @spec ore_remaining(t()) :: non_neg_integer()
  def ore_remaining(%World{rooms: rooms} = world),
    do: rooms |> Map.keys() |> Enum.map(&ore_remaining(world, &1)) |> Enum.sum()

  @doc "Resource amount at a cell in a room (0 if none)."
  @spec resource_at(t(), room(), pos()) :: non_neg_integer()
  def resource_at(%World{} = world, room, pos), do: Map.get(resources(world, room), pos, 0)

  @doc "Nearest cell in a room still holding ore, by Manhattan distance (deterministic tie-break)."
  @spec nearest_resource(t(), room(), pos()) :: pos() | nil
  def nearest_resource(%World{} = world, room, pos),
    do: pick_resource(resources(world, room), pos, &Enum.min_by/3)

  @doc "Farthest cell in a room still holding ore, by Manhattan distance (deterministic tie-break)."
  @spec farthest_resource(t(), room(), pos()) :: pos() | nil
  def farthest_resource(%World{} = world, room, pos),
    do: pick_resource(resources(world, room), pos, &Enum.max_by/3)

  @doc """
  Remove `amount` ore from a cell in a room, dropping the deposit when it
  empties. The sim's authoritative harvest resolution goes through here.
  """
  @spec deplete_resource(t(), room(), pos(), non_neg_integer()) :: t()
  def deplete_resource(%World{} = world, room, pos, amount) do
    updated =
      world
      |> resources(room)
      |> Map.update(pos, 0, &(&1 - amount))
      |> then(fn r -> if Map.get(r, pos, 0) <= 0, do: Map.delete(r, pos), else: r end)

    put_resources(world, room, updated)
  end

  defp put_resources(%World{rooms: rooms} = world, room, resources) do
    %{
      world
      | rooms: Map.update(rooms, room, %{resources: resources}, &%{&1 | resources: resources})
    }
  end

  defp pick_resource(resources, {x, y}, chooser) do
    resources
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

  # Pick a free cell in `room` (not the base, not an existing deposit)
  # deterministically from {seed, tick, room}, probing forward until one's free.
  defp spawn_cell(%World{} = world, room) do
    base_hash = :erlang.phash2({world.seed, world.tick, room})
    find_free_cell(world, room, base_hash, 0)
  end

  defp find_free_cell(%World{width: w, height: h, base: base} = world, room, base_hash, attempt)
       when attempt < w * h do
    n = :erlang.phash2({base_hash, attempt})
    pos = {rem(n, w), rem(div(n, w), h)}

    if pos == base or Map.has_key?(resources(world, room), pos) do
      find_free_cell(world, room, base_hash, attempt + 1)
    else
      pos
    end
  end

  # Grid is entirely full of deposits — can't happen below the threshold, but
  # fall back to the base cell rather than loop forever.
  defp find_free_cell(%World{base: base}, _room, _base_hash, _attempt), do: base

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
