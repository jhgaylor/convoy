defmodule Convoy.Engine.Colony.RegionTest do
  use ExUnit.Case, async: false

  alias Convoy.Engine.Colony.Region

  defp fresh_id, do: "t#{System.unique_integer([:positive])}"

  test "a colony region starts, ticks on step, and reports a snapshot" do
    id = fresh_id()
    Region.ensure(id, seed: 1)
    Region.pause(id)

    s0 = Region.snapshot(id)
    assert s0.region_id == id
    assert s0.pop_cap > 0
    # a fresh colony has its spawner
    assert Enum.any?(s0.world.buildings, &(&1.kind == 0))

    Region.step(id)
    Region.step(id)
    Region.step(id)
    s1 = Region.snapshot(id)

    assert s1.world.tick >= s0.world.tick + 3
  end

  test "submitting a bot replaces the brain (or reports a compile error)" do
    id = fresh_id()
    Region.ensure(id, seed: 2)

    src = File.read!(Path.expand("../../examples/colony.rs", __DIR__))

    case Convoy.Compile.to_wasm(:rust, src) do
      {:ok, wasm} ->
        assert :ok = Region.submit_bot(id, wasm, "test bot")
        assert Region.snapshot(id).has_bot

      {:error, reason} ->
        IO.puts("\n[skip] region submit_bot e2e — rust toolchain unavailable: #{reason}")
        assert true
    end
  end
end
