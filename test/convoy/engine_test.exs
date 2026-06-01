defmodule Convoy.EngineTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Sim}

  # The canonical harvester as a plain Elixir decider (no language involved).
  defp rules, do: &Convoy.Bots.harvester/2

  # A world with one player's harvesters + private room (generate now starts empty).
  defp solo(seed), do: World.generate(seed: seed) |> World.add_player("p1")

  # Force a player's private room to a known ore layout.
  defp with_room(world, player, resources) do
    world = World.add_player(world, player)
    %{world | rooms: Map.put(world.rooms, player, %{resources: resources})}
  end

  test "same seed produces an identical world layout" do
    a = World.generate(seed: 42) |> World.add_player("p1")
    b = World.generate(seed: 42) |> World.add_player("p1")
    assert a.rooms == b.rooms
    assert a.entities == b.entities
  end

  test "different seeds produce different layouts" do
    a = World.generate(seed: 1) |> World.add_player("p1")
    b = World.generate(seed: 2) |> World.add_player("p1")
    refute a.rooms == b.rooms
  end

  test "each player gets a distinct private room under the same seed" do
    world = World.generate(seed: 5) |> World.add_player("p1") |> World.add_player("p2")
    # Same world seed, but different players → different (private) layouts.
    refute World.resources(world, "p1") == World.resources(world, "p2")
    # And a harvester is tagged with its owner's room.
    assert Enum.all?(world.entities, &(&1.room == &1.owner))
  end

  test "a harvester only mines ore in its own room, never another player's" do
    world = World.generate(seed: 1) |> World.add_player("p1") |> World.add_player("p2")
    # p1's room is empty; p2 has ore sitting on the (shared-coordinate) base cell.
    world = %{world | rooms: %{"p1" => %{resources: %{}}, "p2" => %{resources: %{{0, 0} => 40}}}}

    # Everyone tries to harvest. p1's harvesters stand on {0,0} too, but that's a
    # cell in their OWN room, which has no ore — they can't touch p2's deposit.
    final = Sim.run(world, fn _e, _w -> :harvest end, 1)

    assert World.resource_at(final, "p1", {0, 0}) == 0
    # p2 mined its own ore (3 harvesters × 5 cargo each = 15 removed).
    assert World.resource_at(final, "p2", {0, 0}) == 25

    p1_cargo =
      final.entities |> Enum.filter(&(&1.owner == "p1")) |> Enum.map(& &1.cargo) |> Enum.sum()

    assert p1_cargo == 0
  end

  test "nearest/farthest_resource pick the closest/most-distant node in a room" do
    world = with_room(World.generate(seed: 1), "p1", %{{1, 0} => 5, {14, 8} => 5})
    assert World.nearest_resource(world, "p1", {0, 0}) == {1, 0}
    assert World.farthest_resource(world, "p1", {0, 0}) == {14, 8}
  end

  test "farthest_resource is deterministic and returns nil on an empty room" do
    world = with_room(World.generate(seed: 1), "p1", %{{2, 2} => 1, {9, 9} => 1})

    assert World.farthest_resource(world, "p1", {0, 0}) ==
             World.farthest_resource(world, "p1", {0, 0})

    assert World.farthest_resource(with_room(world, "p1", %{}), "p1", {0, 0}) == nil
  end

  # The primer §11 acceptance test, in miniature: running the same program
  # from the same seed must be bit-identical across independent runs (the
  # freeze/replay guarantee).
  test "the tick loop is deterministic across independent runs" do
    rules = rules()
    run_a = solo(7) |> Sim.run(rules, 200)
    run_b = solo(7) |> Sim.run(rules, 200)
    assert run_a == run_b
  end

  test "harvesters deliver ore and the base refines it into goods over time" do
    final = solo(7) |> Sim.run(rules(), 200)
    assert World.total_refined(final) > 0
    assert final.tick == 200
  end

  test "the sim conserves ore: refined + stockpile + in-cargo + in-ground == initial + spawned" do
    rules = rules()
    initial = solo(3)
    total = World.ore_remaining(initial)

    final = Sim.run(initial, rules, 150)
    # Only harvester cargo is ore; a convoy's cargo is a credit-value shipment,
    # not raw ore, so it doesn't enter the ore balance.
    in_cargo =
      final.entities
      |> Enum.filter(&(&1.kind == :harvester))
      |> Enum.map(& &1.cargo)
      |> Enum.sum()

    spawned = final.replenished * World.resource_amount()

    # Delivered ore now splits into raw stockpile + lifetime-refined; every ore
    # unit is in exactly one of: ground, cargo, base stockpile, or refined.
    assert World.total_refined(final) + World.total_stockpile(final) + in_cargo +
             World.ore_remaining(final) == total + spawned
  end

  test "a dwindling room spawns a fresh deposit at its last node" do
    world = with_room(World.generate(seed: 1), "p1", %{{5, 5} => 3})
    assert World.resource_node_count(world, "p1") == 1

    {world, pos} = World.maybe_spawn_resource(world, "p1")
    assert pos != nil
    assert World.resource_node_count(world, "p1") == 2
    assert World.resource_at(world, "p1", pos) == World.resource_amount()
    assert world.replenished == 1
  end

  test "no deposit spawns while several remain in a room" do
    world = World.generate(seed: 1) |> World.add_player("p1")
    assert {^world, nil} = World.maybe_spawn_resource(world, "p1")
  end

  test "spawn placement is deterministic for the same seed + tick + room" do
    world = %{with_room(World.generate(seed: 2), "p1", %{{3, 3} => 1}) | tick: 17}
    {_, a} = World.maybe_spawn_resource(world, "p1")
    {_, b} = World.maybe_spawn_resource(world, "p1")
    assert a == b
  end

  test "the region never runs dry over a long run" do
    final = solo(4) |> Sim.run(rules(), 1000)
    assert World.ore_remaining(final) > 0
    assert World.resource_node_count(final) >= 1
    assert final.replenished > 0
  end

  test "player code cannot move an entity outside the grid" do
    rules = rules()
    final = solo(5) |> Sim.run(rules, 300)

    for e <- final.entities do
      assert e.x in 0..(final.width - 1)
      assert e.y in 0..(final.height - 1)
    end
  end

  # --- the Forge: refining + tech ladder (primer §1) ---

  # Hand a player goods directly, to test building without harvesting first.
  defp grant_goods(world, player, n) do
    %{world | bases: Map.update!(world.bases, player, &%{&1 | goods: &1.goods + n})}
  end

  test "unload stocks raw ore; the base refines it into goods over ticks" do
    world = solo(1) |> World.deposit_ore("p1", 10)
    assert World.base(world, "p1").ore == 10

    world = World.refine_all(world)
    b = World.base(world, "p1")
    # rate 1 at refine level 0: one ore becomes one good per tick.
    assert b.ore == 9
    assert b.goods == 1
    assert b.refined_total == 1
  end

  test "building refine spends goods, raises the level, and speeds refining" do
    world = solo(1) |> grant_goods("p1", 50)
    assert World.can_build?(world, "p1", :refine)
    assert World.build_cost(world, "p1", :refine) == 10

    world = World.build(world, "p1", :refine)
    b = World.base(world, "p1")
    assert b.tech.refine == 1
    assert b.goods == 40

    # refine rate is now 2/tick (base 1 + level 1).
    world = world |> World.deposit_ore("p1", 10) |> World.refine_all()
    assert World.base(world, "p1").ore == 8
  end

  test "building cargo raises cargo_max on all of the player's harvesters" do
    world = solo(1) |> grant_goods("p1", 50) |> World.build("p1", :cargo)
    assert World.base(world, "p1").tech.cargo == 1

    caps = world.entities |> Enum.filter(&(&1.owner == "p1")) |> Enum.map(& &1.cargo_max)
    # base 5 + one level * step 5.
    assert Enum.all?(caps, &(&1 == 10))
  end

  test "building fuel raises the budget and is capped (never pay-to-win)" do
    assert World.fuel_budget(solo(1), "p1") == 50_000

    world = solo(1) |> grant_goods("p1", 1000)

    # Climb fuel to its cap, building as long as the sim says it's affordable.
    world =
      Enum.reduce_while(1..10, world, fn _i, w ->
        if World.can_build?(w, "p1", :fuel),
          do: {:cont, World.build(w, "p1", :fuel)},
          else: {:halt, w}
      end)

    b = World.base(world, "p1")
    assert b.tech.fuel == 4
    assert World.fuel_budget(world, "p1") == 150_000
    refute World.can_build?(world, "p1", :fuel)
  end

  test "can_build? is false when broke" do
    world = solo(1)
    refute World.can_build?(world, "p1", :refine)
    refute World.can_build?(world, "p1", :cargo)
    refute World.can_build?(world, "p1", :fuel)
  end

  test "building is bit-identical across independent runs (replay holds with the Forge)" do
    rules = rules()
    a = solo(11) |> Sim.run(rules, 400)
    b = solo(11) |> Sim.run(rules, 400)
    assert a == b
    # the default bot forges, so the run actually exercises the tech ladder.
    assert World.base(a, "p1").tech.refine > 0
  end

  # --- convoys + the contested market (primer §1, §4) ---

  # A decider whose harvesters idle, so only the convoy auto-pilot runs.
  defp idle_harvesters, do: fn _e, _w -> :idle end

  test "launching a convoy spends goods and spawns a market-bound convoy" do
    world = solo(1) |> grant_goods("p1", World.shipment_size())
    assert World.can_launch?(world, "p1")

    world = World.launch_convoy(world, "p1")
    assert World.base(world, "p1").goods == 0

    assert [convoy] = World.convoys(world)
    assert convoy.owner == "p1"
    assert convoy.kind == :convoy
    assert convoy.cargo == World.shipment_value()
  end

  test "a convoy runs to the market and sells its shipment for credits" do
    world = solo(1) |> grant_goods("p1", World.shipment_size()) |> World.launch_convoy("p1")

    # The map is 16x12, market at the far corner — 60 ticks is ample to arrive.
    final = Sim.run(world, idle_harvesters(), 60)

    assert World.convoys(final) == []
    assert World.credits(final, "p1") == World.shipment_value()
  end

  test "when two players' convoys meet, the lower-id one seizes the shipment (PvP)" do
    world =
      World.generate(seed: 1)
      |> World.add_player("p1")
      |> World.add_player("p2")
      |> grant_goods("p1", World.shipment_size())
      |> grant_goods("p2", World.shipment_size())
      |> World.launch_convoy("p1")
      |> World.launch_convoy("p2")

    # Both enter the shared market room at the same entry and step toward the
    # market together, so they share a cell — the lower-id convoy ambushes.
    final = Sim.run(world, idle_harvesters(), 1)

    assert [survivor] = World.convoys(final)
    assert survivor.cargo == 2 * World.shipment_value()
  end

  test "the default bot ships convoys to market over a long run (credits accrue)" do
    final = solo(7) |> Sim.run(rules(), 600)
    assert World.credits(final, "p1") > 0
  end
end
