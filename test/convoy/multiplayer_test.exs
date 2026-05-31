defmodule Convoy.MultiplayerTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine
  alias Convoy.Engine.{World, Program, Sim}

  @worker """
  when can_unload  unload
  when cargo_full  to_base
  when on_resource harvest
  otherwise        to_resource
  """

  defp worker_rules do
    {:ok, rules} = Program.compile(@worker)
    rules
  end

  test "generate seeds the default player; add_player adds more, idempotently" do
    world = World.generate(seed: 1)
    assert World.players(world) == ["p1"]
    assert length(world.entities) == World.harvesters_per_player()
    assert Enum.all?(world.entities, &(&1.owner == "p1"))

    world = World.add_player(world, "p2")
    assert Enum.sort(World.players(world)) == ["p1", "p2"]
    assert length(world.entities) == 2 * World.harvesters_per_player()

    # entity ids stay unique across players
    ids = Enum.map(world.entities, & &1.id)
    assert ids == Enum.uniq(ids)

    # re-adding an existing player changes nothing
    assert World.add_player(world, "p2") == world
  end

  test "two players score independently in one shared world" do
    rules = worker_rules()
    world = World.generate(seed: 7) |> World.add_player("p2")
    decider = fn entity, w -> Program.eval(rules, entity, w) end

    final = Sim.run(world, decider, 200)

    assert World.score(final, "p1") > 0
    assert World.score(final, "p2") > 0
    assert World.total_delivered(final) == World.score(final, "p1") + World.score(final, "p2")
  end

  test "a multi-player world stays deterministic across runs" do
    worker = worker_rules()
    {:ok, idler} = Program.compile("otherwise idle")

    build = fn -> World.generate(seed: 3) |> World.add_player("p2") end

    # p1 works, p2 idles — programs dispatched per entity owner.
    decider = fn e, w ->
      if e.owner == "p1", do: Program.eval(worker, e, w), else: Program.eval(idler, e, w)
    end

    a = Sim.run(build.(), decider, 150)
    b = Sim.run(build.(), decider, 150)

    assert a == b
    assert World.score(a, "p1") > 0
    assert World.score(a, "p2") == 0
  end

  test "a Region runs two submitted players with independent programs" do
    id = "mp-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)

    :ok = Engine.submit_player(id, "idle", :rules, "otherwise idle", "otherwise idle")
    :ok = Engine.submit_player(id, "worker", :rules, @worker, @worker)

    for _ <- 1..150, do: Engine.step(id)
    snap = Engine.snapshot(id)

    # Independent scoring: the idle bot earns nothing, the worker delivers.
    assert snap.scores["idle"] == 0
    assert snap.scores["worker"] > 0

    # Both players' harvesters share the one world (plus the default p1).
    owners = snap.world.entities |> Enum.map(& &1.owner) |> Enum.uniq()
    assert "idle" in owners
    assert "worker" in owners
    assert "p1" in owners
    assert Map.has_key?(snap.players, "worker")
  end
end
