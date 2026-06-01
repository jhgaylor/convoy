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
  `install_hint/1` says how to get them. Every module must export the colony ABI
  (`inbuf`/`outbuf`/`tick`) defined in `Convoy.Engine.ColonyAbi`.
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

  # --- starter templates (each exports the colony ABI: inbuf/outbuf/tick) ---

  @doc """
  Starter source for a language: a minimal **colony** brain on the v2 ABI. Each
  exports `inbuf`/`outbuf`/`tick`. Harvesters mine the nearest ore and haul it to
  the spawner; the colony ships a convoy when it has goods. Extend from there —
  the full reference is `examples/colony.rs`, the wire format `colony_abi.ex`.
  """
  def template(:assemblyscript) do
    """
    // Minimal COLONY brain in AssemblyScript (the JS/TS path). Compile with
    // `asc --runtime stub`. One `tick` commands your whole colony; extend it to
    // build refineries, spawn units, and steer convoys (see examples/colony.rs).
    const IN: usize = memory.data(16384);
    const OUT: usize = memory.data(8192);
    let n: i32 = 0;

    export function inbuf(): i32 { return IN as i32; }
    export function outbuf(): i32 { return OUT as i32; }

    function r8(i: i32): i32 { return load<u8>(IN + i); }
    function r16(i: i32): i32 { return r8(i) | (r8(i + 1) << 8); }
    function r32(i: i32): i32 { return r16(i) | (r16(i + 2) << 16); }
    function ab(v: i32): i32 { return v < 0 ? -v : v; }
    function sgn(d: i32): i32 { return d < 0 ? -1 : (d > 0 ? 1 : 0); }

    function w32(o: i32, v: i32): void { for (let k = 0; k < 4; k++) store<u8>(OUT + o + k, (v >>> (8 * k)) & 0xff); }
    // command: op:u8 _pad:u8 _pad:u16 target:u32 a:i32 b:i32  (16 bytes)
    function emit(op: i32, target: i32, a: i32, b: i32): void {
      let o = n * 16; if (o + 16 > 8192) return;
      store<u8>(OUT + o, op & 0xff);
      w32(o + 4, target); w32(o + 8, a); w32(o + 12, b);
      n++;
    }
    // step toward (tx,ty): close x first, then y
    function moveToward(id: i32, x: i32, y: i32, tx: i32, ty: i32): void {
      let dx = sgn(tx - x); let dy = dx == 0 ? sgn(ty - y) : 0; emit(2, id, dx, dy);
    }

    export function tick(viewLen: i32): i32 {
      n = 0;
      let goods = r32(12);
      let nu = r16(20), nb = r16(22), nd = r16(24);
      let bld = 28 + nu * 12, dep = bld + nb * 10;

      let sid = 0, sx = 0, sy = 0; // the spawner (building kind 0) — our drop-off
      for (let b = 0; b < nb; b++) { let o = bld + b * 10; if (r8(o + 4) == 0) { sid = r32(o); sx = r8(o + 5); sy = r8(o + 6); } }

      for (let u = 0; u < nu; u++) {
        let o = 28 + u * 12; let id = r32(o); if (r8(o + 4) != 0) continue;
        let x = r8(o + 5), y = r8(o + 6), cargo = r16(o + 7), cmax = r16(o + 9);
        if (cargo >= cmax) {
          if (ab(x - sx) + ab(y - sy) <= 1) emit(3, id, sid, 0); else moveToward(id, x, y, sx, sy);
        } else {
          let best = 1 << 30, bx = 0, by = 0; let found = false;
          for (let d = 0; d < nd; d++) { let p = dep + d * 4; if (r16(p + 2) > 0) { let dx = r8(p), dy = r8(p + 1); let dist = ab(x - dx) + ab(y - dy); if (dist < best) { best = dist; bx = dx; by = dy; found = true; } } }
          if (found) { if (x == bx && y == by) emit(1, id, 0, 0); else moveToward(id, x, y, bx, by); }
        }
      }

      if (goods >= 20) emit(7, 0, 0, 0); // ship a convoy to market
      return n;
    }
    """
  end

  def template(:rust) do
    """
    // Minimal COLONY brain in Rust (no_std, single-file → wasm32). One `tick`
    // commands your whole colony: harvesters mine the nearest ore and haul it to
    // the spawner; the colony ships a convoy to the market whenever it has goods.
    // Extend it — build refineries, spawn units, steer convoys. Full reference +
    // wire format: examples/colony.rs and lib/convoy/engine/colony_abi.ex.
    #![no_std]
    use core::ptr::{addr_of, addr_of_mut};
    #[panic_handler]
    fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

    static mut IN: [u8; 16384] = [0; 16384];
    static mut OUT: [u8; 8192] = [0; 8192];
    static mut N: usize = 0;

    #[no_mangle] pub extern "C" fn inbuf() -> *mut u8 { addr_of_mut!(IN) as *mut u8 }
    #[no_mangle] pub extern "C" fn outbuf() -> *mut u8 { addr_of_mut!(OUT) as *mut u8 }

    fn r8(i: usize) -> i32 { unsafe { *addr_of!(IN[i]) as i32 } }
    fn r16(i: usize) -> i32 { r8(i) | (r8(i + 1) << 8) }
    fn r32(i: usize) -> i32 { r16(i) | (r16(i + 2) << 16) }
    fn ab(v: i32) -> i32 { if v < 0 { -v } else { v } }
    fn step(x: i32, y: i32, tx: i32, ty: i32) -> (i32, i32) {
        if x < tx { (1, 0) } else if x > tx { (-1, 0) } else if y < ty { (0, 1) } else if y > ty { (0, -1) } else { (0, 0) }
    }

    fn w32(o: usize, v: i32) { let u = v as u32; for k in 0..4 { unsafe { *addr_of_mut!(OUT[o + k]) = (u >> (8 * k)) as u8; } } }

    // command record: op:u8 _pad:u8 _pad:u16 target:u32 a:i32 b:i32  (16 bytes)
    fn emit(op: i32, target: i32, a: i32, b: i32) {
        unsafe {
            let o = N * 16;
            if o + 16 > 8192 { return; }
            *addr_of_mut!(OUT[o]) = op as u8;
            w32(o + 4, target);
            w32(o + 8, a);
            w32(o + 12, b);
            N += 1;
        }
    }

    #[no_mangle]
    pub extern "C" fn tick(_view_len: i32) -> i32 {
        unsafe { N = 0; }
        let goods = r32(12);
        let nu = r16(20) as usize;
        let nb = r16(22) as usize;
        let nd = r16(24) as usize;
        let bld = 28 + nu * 12;
        let dep = bld + nb * 10;

        // find the spawner (building kind 0) — our drop-off
        let (mut sid, mut sx, mut sy) = (0i32, 0i32, 0i32);
        for b in 0..nb { let o = bld + b * 10; if r8(o + 4) == 0 { sid = r32(o); sx = r8(o + 5); sy = r8(o + 6); } }

        for u in 0..nu {
            let o = 28 + u * 12;
            let id = r32(o);
            if r8(o + 4) != 0 { continue; } // harvesters only (kind 0)
            let (x, y, cargo, cmax) = (r8(o + 5), r8(o + 6), r16(o + 7), r16(o + 9));

            if cargo >= cmax {
                if ab(x - sx) + ab(y - sy) <= 1 { emit(3, id, sid, 0); } // transfer to spawner
                else { let (dx, dy) = step(x, y, sx, sy); emit(2, id, dx, dy); } // move toward it
            } else {
                let (mut best, mut bx, mut by, mut found) = (1 << 30, 0i32, 0i32, false);
                for d in 0..nd {
                    let p = dep + d * 4;
                    if r16(p + 2) > 0 { let (dx, dy) = (r8(p), r8(p + 1)); let dist = ab(x - dx) + ab(y - dy); if dist < best { best = dist; bx = dx; by = dy; found = true; } }
                }
                if found {
                    if x == bx && y == by { emit(1, id, 0, 0); } // harvest
                    else { let (dx, dy) = step(x, y, bx, by); emit(2, id, dx, dy); }
                }
            }
        }

        if goods >= 20 { emit(7, 0, 0, 0); } // ship a convoy to market
        unsafe { N as i32 }
    }
    """
  end

  def template(:tinygo) do
    """
    // Minimal COLONY brain in Go (TinyGo → wasm). One tick commands your colony:
    // harvesters mine the nearest ore and haul to the spawner; ship a convoy when
    // there are goods. Extend it (build/spawn/steer) — see examples/colony.rs.
    package main

    import "unsafe"

    var inBuf [16384]byte
    var outBuf [8192]byte
    var n int32

    //export inbuf
    func inbuf() int32 { return int32(uintptr(unsafe.Pointer(&inBuf[0]))) }

    //export outbuf
    func outbuf() int32 { return int32(uintptr(unsafe.Pointer(&outBuf[0]))) }

    func r8(i int32) int32  { return int32(inBuf[i]) }
    func r16(i int32) int32 { return r8(i) | (r8(i+1) << 8) }
    func r32(i int32) int32 { return r16(i) | (r16(i+2) << 16) }
    func ab(v int32) int32  { if v < 0 { return -v }; return v }
    func sgn(d int32) int32 { if d < 0 { return -1 }; if d > 0 { return 1 }; return 0 }

    func w32(o, v int32) { for k := int32(0); k < 4; k++ { outBuf[o+k] = byte((uint32(v) >> (8 * uint32(k))) & 0xff) } }
    func emit(op, target, a, b int32) {
    \to := n * 16
    \tif o+16 > 8192 { return }
    \toutBuf[o] = byte(op)
    \tw32(o+4, target); w32(o+8, a); w32(o+12, b)
    \tn++
    }
    func moveToward(id, x, y, tx, ty int32) {
    \tdx := sgn(tx - x); dy := int32(0); if dx == 0 { dy = sgn(ty - y) }; emit(2, id, dx, dy)
    }

    //export tick
    func tick(viewLen int32) int32 {
    \tn = 0
    \tgoods := r32(12)
    \tnu := r16(20); nb := r16(22); nd := r16(24)
    \tbld := 28 + nu*12; dep := bld + nb*10
    \tvar sid, sx, sy int32
    \tfor b := int32(0); b < nb; b++ { o := bld + b*10; if r8(o+4) == 0 { sid = r32(o); sx = r8(o+5); sy = r8(o+6) } }
    \tfor u := int32(0); u < nu; u++ {
    \t\to := 28 + u*12; id := r32(o); if r8(o+4) != 0 { continue }
    \t\tx := r8(o+5); y := r8(o+6); cargo := r16(o+7); cmax := r16(o+9)
    \t\tif cargo >= cmax {
    \t\t\tif ab(x-sx)+ab(y-sy) <= 1 { emit(3, id, sid, 0) } else { moveToward(id, x, y, sx, sy) }
    \t\t} else {
    \t\t\tbest := int32(1 << 30); var bx, by int32; found := false
    \t\t\tfor d := int32(0); d < nd; d++ { p := dep + d*4; if r16(p+2) > 0 { dx := r8(p); dy := r8(p+1); dist := ab(x-dx) + ab(y-dy); if dist < best { best = dist; bx = dx; by = dy; found = true } } }
    \t\t\tif found { if x == bx && y == by { emit(1, id, 0, 0) } else { moveToward(id, x, y, bx, by) } }
    \t\t}
    \t}
    \tif goods >= 20 { emit(7, 0, 0, 0) }
    \treturn n
    }

    func main() {}
    """
  end

  def template(:zig) do
    """
    // Minimal COLONY brain in Zig (wasm32-freestanding, no imports). Harvesters
    // mine the nearest ore and haul to the spawner; ship a convoy when there are
    // goods. Extend it — full reference: examples/colony.rs.
    var in_buf: [16384]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var n: i32 = 0;

    export fn inbuf() i32 { return @intCast(@intFromPtr(&in_buf)); }
    export fn outbuf() i32 { return @intCast(@intFromPtr(&out_buf)); }

    fn r8(i: usize) i32 { return @intCast(in_buf[i]); }
    fn r16(i: usize) i32 { return r8(i) | (r8(i + 1) << 8); }
    fn r32(i: usize) i32 { return r16(i) | (r16(i + 2) << 16); }
    fn ab(v: i32) i32 { return if (v < 0) -v else v; }
    fn sgn(d: i32) i32 { return if (d < 0) @as(i32, -1) else (if (d > 0) @as(i32, 1) else @as(i32, 0)); }

    fn w32(o: usize, v: i32) void {
        const u: u32 = @bitCast(v);
        var k: usize = 0;
        while (k < 4) : (k += 1) out_buf[o + k] = @truncate(u >> @as(u5, @intCast(k * 8)));
    }
    fn emit(op: i32, target: i32, a: i32, b: i32) void {
        const o: usize = @intCast(n * 16);
        if (o + 16 > 8192) return;
        out_buf[o] = @intCast(op);
        w32(o + 4, target);
        w32(o + 8, a);
        w32(o + 12, b);
        n += 1;
    }
    fn moveToward(id: i32, x: i32, y: i32, tx: i32, ty: i32) void {
        const dx = sgn(tx - x);
        const dy = if (dx == 0) sgn(ty - y) else @as(i32, 0);
        emit(2, id, dx, dy);
    }

    export fn tick(view_len: i32) i32 {
        _ = view_len;
        n = 0;
        const goods = r32(12);
        const nu: usize = @intCast(r16(20));
        const nb: usize = @intCast(r16(22));
        const nd: usize = @intCast(r16(24));
        const bld: usize = 28 + nu * 12;
        const dep: usize = bld + nb * 10;

        var sid: i32 = 0;
        var sx: i32 = 0;
        var sy: i32 = 0;
        var b: usize = 0;
        while (b < nb) : (b += 1) {
            const o = bld + b * 10;
            if (r8(o + 4) == 0) {
                sid = r32(o);
                sx = r8(o + 5);
                sy = r8(o + 6);
            }
        }

        var u: usize = 0;
        while (u < nu) : (u += 1) {
            const o = 28 + u * 12;
            const id = r32(o);
            if (r8(o + 4) != 0) continue;
            const x = r8(o + 5);
            const y = r8(o + 6);
            const cargo = r16(o + 7);
            const cmax = r16(o + 9);
            if (cargo >= cmax) {
                if (ab(x - sx) + ab(y - sy) <= 1) emit(3, id, sid, 0) else moveToward(id, x, y, sx, sy);
            } else {
                var best: i32 = 1 << 30;
                var bx: i32 = 0;
                var by: i32 = 0;
                var found = false;
                var d: usize = 0;
                while (d < nd) : (d += 1) {
                    const p = dep + d * 4;
                    if (r16(p + 2) > 0) {
                        const dx = r8(p);
                        const dy = r8(p + 1);
                        const dist = ab(x - dx) + ab(y - dy);
                        if (dist < best) {
                            best = dist;
                            bx = dx;
                            by = dy;
                            found = true;
                        }
                    }
                }
                if (found) {
                    if (x == bx and y == by) emit(1, id, 0, 0) else moveToward(id, x, y, bx, by);
                }
            }
        }

        if (goods >= 20) emit(7, 0, 0, 0);
        return n;
    }
    """
  end

  def template(:c) do
    """
    // Minimal COLONY brain in C (wasm32, no libc, no imports). The linker exports
    // inbuf/outbuf/tick. Harvesters mine the nearest ore and haul to the spawner;
    // ship a convoy when there are goods. Extend — see examples/colony.rs.
    static unsigned char in_buf[16384];
    static unsigned char out_buf[8192];
    static int n;

    int inbuf(void)  { return (int)(__UINTPTR_TYPE__)in_buf; }
    int outbuf(void) { return (int)(__UINTPTR_TYPE__)out_buf; }

    static int r8(int i)  { return in_buf[i]; }
    static int r16(int i) { return r8(i) | (r8(i + 1) << 8); }
    static int r32(int i) { return r16(i) | (r16(i + 2) << 16); }
    static int ab(int v)  { return v < 0 ? -v : v; }
    static int sgn(int d) { return d < 0 ? -1 : (d > 0 ? 1 : 0); }

    static void w32(int o, int v) { for (int k = 0; k < 4; k++) out_buf[o + k] = (unsigned char)((unsigned)v >> (8 * k)); }
    // command: op:u8 _pad:u8 _pad:u16 target:u32 a:i32 b:i32  (16 bytes)
    static void emit(int op, int target, int a, int b) {
      int o = n * 16; if (o + 16 > 8192) return;
      out_buf[o] = (unsigned char)op;
      w32(o + 4, target); w32(o + 8, a); w32(o + 12, b);
      n++;
    }
    static void move_toward(int id, int x, int y, int tx, int ty) {
      int dx = sgn(tx - x); int dy = dx == 0 ? sgn(ty - y) : 0; emit(2, id, dx, dy);
    }

    int tick(int view_len) {
      (void)view_len;
      n = 0;
      int goods = r32(12);
      int nu = r16(20), nb = r16(22), nd = r16(24);
      int bld = 28 + nu * 12, dep = bld + nb * 10;
      int sid = 0, sx = 0, sy = 0;
      for (int b = 0; b < nb; b++) { int o = bld + b * 10; if (r8(o + 4) == 0) { sid = r32(o); sx = r8(o + 5); sy = r8(o + 6); } }
      for (int u = 0; u < nu; u++) {
        int o = 28 + u * 12; int id = r32(o); if (r8(o + 4) != 0) continue;
        int x = r8(o + 5), y = r8(o + 6), cargo = r16(o + 7), cmax = r16(o + 9);
        if (cargo >= cmax) {
          if (ab(x - sx) + ab(y - sy) <= 1) emit(3, id, sid, 0); else move_toward(id, x, y, sx, sy);
        } else {
          int best = 1 << 30, bx = 0, by = 0, found = 0;
          for (int d = 0; d < nd; d++) { int p = dep + d * 4; if (r16(p + 2) > 0) { int dx = r8(p), dy = r8(p + 1); int dist = ab(x - dx) + ab(y - dy); if (dist < best) { best = dist; bx = dx; by = dy; found = 1; } } }
          if (found) { if (x == bx && y == by) emit(1, id, 0, 0); else move_toward(id, x, y, bx, by); }
        }
      }
      if (goods >= 20) emit(7, 0, 0, 0);
      return n;
    }
    """
  end

  def template(:wat) do
    """
    ;; Minimal COLONY skeleton in WebAssembly text (no toolchain — Wasmtime
    ;; compiles this directly). It reads the colony view the host writes at inbuf()
    ;; and writes a command list at outbuf(). This skeleton harvests with every
    ;; unit and ships a convoy when goods are available; add movement toward ore
    ;; to make it really mine (see examples/colony.rs for the full thing).
    ;;
    ;; Memory layout we use: IN at 1024, OUT at 40000 (both inside one 64KB page).
    ;; View is little-endian, so native i32 loads read fields directly:
    ;;   goods   = i32 at IN+12        n_units = u16 at IN+20
    ;;   units[] start at IN+28, stride 12: id:u32@0 kind:u8@4 ...
    ;; Command record (16B): op:u8@0  target:u32@4  a:i32@8  b:i32@12
    (module
      (memory (export "memory") 1)
      (global $n (mut i32) (i32.const 0))
      (func (export "inbuf") (result i32) (i32.const 1024))
      (func (export "outbuf") (result i32) (i32.const 40000))
      (func (export "tick") (param $len i32) (result i32)
        (local $i i32) (local $nu i32) (local $uo i32) (local $oo i32)
        (global.set $n (i32.const 0))
        (local.set $nu (i32.load16_u (i32.const 1044)))      ;; IN+20 = n_units
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (local.get $nu)))
            (local.set $uo (i32.add (i32.const 1052) (i32.mul (local.get $i) (i32.const 12)))) ;; IN+28 + i*12
            ;; harvesters are kind 0 (byte at uo+4)
            (if (i32.eqz (i32.load8_u (i32.add (local.get $uo) (i32.const 4))))
              (then
                (local.set $oo (i32.add (i32.const 40000) (i32.mul (global.get $n) (i32.const 16))))
                (i32.store8 (local.get $oo) (i32.const 1))                                     ;; op = harvest
                (i32.store (i32.add (local.get $oo) (i32.const 4)) (i32.load (local.get $uo))) ;; target = unit id
                (global.set $n (i32.add (global.get $n) (i32.const 1)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        ;; goods (IN+12) >= 20 -> launch a convoy
        (if (i32.ge_s (i32.load (i32.const 1036)) (i32.const 20))
          (then
            (local.set $oo (i32.add (i32.const 40000) (i32.mul (global.get $n) (i32.const 16))))
            (i32.store8 (local.get $oo) (i32.const 7))        ;; op = launch
            (global.set $n (i32.add (global.get $n) (i32.const 1)))))
        (global.get $n)))
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
          # an empty import set. `-scheduler=none -gc=leaking` keep the pure
          # `//export tick` (+ inbuf/outbuf) functions from pulling in runtime imports.
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
          # set. `-rdynamic` keeps the `export fn` symbols (inbuf/outbuf/tick)
          # from being stripped. Caches go in the throwaway dir, nothing leaks to cwd.
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
        # and export the colony ABI functions. Pure arithmetic means the module
        # has zero imports, as the sim requires.
        run(
          bin,
          [
            "--target=wasm32",
            "-O3",
            "-nostdlib",
            "-Wl,--no-entry",
            "-Wl,--export=inbuf",
            "-Wl,--export=outbuf",
            "-Wl,--export=tick",
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
