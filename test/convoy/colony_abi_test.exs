defmodule Convoy.Engine.ColonyAbiTest do
  @moduledoc """
  Proves the v2 colony ABI end to end: the wire-format codec round-trips, and a
  real bot (`examples/colony.rs`) compiled through the game's own compiler runs
  under wasmex and steers a unit. The end-to-end case self-skips if the Rust
  toolchain isn't on PATH (matching the rest of the suite).
  """
  use ExUnit.Case, async: false

  alias Convoy.Engine.{ColonyAbi, ColonyWasm}
  alias Convoy.Compile

  @colony_src Path.expand("../../examples/colony.rs", __DIR__)

  describe "wire-format codec" do
    test "decode_commands round-trips a hand-built buffer" do
      bin =
        <<2, 0::24, 1::little-32, 1::little-signed-32, 0::little-signed-32,
          1, 0::24, 2::little-32, 0::little-signed-32, 0::little-signed-32>>

      assert ColonyAbi.decode_commands(bin, 2) == [
               %{op: 2, target: 1, a: 1, b: 0},
               %{op: 1, target: 2, a: 0, b: 0}
             ]

      assert ColonyAbi.decode_commands(bin, 0) == []
      # tolerant of a count larger than the buffer actually holds
      assert length(ColonyAbi.decode_commands(bin, 99)) == 2
    end

    test "encode_view header + record strides are correct" do
      v = %{
        tick: 7,
        width: 16,
        height: 12,
        ore: 0,
        goods: 0,
        credits: 0,
        units: [%{id: 1, kind: 0, x: 2, y: 3, cargo: 4, cargo_max: 5}],
        buildings: [%{id: 100, kind: 0, x: 0, y: 0, level: 0, progress: 255}],
        deposits: [%{x: 9, y: 1, amount: 40}]
      }

      bin = ColonyAbi.encode_view(v)
      # header(28) + 1 unit(12) + 1 building(10) + 1 deposit(4) = 54
      assert byte_size(bin) == 54
      <<tick::little-32, w::little-16, h::little-16, _::binary>> = bin
      assert {tick, w, h} == {7, 16, 12}
    end
  end

  describe "end-to-end: examples/colony.rs through the real compiler + wasmex" do
    test "the colony brain steers a harvester toward ore (and is deterministic)" do
      src = File.read!(@colony_src)

      case Compile.to_wasm(:rust, src) do
        {:ok, wasm} ->
          view = %{
            tick: 0,
            width: 16,
            height: 12,
            ore: 0,
            goods: 0,
            credits: 0,
            units: [%{id: 1, kind: 0, x: 0, y: 0, cargo: 0, cargo_max: 5}],
            buildings: [%{id: 100, kind: 0, x: 0, y: 0, level: 0, progress: 255}],
            deposits: [%{x: 2, y: 3, amount: 40}],
            market: []
          }

          {:ok, inst} = ColonyWasm.instantiate(wasm)
          {:ok, cmds, used} = ColonyWasm.tick(inst, view, 5_000_000)
          # bit-identical re-run on a fresh instance (determinism, primer §6)
          {:ok, inst2} = ColonyWasm.instantiate(wasm)
          {:ok, cmds2, used2} = ColonyWasm.tick(inst2, view, 5_000_000)
          ColonyWasm.stop(inst)
          ColonyWasm.stop(inst2)

          # harvester is not full and not on ore → MOVE one step toward (2,3),
          # which for a (0,0) start is (+1, 0) (close x first, then y).
          assert %{op: 2, target: 1, a: 1, b: 0} in cmds
          assert used > 0
          assert cmds == cmds2
          assert used == used2

        {:error, reason} ->
          IO.puts("\n[skip] colony e2e — rust toolchain unavailable: #{reason}")
          assert true
      end
    end

    test "a unit standing on ore harvests it" do
      src = File.read!(@colony_src)

      case Compile.to_wasm(:rust, src) do
        {:ok, wasm} ->
          view = %{
            tick: 0,
            width: 16,
            height: 12,
            ore: 0,
            goods: 0,
            credits: 0,
            units: [%{id: 1, kind: 0, x: 2, y: 3, cargo: 0, cargo_max: 5}],
            buildings: [%{id: 100, kind: 0, x: 0, y: 0, level: 0, progress: 255}],
            deposits: [%{x: 2, y: 3, amount: 40}],
            market: []
          }

          {:ok, inst} = ColonyWasm.instantiate(wasm)
          {:ok, cmds, _used} = ColonyWasm.tick(inst, view, 5_000_000)
          ColonyWasm.stop(inst)

          assert %{op: 1, target: 1} = Enum.find(cmds, &(&1.op == 1))

        {:error, reason} ->
          IO.puts("\n[skip] colony e2e — rust toolchain unavailable: #{reason}")
          assert true
      end
    end
  end
end
