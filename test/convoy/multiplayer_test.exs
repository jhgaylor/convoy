defmodule Convoy.MultiplayerTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine
  alias Convoy.Engine.{World, Sim}

  test "a fresh world has no players; add_player adds them, idempotently" do
    world = World.generate(seed: 1)
    assert World.players(world) == []
    assert world.entities == []

    world = World.add_player(world, "p1")
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
    world = World.generate(seed: 7) |> World.add_player("p1") |> World.add_player("p2")

    final = Sim.run(world, &Convoy.Bots.harvester/2, 200)

    assert World.score(final, "p1") > 0
    assert World.score(final, "p2") > 0
    assert World.total_refined(final) == World.score(final, "p1") + World.score(final, "p2")
  end

  test "a multi-player world stays deterministic across runs" do
    build = fn -> World.generate(seed: 3) |> World.add_player("p1") |> World.add_player("p2") end

    # p1 works, p2 idles — dispatched per entity owner.
    decider = fn e, w ->
      if e.owner == "p1", do: Convoy.Bots.harvester(e, w), else: :idle
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

    :ok = Engine.submit_player(id, "idle", :wasm, Convoy.Bots.wat_idle(), "idle")
    :ok = Engine.submit_player(id, "worker", :wasm, Convoy.Bots.wat_harvester(), "worker")

    for _ <- 1..150, do: Engine.step(id)
    snap = Engine.snapshot(id)

    # Independent scoring: the idle bot earns nothing, the worker delivers.
    assert snap.scores["idle"] == 0
    assert snap.scores["worker"] > 0

    # Only the submitted players exist in the shared world — no phantom default.
    owners = snap.world.entities |> Enum.map(& &1.owner) |> Enum.uniq() |> Enum.sort()
    assert owners == ["idle", "worker"]
    assert Map.has_key?(snap.players, "worker")
  end

  test "remove_player drops a player's harvesters and score" do
    world = World.generate(seed: 1) |> World.add_player("p1") |> World.add_player("p2")
    world = World.remove_player(world, "p1")

    assert World.players(world) == ["p2"]
    assert Enum.all?(world.entities, &(&1.owner == "p2"))
    assert World.score(world, "p1") == 0
    # removing an absent player is a no-op
    assert World.remove_player(world, "ghost") == world
  end

  test "kicking a player from a Region removes them but leaves others running" do
    id = "mp-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)
    :ok = Engine.submit_player(id, "alice", :wasm, Convoy.Bots.wat_harvester(), "alice")
    :ok = Engine.submit_player(id, "bob", :wasm, Convoy.Bots.wat_harvester(), "bob")

    assert :ok = Engine.kick_player(id, "alice")
    snap = Engine.snapshot(id)

    assert Map.keys(snap.scores) == ["bob"]
    refute Map.has_key?(snap.players, "alice")
    owners = snap.world.entities |> Enum.map(& &1.owner) |> Enum.uniq()
    assert owners == ["bob"]

    # kicking someone who isn't there is reported, not crashing
    assert {:error, :not_found} = Engine.kick_player(id, "nobody")
  end

  test "a fresh region has no players until someone submits" do
    id = "empty-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)
    snap = Engine.snapshot(id)

    assert snap.scores == %{}
    assert snap.world.entities == []
    assert snap.players == %{}
  end
end
