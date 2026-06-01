defmodule Convoy.ConvoyHandoffTest do
  use ExUnit.Case, async: false

  alias Convoy.Engine
  alias Convoy.Engine.{World, Sim}

  defp convoy_at(pos, opts) do
    {x, y} = pos

    %{
      id: Keyword.get(opts, :id, 999),
      owner: Keyword.get(opts, :owner, "p1"),
      kind: :convoy,
      x: x,
      y: y,
      cargo: Keyword.get(opts, :cargo, 30),
      cargo_max: 30,
      origin_region: Keyword.fetch!(opts, :origin),
      last_action: :move
    }
  end

  # --- Sim/World queue mechanics (pure, deterministic) ---

  test "with a neighbor, a convoy at the market is queued to cross, not sold" do
    world = World.generate(seed: 1, region_id: "home", neighbor: "market")
    convoy = convoy_at(World.market(world), origin: "home", owner: "p1", cargo: 30)
    world = %{world | entities: [convoy]}

    world = Sim.apply_intents(world, [])

    assert World.convoys(world) == []

    assert [%{to: "market", convoy: %{owner: "p1", cargo: 30, origin_region: "home"}}] =
             world.departing

    # crossing is not a sale — no credits accrue here
    assert World.credits(world, "p1") == 0
  end

  test "a foreign-origin convoy selling at a terminal market queues a credit-back" do
    world = World.generate(seed: 1, region_id: "market")
    convoy = convoy_at(World.market(world), origin: "home", owner: "alice", cargo: 30)
    world = %{world | entities: [convoy]}

    world = Sim.apply_intents(world, [])

    assert World.convoys(world) == []
    assert [%{region: "home", owner: "alice", amount: 30}] = world.pending_credits
    # not credited in the market region — it flows back to the origin
    assert World.credits(world, "alice") == 0
  end

  test "a home-origin convoy at its own terminal market credits locally (no cross-region)" do
    world = World.generate(seed: 1, region_id: "home")
    convoy = convoy_at(World.market(world), origin: "home", owner: "p1", cargo: 30)
    world = %{world | entities: [convoy]}

    world = Sim.apply_intents(world, [])
    assert World.credits(world, "p1") == 30
    assert world.pending_credits == []
    assert world.departing == []
  end

  # --- the two-region handoff end to end (primer §4) ---

  test "a convoy crossing into a neighbor region sells there and credits back home" do
    uniq = System.unique_integer([:positive])
    home = "home-#{uniq}"
    market = "market-#{uniq}"
    Engine.ensure_region(home)
    Engine.ensure_region(market)

    on_exit(fn ->
      Engine.delete_region(home)
      Engine.delete_region(market)
    end)

    # Phase 2 of a border crossing: a shipment from `home` arrives at the market.
    Engine.receive_convoy(market, %{owner: "alice", cargo: 30, origin_region: home})

    # Drive the market until the convoy reaches the sell-point and sells, which
    # casts a credit-back to `home`. step/1 is a cast, so we synchronize on the
    # market with a call (snapshot) — that drains all the step casts, by which
    # point the credit-back cast has been sent to home.
    for _ <- 1..50, do: Engine.step(market)
    market_snap = Engine.snapshot(market)
    assert World.convoys(market_snap.world) == []

    # The credit-back was sent before the market snapshot returned, so it's in
    # home's mailbox ahead of this call.
    assert World.credits(Engine.snapshot(home).world, "alice") == 30
  end
end
