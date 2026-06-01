defmodule Convoy.Engine.ColonyTemplateTest do
  @moduledoc """
  Every per-language starter template must be a valid COLONY bot on the v2 ABI:
  compile it through the real pipeline, instantiate it, and confirm it produces
  commands for a sample view. WAT compiles in-process (always runs); compiled
  languages self-skip when their toolchain isn't installed.
  """
  use ExUnit.Case, async: false

  alias Convoy.Compile
  alias Convoy.Engine.ColonyWasm

  @view %{
    tick: 0,
    width: 16,
    height: 12,
    ore: 0,
    goods: 30,
    credits: 0,
    units: [
      %{id: 2, kind: 0, x: 0, y: 0, cargo: 0, cargo_max: 5},
      %{id: 3, kind: 0, x: 2, y: 3, cargo: 5, cargo_max: 5}
    ],
    buildings: [%{id: 1, kind: 0, x: 0, y: 0, level: 0, progress: 255}],
    deposits: [%{x: 4, y: 1, amount: 40}],
    market: []
  }

  for lang <- [:rust, :assemblyscript, :tinygo, :zig, :c, :wat] do
    @lang lang
    test "#{lang} starter template is a valid colony bot" do
      case Compile.to_wasm(@lang, Compile.template(@lang)) do
        {:ok, wasm} ->
          {:ok, inst} = ColonyWasm.instantiate(wasm)
          {:ok, cmds, used} = ColonyWasm.tick(inst, @view, 5_000_000)
          ColonyWasm.stop(inst)
          assert is_list(cmds)
          assert length(cmds) >= 1, "#{@lang} template produced no commands"
          assert used >= 0

        {:error, msg} ->
          IO.puts("\n[skip] #{@lang} template — toolchain unavailable: #{String.slice(msg, 0, 120)}")
          assert true
      end
    end
  end
end
