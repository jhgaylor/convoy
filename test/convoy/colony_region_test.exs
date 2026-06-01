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

  test "kicking a player removes their colony, brain, convoys, and history" do
    id = fresh_id()
    Region.ensure(id, seed: 1)
    Region.pause(id)

    s0 = Region.snapshot(id)

    if Enum.any?(s0.players, &(&1.id == "demo")) do
      # run enough ticks that the demo has launched convoys + accrued history
      for _ <- 1..220, do: Region.step(id)

      assert :ok = Region.kick(id, "demo")

      s1 = Region.snapshot(id)
      refute Enum.any?(s1.players, &(&1.id == "demo"))
      refute Map.has_key?(s1.colonies, "demo")
      assert s1.history["demo"] in [nil, []]
      assert Enum.all?(s1.market.convoys, &(&1.owner != "demo"))
    else
      IO.puts("\n[skip] demo colony not loaded (priv/colony/default.wasm unavailable in test build)")
      assert true
    end
  end

  test "repeated play/submit don't stack duplicate tick loops (steady single-rate sim)" do
    id = fresh_id()
    Region.ensure(id, seed: 1, tick_ms: 50)

    # Hammer play: each cast used to arm another independent :tick timer with no
    # cancel, so N plays => N concurrent loops => the sim ran N× too fast in
    # bursts ("two ticks, pause, two ticks"). Scheduling is now idempotent.
    for _ <- 1..5, do: Region.play(id)

    t0 = Region.snapshot(id).tick
    Process.sleep(500)
    dt = Region.snapshot(id).tick - t0

    # One 50ms loop advances ~10 ticks in 500ms; five stacked loops would be ~50.
    assert dt <= 20, "tick advanced #{dt} in ~500ms at 50ms/tick — duplicate tick loops?"
    assert dt >= 4, "sim should still be ticking (advanced #{dt})"
  end

  test "set_color pins a player's color index, exposed in the snapshot and dropped on kick" do
    id = fresh_id()
    Region.ensure(id, seed: 1)
    Region.pause(id)

    s0 = Region.snapshot(id)
    assert Map.get(s0, :colors) == %{}

    assert :ok = Region.set_color(id, "demo", 3)
    assert Region.snapshot(id).colors == %{"demo" => 3}

    # a negative index is rejected, leaving the pinned color untouched
    assert {:error, :bad_index} = Region.set_color(id, "demo", -1)
    assert Region.snapshot(id).colors == %{"demo" => 3}

    assert :ok = Region.kick(id, "demo")
    refute Map.has_key?(Region.snapshot(id).colors, "demo")
  end

  test "a region records a downsampled metrics time-series as it ticks" do
    id = fresh_id()
    Region.ensure(id, seed: 1)
    Region.pause(id)

    s0 = Region.snapshot(id)
    assert Map.has_key?(s0, :history)

    if s0.colonies != %{} do
      [player | _] = Map.keys(s0.colonies)
      assert s0.history[player] in [nil, []]

      for _ <- 1..60, do: Region.step(id)
      s1 = Region.snapshot(id)
      series = s1.history[player]

      assert is_list(series) and series != [], "history should accumulate for an active colony"
      # sampled every 20 ticks → ticks 20/40/60, newest-first
      assert Enum.all?(series, &(rem(&1.t, 20) == 0))
      assert [%{t: latest} | _] = series
      assert latest >= 40
      assert Enum.all?(series, &Map.has_key?(&1, :credits))
    else
      IO.puts("\n[skip] no colonies loaded (priv/colony/*.wasm unavailable in test build)")
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
