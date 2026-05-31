defmodule Convoy.EngineTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Program, Sim}

  @program """
  when can_unload  unload
  when cargo_full  to_base
  when on_resource harvest
  otherwise        to_resource
  """

  defp rules do
    {:ok, rules} = Program.compile(@program)
    rules
  end

  test "the default program compiles to four rules" do
    assert {:ok, rules} = Program.compile(@program)
    assert length(rules) == 4
    assert {:always, :to_resource} = List.last(rules)
  end

  test "compile reports line-numbered errors for unknown tokens" do
    assert {:error, msg} = Program.compile("when nonsense harvest")
    assert msg =~ "line 1"
    assert msg =~ "unknown condition"
  end

  test "same seed produces an identical world layout" do
    a = World.generate(seed: 42)
    b = World.generate(seed: 42)
    assert a.resources == b.resources
    assert a.entities == b.entities
  end

  test "different seeds produce different layouts" do
    refute World.generate(seed: 1).resources == World.generate(seed: 2).resources
  end

  test "nearest/farthest_resource pick the closest/most-distant node" do
    world = %{World.generate(seed: 1) | resources: %{{1, 0} => 5, {14, 8} => 5}}
    assert World.nearest_resource(world, {0, 0}) == {1, 0}
    assert World.farthest_resource(world, {0, 0}) == {14, 8}
  end

  test "farthest_resource is deterministic and returns nil on an empty map" do
    world = %{World.generate(seed: 1) | resources: %{{2, 2} => 1, {9, 9} => 1}}
    assert World.farthest_resource(world, {0, 0}) == World.farthest_resource(world, {0, 0})
    assert World.farthest_resource(%{world | resources: %{}}, {0, 0}) == nil
  end

  # The primer §11 acceptance test, in miniature: running the same program
  # from the same seed must be bit-identical across independent runs (the
  # freeze/replay guarantee).
  test "the tick loop is deterministic across independent runs" do
    rules = rules()
    run_a = World.generate(seed: 7) |> Sim.run(rules, 200)
    run_b = World.generate(seed: 7) |> Sim.run(rules, 200)
    assert run_a == run_b
  end

  test "harvesters actually deliver ore to the base over time" do
    final = World.generate(seed: 7) |> Sim.run(rules(), 200)
    assert final.delivered > 0
    assert final.tick == 200
  end

  test "the sim conserves ore: delivered + in-cargo + in-ground == initial + spawned" do
    rules = rules()
    initial = World.generate(seed: 3)
    total = World.ore_remaining(initial)

    final = Sim.run(initial, rules, 150)
    in_cargo = final.entities |> Enum.map(& &1.cargo) |> Enum.sum()
    spawned = final.replenished * World.resource_amount()

    assert final.delivered + in_cargo + World.ore_remaining(final) == total + spawned
  end

  test "a dwindling map spawns a fresh deposit at its last node" do
    world = %{World.generate(seed: 1) | resources: %{{5, 5} => 3}}
    assert World.resource_node_count(world) == 1

    {world, pos} = World.maybe_spawn_resource(world)
    assert pos != nil
    assert World.resource_node_count(world) == 2
    assert World.resource_at(world, pos) == World.resource_amount()
    assert world.replenished == 1
  end

  test "no deposit spawns while several remain" do
    world = World.generate(seed: 1)
    assert {^world, nil} = World.maybe_spawn_resource(world)
  end

  test "spawn placement is deterministic for the same seed + tick" do
    world = %{World.generate(seed: 2) | resources: %{{3, 3} => 1}, tick: 17}
    {_, a} = World.maybe_spawn_resource(world)
    {_, b} = World.maybe_spawn_resource(world)
    assert a == b
  end

  test "the region never runs dry over a long run" do
    final = World.generate(seed: 4) |> Sim.run(rules(), 1000)
    assert World.ore_remaining(final) > 0
    assert World.resource_node_count(final) >= 1
    assert final.replenished > 0
  end

  test "player code cannot move an entity outside the grid" do
    rules = rules()
    final = World.generate(seed: 5) |> Sim.run(rules, 300)

    for e <- final.entities do
      assert e.x in 0..(final.width - 1)
      assert e.y in 0..(final.height - 1)
    end
  end
end
