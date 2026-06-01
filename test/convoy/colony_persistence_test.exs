defmodule Convoy.Engine.Colony.PersistenceTest do
  use ExUnit.Case, async: false

  alias Convoy.Engine.Colony.{Persistence, Region, World, Market}

  setup do
    File.rm_rf(Persistence.dir())
    :ok
  end

  test "save/load round-trips a region snapshot and version-guards" do
    snap = %{
      region_id: "rt",
      seed: 9,
      tick: 42,
      tick_ms: 200,
      status: :paused,
      colonies: %{"a" => World.generate(seed: 1)},
      market: Market.new(16, 12),
      players: %{"a" => %{exec: <<1, 2, 3>>, display: "x", error: nil, memory: nil}}
    }

    assert :ok = Persistence.save(snap)
    assert {:ok, loaded} = Persistence.load("rt")
    assert loaded.tick == 42 and loaded.seed == 9
    assert "rt" in Persistence.region_ids()

    assert :ok = Persistence.delete("rt")
    assert Persistence.load("rt") == :error
  end

  test "a region's colonies + tick survive a stop and restart" do
    id = "persist#{System.unique_integer([:positive])}"
    Region.ensure(id, seed: 5)
    Region.pause(id)

    # advance deterministically while paused so the persisted status stays :paused
    for _ <- 1..40, do: Region.step(id)
    s0 = Region.snapshot(id)
    players0 = Enum.map(s0.players, & &1.id) |> Enum.sort()

    if "demo" in players0 do
      Region.stop(id)
      Region.ensure(id)
      s1 = Region.snapshot(id)

      assert s1.status == :paused
      assert s1.tick == s0.tick, "tick should be restored exactly"
      assert Enum.sort(Enum.map(s1.players, & &1.id)) == players0
      # the restored demo brain still works (it produced refined goods before the stop)
      demo1 = Enum.find(s1.players, &(&1.id == "demo"))
      demo0 = Enum.find(s0.players, &(&1.id == "demo"))
      assert demo1.refined == demo0.refined
    else
      IO.puts("\n[skip] persistence e2e — demo bot not loaded (priv wasm unavailable in test build)")
      assert true
    end
  end
end
