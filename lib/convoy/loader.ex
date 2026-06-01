defmodule Convoy.Loader do
  @moduledoc """
  Turns a `{language, source}` pair into the arguments
  `Convoy.Engine.load_program/4` wants: `{backend, exec, display}`.

  This is the one place that knows how each language reaches the sim, shared by
  every entry point (the HTTP API, the browser upload, the `convoy.run` mix
  task) so they all behave identically. Everything ends up as a WASM module.
  Compilation (the risky part) is delegated to `Convoy.Compile`; this only routes.

  - `:wat` → Wasmtime compiles the text directly.
  - `:assemblyscript` / `:rust` / `:tinygo` / `:zig` / `:c` → compiled to wasm bytes first.
  - `:wasm` → raw `.wasm` bytes, loaded as-is.

  `exec` is what runs; `display` is the human-facing source (high-level source
  for compiled languages, a short label for raw bytes).
  """

  alias Convoy.Compile

  @compiled [:assemblyscript, :rust, :tinygo, :zig, :c]

  @type prepared :: {:ok, :wasm, binary(), String.t()} | {:error, String.t()}

  @doc "Prepare a program for loading. See the module doc for language behaviour."
  @spec prepare(atom(), binary()) :: prepared()
  def prepare(:wat, source), do: {:ok, :wasm, source, source}

  def prepare(:wasm, bytes) when is_binary(bytes) do
    {:ok, :wasm, bytes, "wasm module · #{byte_size(bytes)} bytes"}
  end

  def prepare(lang, source) when lang in @compiled do
    case Compile.to_wasm(lang, source) do
      {:ok, bytes} -> {:ok, :wasm, bytes, source}
      {:error, _msg} = err -> err
    end
  end

  def prepare(lang, _source), do: {:error, "unknown language: #{inspect(lang)}"}

  @doc "Languages that go through compilation (need a toolchain)."
  def compiled_languages, do: @compiled
end
