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

  @doc "Languages this module can compile from source (excludes raw :upload)."
  @spec languages() :: [atom()]
  def languages, do: [:wat, :assemblyscript, :rust, :tinygo, :zig, :c]

  @doc "Human label for a language id."
  def label(:wat), do: "WAT"
  def label(:assemblyscript), do: "AssemblyScript"
  def label(:rust), do: "Rust"
  def label(:tinygo), do: "TinyGo"
  def label(:zig), do: "Zig"
  def label(:c), do: "C"

  @doc """
  Compile source to wasm bytes (or pass WAT text through untouched, since
  Wasmtime compiles it directly). Returns `{:ok, bytes_or_wat}` or
  `{:error, message}`.
  """
  @compiled [:assemblyscript, :rust, :tinygo, :zig, :c]

  @spec to_wasm(atom(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def to_wasm(:wat, source), do: {:ok, source}

  def to_wasm(lang, source) when lang in @compiled do
    # If a sandboxed builder service is configured (prod), delegate compilation
    # to it — untrusted source never runs a toolchain inside the app pod. In
    # dev, fall back to local toolchains.
    case builder_url() do
      nil -> compile_locally(lang, source)
      url -> compile_remote(url, lang, source)
    end
  end

  defp compile_locally(:assemblyscript, source), do: compile_assemblyscript(source)
  defp compile_locally(:rust, source), do: compile_rust(source)
  defp compile_locally(:tinygo, source), do: compile_tinygo(source)
  defp compile_locally(:zig, source), do: compile_zig(source)
  defp compile_locally(:c, source), do: compile_c(source)

  @doc "Is the toolchain for this language available (via the builder, or locally)?"
  @spec available?(atom()) :: boolean()
  def available?(:wat), do: true

  def available?(lang) when lang in @compiled,
    do: not is_nil(builder_url()) or local_available?(lang)

  def available?(_), do: false

  defp local_available?(:assemblyscript), do: File.exists?(asc_bin())
  defp local_available?(:rust), do: not is_nil(rustc_bin())
  defp local_available?(:tinygo), do: not is_nil(System.find_executable("tinygo"))
  defp local_available?(:zig), do: not is_nil(System.find_executable("zig"))
  # Apple's stock clang lacks `wasm-ld`, so require both a clang and the wasm
  # linker before claiming C is buildable (Homebrew LLVM ships both).
  defp local_available?(:c), do: not is_nil(clang_bin()) and not is_nil(wasm_ld_bin())

  # --- remote builder (sandboxed compile service) ---

  defp builder_url do
    case System.get_env("CONVOY_BUILDER_URL") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp compile_remote(url, lang, source) do
    _ = :inets.start()
    body = Jason.encode!(%{language: Atom.to_string(lang), source: source})
    request = {String.to_charlist(url <> "/compile"), [], ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 30_000}], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, wasm}} -> {:ok, wasm}
      {:ok, {{_v, _code, _r}, _h, err}} -> {:error, String.trim(to_string(err))}
      {:error, reason} -> {:error, "builder unreachable: #{inspect(reason)}"}
    end
  end

  @doc "How to install a missing toolchain."
  def install_hint(:rust),
    do:
      "Install Rust + the wasm target: `curl https://sh.rustup.rs -sSf | sh` then `rustup target add wasm32-unknown-unknown`."

  def install_hint(:tinygo),
    do: "Install TinyGo: `brew install tinygo-org/tools/tinygo` (needs LLVM)."

  def install_hint(:assemblyscript), do: "Run `npm install assemblyscript` in priv/asc."

  def install_hint(:zig),
    do: "Install Zig: `brew install zig` or grab a build from https://ziglang.org/download."

  def install_hint(:c),
    do:
      "Install an LLVM clang with the wasm linker: `brew install llvm` (provides clang + wasm-ld). Apple's stock clang won't link wasm."

  def install_hint(_), do: nil

  # --- starter templates (each exports `decide` with the Wasm ABI) ---

  @doc "Starter source for a language, reproducing the default harvester logic."
  def template(:assemblyscript) do
    """
    // Harvester + forge in AssemblyScript. Compiled in-game with `asc`.
    // Return an intent code (see the ABI panel); the sim resolves it.
    export function decide(
      cargo: i32, cargoMax: i32, atBase: i32, onResource: i32,
      resDx: i32, resDy: i32, baseDx: i32, baseDy: i32, tick: i32,
      baseOre: i32, baseGoods: i32, canRefine: i32, canCargo: i32, canFuel: i32
    ): i32 {
      if (atBase && cargo > 0) return 2; // unload into the forge
      if (atBase) {                      // empty-handed at base: climb the tech ladder
        if (canRefine) return 20;        //   faster refining
        if (canCargo)  return 21;        //   bigger cargo
        if (canFuel)   return 22;        //   more fuel budget
      }
      if (cargo >= cargoMax) return 3;   // head to base
      if (onResource)        return 1;   // harvest
      return 4;                          // seek nearest ore
    }
    """
  end

  def template(:rust) do
    """
    // Harvester + forge in Rust, compiled single-file to wasm32 (no_std,
    // no cargo). Export `decide`; return an intent code.
    #![no_std]
    #[panic_handler]
    fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

    #[no_mangle]
    pub extern "C" fn decide(
        cargo: i32, cargo_max: i32, at_base: i32, on_resource: i32,
        _res_dx: i32, _res_dy: i32, _base_dx: i32, _base_dy: i32, _tick: i32,
        _base_ore: i32, _base_goods: i32, can_refine: i32, can_cargo: i32, can_fuel: i32,
    ) -> i32 {
        if at_base != 0 && cargo > 0 { return 2; } // unload into the forge
        if at_base != 0 {                          // empty at base: climb the tech ladder
            if can_refine != 0 { return 20; }      //   faster refining
            if can_cargo != 0  { return 21; }      //   bigger cargo
            if can_fuel != 0   { return 22; }      //   more fuel budget
        }
        if cargo >= cargo_max { return 3; }        // head to base
        if on_resource != 0   { return 1; }        // harvest
        4                                          // seek nearest ore
    }
    """
  end

  def template(:tinygo) do
    """
    // Harvester + forge in Go, compiled with TinyGo to wasm.
    package main

    //export decide
    func decide(cargo, cargoMax, atBase, onResource, resDx, resDy, baseDx, baseDy, tick,
    \tbaseOre, baseGoods, canRefine, canCargo, canFuel int32) int32 {
    \tif atBase != 0 && cargo > 0 {
    \t\treturn 2 // unload into the forge
    \t}
    \tif atBase != 0 { // empty at base: climb the tech ladder
    \t\tif canRefine != 0 {
    \t\t\treturn 20 // faster refining
    \t\t}
    \t\tif canCargo != 0 {
    \t\t\treturn 21 // bigger cargo
    \t\t}
    \t\tif canFuel != 0 {
    \t\t\treturn 22 // more fuel budget
    \t\t}
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

  def template(:zig) do
    """
    // Harvester + forge in Zig, compiled single-file to wasm32-freestanding
    // (no std, no imports). `export fn decide` gives it the C ABI the sim wants;
    // return an intent code.
    export fn decide(
        cargo: i32,
        cargo_max: i32,
        at_base: i32,
        on_resource: i32,
        res_dx: i32,
        res_dy: i32,
        base_dx: i32,
        base_dy: i32,
        tick: i32,
        base_ore: i32,
        base_goods: i32,
        can_refine: i32,
        can_cargo: i32,
        can_fuel: i32,
    ) i32 {
        _ = res_dx;
        _ = res_dy;
        _ = base_dx;
        _ = base_dy;
        _ = tick;
        _ = base_ore;
        _ = base_goods;
        if (at_base != 0 and cargo > 0) return 2; // unload into the forge
        if (at_base != 0) { // empty at base: climb the tech ladder
            if (can_refine != 0) return 20; // faster refining
            if (can_cargo != 0) return 21; // bigger cargo
            if (can_fuel != 0) return 22; // more fuel budget
        }
        if (cargo >= cargo_max) return 3; // head to base
        if (on_resource != 0) return 1; // harvest
        return 4; // seek nearest ore
    }
    """
  end

  def template(:c) do
    """
    // Harvester + forge in C, compiled single-file to wasm32 with no libc and
    // no imports. `decide` is exported by the linker; return an intent code.
    int decide(
        int cargo, int cargo_max, int at_base, int on_resource,
        int res_dx, int res_dy, int base_dx, int base_dy, int tick,
        int base_ore, int base_goods, int can_refine, int can_cargo, int can_fuel
    ) {
      if (at_base && cargo > 0) return 2; // unload into the forge
      if (at_base) {                      // empty at base: climb the tech ladder
        if (can_refine) return 20;        //   faster refining
        if (can_cargo)  return 21;        //   bigger cargo
        if (can_fuel)   return 22;        //   more fuel budget
      }
      if (cargo >= cargo_max) return 3;   // head to base
      if (on_resource)        return 1;   // harvest
      return 4;                           // seek nearest ore
    }
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

          # `wasm-unknown`: a freestanding target with NO host imports (no WASI,
          # no JS runtime) — required because the sim instantiates modules with
          # an empty import set. `-scheduler=none -gc=leaking` keep a pure
          # `//export decide` function from pulling in runtime imports.
          run(
            bin,
            [
              "build",
              "-o",
              out_file,
              "-target=wasm-unknown",
              "-scheduler=none",
              "-gc=leaking",
              "-no-debug",
              in_file
            ],
            out_file
          )
        end)
    end
  end

  defp compile_zig(source) do
    case System.find_executable("zig") do
      nil ->
        {:error, "Zig toolchain not found. #{install_hint(:zig)}"}

      bin ->
        with_tempdir(fn dir ->
          in_file = Path.join(dir, "bot.zig")
          out_file = Path.join(dir, "bot.wasm")
          File.write!(in_file, source)

          # `wasm32-freestanding` + `-fno-entry`: a library with NO host imports
          # (no WASI, no `_start`) — the sim instantiates with an empty import
          # set. `-rdynamic` keeps the `export fn decide` symbol from being
          # stripped. Caches go in the throwaway dir so nothing leaks to cwd.
          run(
            bin,
            [
              "build-exe",
              in_file,
              "-target",
              "wasm32-freestanding",
              "-O",
              "ReleaseSmall",
              "-fno-entry",
              "-rdynamic",
              "-femit-bin=" <> out_file,
              "--cache-dir",
              Path.join(dir, "zig-cache"),
              "--global-cache-dir",
              Path.join(dir, "zig-global-cache")
            ],
            out_file
          )
        end)
    end
  end

  defp compile_c(source) do
    # Need a wasm-capable clang AND the wasm linker — Apple's stock clang has
    # neither the wasm32 backend nor wasm-ld, so guard on both before trying.
    if is_nil(clang_bin()) or is_nil(wasm_ld_bin()) do
      {:error, "C toolchain not found (need an LLVM clang + wasm-ld). #{install_hint(:c)}"}
    else
      bin = clang_bin()

      with_tempdir(fn dir ->
        in_file = Path.join(dir, "bot.c")
        out_file = Path.join(dir, "bot.wasm")
        File.write!(in_file, source)

        # Freestanding wasm: `-nostdlib -Wl,--no-entry` (no libc, no `_start`)
        # and `-Wl,--export=decide` to keep + export the one function. Pure
        # arithmetic means the module has zero imports, as the sim requires.
        run(
          bin,
          [
            "--target=wasm32",
            "-O3",
            "-nostdlib",
            "-Wl,--no-entry",
            "-Wl,--export=decide",
            "-o",
            out_file,
            in_file
          ],
          out_file
        )
      end)
    end
  end

  # --- shared compile machinery ---

  # Run a compiler with a hard timeout; on success read the wasm output.
  defp run(bin, args, out_file) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        if File.exists?(out_file),
          do: {:ok, File.read!(out_file)},
          else: {:error, "compiler produced no output"}

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

  # Prefer a Homebrew LLVM clang (wasm-capable, ships its own wasm-ld) over the
  # PATH clang, which on macOS is Apple's and can't link wasm. On the Linux
  # builder the Homebrew paths don't exist, so it falls through to PATH clang.
  @brew_llvm_bin ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]

  defp clang_bin do
    Enum.find_value(@brew_llvm_bin, fn dir ->
      path = Path.join(dir, "clang")
      if File.exists?(path), do: path
    end) || System.find_executable("clang")
  end

  defp wasm_ld_bin do
    Enum.find_value(@brew_llvm_bin, fn dir ->
      path = Path.join(dir, "wasm-ld")
      if File.exists?(path), do: path
    end) || System.find_executable("wasm-ld")
  end

  defp priv_dir do
    case :code.priv_dir(:convoy) do
      {:error, _} -> Path.join(File.cwd!(), "priv")
      dir -> to_string(dir)
    end
  end
end
