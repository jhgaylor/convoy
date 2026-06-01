defmodule Convoy.StrategistTest do
  use ExUnit.Case, async: false

  alias Convoy.Compile
  alias Convoy.Engine.{World, Sim, Wasm}

  # Compile a bot file, run it solo for `ticks`, and return the final world plus
  # a snapshot of its linear memory.
  defp run_bot(lang, file, ticks) do
    {:ok, bytes} = Compile.to_wasm(lang, File.read!(file))
    {:ok, inst} = Wasm.instantiate(bytes)

    decider = fn e, w ->
      {:ok, intent, _used} = Wasm.decide(inst, e, w, 50_000)
      intent
    end

    world = World.generate(seed: 7) |> World.add_player("p1") |> Sim.run(decider, ticks)
    mem = Wasm.snapshot_memory(inst)
    Wasm.stop(inst)
    {world, mem}
  end

  # The strategist plays the whole loop (harvest → forge → ship for credits) and
  # keeps persistent state in linear memory (its last-launch tick). We assert
  # both: credits accrue (it ships), and its memory is written + exported (so it
  # survives a freeze/thaw).
  defp assert_full_game_with_memory(lang, file) do
    {world, mem} = run_bot(lang, file, 400)
    assert World.credits(world, "p1") > 0, "expected the strategist to ship convoys for credits"
    assert is_binary(mem), "expected the module to export memory (for §8 persistence)"

    assert Enum.any?(:binary.bin_to_list(mem), &(&1 != 0)),
           "expected it to have written its Memory"
  end

  @tag :rust
  test "the Rust strategist plays the full game and uses Memory" do
    if Compile.available?(:rust) do
      assert_full_game_with_memory(:rust, "examples/strategist.rs")
    else
      IO.puts("[skip] Rust toolchain not installed")
    end
  end

  @tag :assemblyscript
  test "the AssemblyScript strategist plays the full game and uses Memory" do
    if Compile.available?(:assemblyscript) do
      assert_full_game_with_memory(:assemblyscript, "examples/strategist.ts")
    else
      IO.puts("[skip] AssemblyScript toolchain not installed")
    end
  end
end
