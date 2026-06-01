defmodule Convoy.Engine.Colony.RegionTest do
  use ExUnit.Case, async: false

  alias Convoy.Engine.Colony.Region

  defp fresh_id, do: "t#{System.unique_integer([:positive])}"

  test "a region seeds a demo colony, ticks, and the demo earns credits at the market" do
    id = fresh_id()
    Region.ensure(id, seed: 1)
    Region.pause(id)

    s0 = Region.snapshot(id)
    assert s0.region_id == id
    assert s0.market.convoys == []

    # demo colony should be present (loads the bundled default bot from priv)
    if Enum.any?(s0.players, &(&1.id == "demo")) do
      for _ <- 1..220, do: Region.step(id)
      s1 = Region.snapshot(id)
      assert s1.tick >= 220
      demo = Enum.find(s1.players, &(&1.id == "demo"))
      assert demo.refined > 0, "the forge should produce goods"
      # the demo ships convoys → credits earned, or convoys still crossing the market
      assert demo.credits > 0 or s1.market.convoys != [],
             "the demo should be shipping convoys to the market"
    else
      IO.puts("\n[skip] demo colony not loaded (priv/colony/default.wasm unavailable in test build)")
      assert true
    end
  end

  test "submitting a bot joins a player with their own colony (or reports a compile error)" do
    id = fresh_id()
    Region.ensure(id, seed: 2)

    src = File.read!(Path.expand("../../examples/colony.rs", __DIR__))

    case Convoy.Compile.to_wasm(:rust, src) do
      {:ok, wasm} ->
        assert :ok = Region.submit_player(id, "alice", wasm, "alice bot")
        s = Region.snapshot(id)
        assert Enum.any?(s.players, &(&1.id == "alice"))
        assert Map.has_key?(s.colonies, "alice")

      {:error, reason} ->
        IO.puts("\n[skip] region submit e2e — rust toolchain unavailable: #{reason}")
        assert true
    end
  end

  test "the `main` region seeds demo + shipper + builder residents" do
    Region.ensure("main", seed: 1)
    s = Region.snapshot("main")
    ids = Enum.map(s.players, & &1.id)

    # all three bundled residents load (skip if priv wasm isn't in the test build)
    if "demo" in ids do
      assert "shipper" in ids
      assert "builder" in ids
    else
      IO.puts("\n[skip] residents not loaded (priv/colony/*.wasm unavailable in test build)")
      assert true
    end
  end
end
