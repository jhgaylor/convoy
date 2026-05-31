defmodule Convoy.PersistenceTest do
  # async: false — these touch the shared on-disk snapshot dir.
  use ExUnit.Case, async: false

  alias Convoy.{Engine, Persistence}
  alias Convoy.Engine.World

  setup do
    File.rm_rf(Persistence.dir())
    :ok
  end

  test "save/load round-trips a snapshot map" do
    id = "rt-#{System.unique_integer([:positive])}"
    snap = %{version: 1, region_id: id, world: World.generate(seed: 5), backend: :rules}

    assert :ok = Persistence.save(id, snap)
    assert {:ok, loaded} = Persistence.load(id)
    assert loaded.world == snap.world
    assert loaded.region_id == id
  end

  test "load returns :error when nothing is saved" do
    assert :error = Persistence.load("never-saved-#{System.unique_integer([:positive])}")
  end

  test "delete removes a snapshot" do
    id = "del-#{System.unique_integer([:positive])}"
    Persistence.save(id, %{region_id: id, v: 1})
    assert {:ok, _} = Persistence.load(id)
    Persistence.delete(id)
    assert :error = Persistence.load(id)
  end

  test "region_ids lists saved regions by their true id" do
    id = "list-#{System.unique_integer([:positive])}"
    Persistence.save(id, %{version: 1, region_id: id, world: World.generate(seed: 1)})
    assert id in Persistence.region_ids()
  end

  # The freeze/thaw guarantee (primer §8, §11): a durable region resumes at the
  # tick it stopped, still running its program — as if a deploy never happened.
  test "a durable region resumes from its snapshot after the process restarts" do
    id = "resume-#{System.unique_integer([:positive])}"

    Engine.ensure_region(id, persist: true)
    :ok = Engine.load_program(id, :rules, "otherwise to_resource", "otherwise to_resource")
    Engine.set_speed(id, 20)
    Engine.play(id)

    # Let it run a few ticks, then force a snapshot by stopping the process.
    Process.sleep(150)
    before = Engine.snapshot(id)
    assert before.world.tick > 0

    # Simulate a deploy: kill the region process. terminate/2 writes a snapshot.
    [{pid, _}] = Registry.lookup(Convoy.Engine.RegionRegistry, id)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    # Start it again — it should restore, not regenerate.
    Engine.ensure_region(id, persist: true)
    after_restart = Engine.snapshot(id)

    assert after_restart.world.tick >= before.world.tick
    assert after_restart.world.tick > 0
    assert after_restart.backend == :rules
    assert after_restart.status == :running
    assert after_restart.world.region_id == id

    Persistence.delete(id)
  end

  test "a stale-version snapshot is discarded instead of crashing" do
    id = "stale-#{System.unique_integer([:positive])}"
    # An older deploy's snapshot (wrong version) must not be restored.
    Persistence.save(id, %{version: 0, region_id: id, world: World.generate(seed: 1), backend: :rules})

    Engine.ensure_region(id, persist: true)
    snap = Engine.snapshot(id)
    # Fresh start (tick 0), not a crash.
    assert snap.world.tick == 0
    Persistence.delete(id)
  end
end
