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

  test "the sim conserves ore: delivered + in-cargo + in-ground == initial" do
    rules = rules()
    initial = World.generate(seed: 3)
    total = World.ore_remaining(initial)

    final = Sim.run(initial, rules, 150)
    in_cargo = final.entities |> Enum.map(& &1.cargo) |> Enum.sum()

    assert final.delivered + in_cargo + World.ore_remaining(final) == total
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
