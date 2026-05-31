defmodule Convoy.Compile do
  @moduledoc """
  Turns player **source code** into a `.wasm` module the sim can run.

  This is the compile step that sits *in front of* the execution tier
  (`Convoy.Engine.Wasm`). The sim host itself never compiles untrusted code —
  it only instantiates the finished bytes. Compilation is a distinct, riskier
  concern handled here.

  ## Safety model

  Compiling arbitrary source is a remote-code-execution surface (a malicious
  `build.rs`, an `npm` post-install hook, etc.). We shrink that surface:

  - **Single source file only.** We invoke `rustc` (not `cargo`) and `asc` on
    one file with no manifest, so there are no dependency fetches and no build
    scripts to run.
  - **No network, temp dir, hard timeout.** Each build runs in a throwaway
    directory and is killed if it overruns.

  This is the in-process layer. Production should move compilation to the
  separate, locked-down build service from primer §10 (gVisor/Firecracker, no
  egress, ephemeral) — the same isolation argument as the runner pool. The
  abstraction here (`to_wasm/2`) would point at that service unchanged.

  ## Languages

  `:wat` compiles for free (Wasmtime reads text). `:assemblyscript` uses the
  pure-JS `asc` compiler (no native toolchain). `:rust` and `:tinygo` need
  their native toolchains installed; `available?/1` reports presence and
  `install_hint/1` says how to get them. Every module must export `decide`
  with the ABI in `Convoy.Engine.Wasm`.
  """

  @timeout_ms 20_000

  @doc "Languages this module can compile from source (excludes :rules and raw :upload)."
  @spec languages() :: [atom()]
  def languages, do: [:wat, :assemblyscript, :rust, :tinygo]

  @doc "Human label for a language id."
  def label(:wat), do: "WAT"
  def label(:assemblyscript), do: "AssemblyScript"
  def label(:rust), do: "Rust"
  def label(:tinygo), do: "TinyGo"

  @doc """
  Compile source to wasm bytes (or pass WAT text through untouched, since
  Wasmtime compiles it directly). Returns `{:ok, bytes_or_wat}` or
  `{:error, message}`.
  """
  @spec to_wasm(atom(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def to_wasm(:wat, source), do: {:ok, source}
  def to_wasm(:assemblyscript, source), do: compile_assemblyscript(source)
  def to_wasm(:rust, source), do: compile_rust(source)
  def to_wasm(:tinygo, source), do: compile_tinygo(source)

  @doc "Is the toolchain for this language available on this host?"
  @spec available?(atom()) :: boolean()
  def available?(:wat), do: true
  def available?(:assemblyscript), do: File.exists?(asc_bin())
  def available?(:rust), do: not is_nil(rustc_bin())
  def available?(:tinygo), do: not is_nil(System.find_executable("tinygo"))
  def available?(_), do: false

  @doc "How to install a missing toolchain."
  def install_hint(:rust),
    do: "Install Rust + the wasm target: `curl https://sh.rustup.rs -sSf | sh` then `rustup target add wasm32-unknown-unknown`."

  def install_hint(:tinygo), do: "Install TinyGo: `brew install tinygo` (needs LLVM)."
  def install_hint(:assemblyscript), do: "Run `npm install assemblyscript` in priv/asc."
  def install_hint(_), do: nil

  # --- starter templates (each exports `decide` with the Wasm ABI) ---

  @doc "Starter source for a language, reproducing the default harvester logic."
  def template(:assemblyscript) do
    """
    // Harvester behaviour in AssemblyScript. Compiled in-game with `asc`.
    // Return an intent code (see the ABI panel); the sim resolves it.
    export function decide(
      cargo: i32, cargoMax: i32, atBase: i32, onResource: i32,
      resDx: i32, resDy: i32, baseDx: i32, baseDy: i32, tick: i32
    ): i32 {
      if (atBase && cargo > 0) return 2; // unload
      if (cargo >= cargoMax)   return 3; // head to base
      if (onResource)          return 1; // harvest
      return 4;                          // seek nearest ore
    }
    """
  end

  def template(:rust) do
    """
    // Harvester behaviour in Rust, compiled single-file to wasm32 (no_std,
    // no cargo). Export `decide`; return an intent code.
    #![no_std]
    #[panic_handler]
    fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

    #[no_mangle]
    pub extern "C" fn decide(
        cargo: i32, cargo_max: i32, at_base: i32, on_resource: i32,
        _res_dx: i32, _res_dy: i32, _base_dx: i32, _base_dy: i32, _tick: i32,
    ) -> i32 {
        if at_base != 0 && cargo > 0 { return 2; } // unload
        if cargo >= cargo_max         { return 3; } // head to base
        if on_resource != 0           { return 1; } // harvest
        4                                           // seek nearest ore
    }
    """
  end

  def template(:tinygo) do
    """
    // Harvester behaviour in Go, compiled with TinyGo to wasm.
    package main

    //export decide
    func decide(cargo, cargoMax, atBase, onResource, resDx, resDy, baseDx, baseDy, tick int32) int32 {
    \tif atBase != 0 && cargo > 0 {
    \t\treturn 2 // unload
    \t}
    \tif cargo >= cargoMax {
    \t\treturn 3 // head to base
    \t}
    \tif onResource != 0 {
    \t\treturn 1 // harvest
    \t}
    \treturn 4 // seek nearest ore
    }

    func main() {}
    """
  end

  # --- compiler backends ---

  defp compile_assemblyscript(source) do
    bin = asc_bin()

    if File.exists?(bin) do
      with_tempdir(fn dir ->
        in_file = Path.join(dir, "bot.ts")
        out_file = Path.join(dir, "bot.wasm")
        File.write!(in_file, source)

        run(bin, [in_file, "--outFile", out_file, "--runtime", "stub", "--optimize"], out_file)
      end)
    else
      {:error, "AssemblyScript compiler not installed. #{install_hint(:assemblyscript)}"}
    end
  end

  defp compile_rust(source) do
    case rustc_bin() do
      nil ->
        {:error, "Rust toolchain not found. #{install_hint(:rust)}"}

      bin ->
        with_tempdir(fn dir ->
          in_file = Path.join(dir, "bot.rs")
          out_file = Path.join(dir, "bot.wasm")
          File.write!(in_file, source)

          args = [
            "--target",
            "wasm32-unknown-unknown",
            "-O",
            "--crate-type",
            "cdylib",
            "-o",
            out_file,
            in_file
          ]

          run(bin, args, out_file)
        end)
    end
  end

  defp compile_tinygo(source) do
    case System.find_executable("tinygo") do
      nil ->
        {:error, "TinyGo not found. #{install_hint(:tinygo)}"}

      bin ->
        with_tempdir(fn dir ->
          in_file = Path.join(dir, "bot.go")
          out_file = Path.join(dir, "bot.wasm")
          File.write!(in_file, source)

          run(bin, ["build", "-o", out_file, "-target=wasm", "-no-debug", in_file], out_file)
        end)
    end
  end

  # --- shared compile machinery ---

  # Run a compiler with a hard timeout; on success read the wasm output.
  defp run(bin, args, out_file) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        if File.exists?(out_file), do: {:ok, File.read!(out_file)}, else: {:error, "compiler produced no output"}

      {:ok, {out, _code}} ->
        {:error, trim_output(out)}

      nil ->
        {:error, "compilation timed out after #{div(@timeout_ms, 1000)}s"}
    end
  end

  defp with_tempdir(fun) do
    dir = Path.join(System.tmp_dir!(), "convoy-build-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # Keep error messages bounded and readable in the UI.
  defp trim_output(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.take(12)
    |> Enum.join("\n")
  end

  # --- toolchain locations ---

  defp asc_bin, do: Path.join([priv_dir(), "asc", "node_modules", ".bin", "asc"])

  defp rustc_bin do
    System.find_executable("rustc") ||
      with path <- Path.expand("~/.cargo/bin/rustc"), true <- File.exists?(path) do
        path
      else
        _ -> nil
      end
  end

  defp priv_dir do
    case :code.priv_dir(:convoy) do
      {:error, _} -> Path.join(File.cwd!(), "priv")
      dir -> to_string(dir)
    end
  end
end
