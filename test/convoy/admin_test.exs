defmodule Convoy.AdminTest do
  use ExUnit.Case, async: false

  alias Convoy.Engine

  test "list_regions reports running regions; stop removes them" do
    id = "ov-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)

    assert id in Engine.list_regions()

    :ok = Engine.stop_region(id)
    # Give the supervisor a moment to reap the child.
    Process.sleep(20)
    refute id in Engine.list_regions()
  end

  test "region_stats reports world + process utilization (incl. wasm instances)" do
    id = "ov-#{System.unique_integer([:positive])}"
    wat = "(module (func (export \"decide\") (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 4)))"
    Engine.ensure_region(id)
    Engine.submit_player(id, "seeker", :wasm, Convoy.Bots.wat_seeker(), "seeker")
    Engine.submit_player(id, "wasm_bot", :wasm, wat, wat)

    stats = Engine.region_stats(id)
    assert stats.region_id == id
    assert stats.players == 2
    assert stats.entities == 6
    # Both players' wasm instance processes are counted.
    assert stats.wasm_instances == 2
    assert is_integer(stats.memory) and stats.memory > 0
    assert is_integer(stats.reductions) and stats.reductions > 0

    Engine.stop_region(id)
  end

  test "region_stats returns nil for an unknown region" do
    assert Engine.region_stats("does-not-exist-#{System.unique_integer([:positive])}") == nil
  end

  test "a stopped (persisted) region is still listed and deletable" do
    id = "ov-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id, persist: true)
    Engine.submit_player(id, "p1", :wasm, Convoy.Bots.wat_idle(), "idle")

    # Stop: the process is gone but the snapshot remains.
    Engine.stop_region(id)
    Process.sleep(20)
    refute id in Engine.list_regions()
    assert id in Engine.persisted_regions()

    # The overview can still build a row for it (status :stopped) and delete it.
    stats = Engine.stopped_region_stats(id)
    assert stats.status == :stopped
    assert stats.players == 1
    assert stats.entities == 3

    Engine.delete_region(id)
    refute id in Engine.persisted_regions()
  end

  test "delete_region stops it and removes the snapshot" do
    id = "ov-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id, persist: true)
    Engine.submit_player(id, "p1", :wasm, Convoy.Bots.wat_idle(), "idle")

    assert {:ok, _} = Convoy.Persistence.load(id)

    Engine.delete_region(id)
    Process.sleep(20)
    refute id in Engine.list_regions()
    assert :error = Convoy.Persistence.load(id)
  end
end
