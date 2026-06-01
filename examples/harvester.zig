// A harvester that clears the FARTHEST deposit first, in Zig.
//   mix convoy.run examples/harvester.zig --watch
//
// Built for the freestanding `wasm32-freestanding` target (no WASI, no host) so
// the module has zero imports, which is what the sim requires. `export fn`
// gives `decide` the C ABI; return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource (nearest) · 5 wander
//   6 to_far_resource (farthest from base) · 10/11/12/13 move ±x/±y · else idle
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
) i32 {
    _ = res_dx;
    _ = res_dy;
    _ = base_dx;
    _ = base_dy;
    _ = tick;
    if (at_base != 0 and cargo > 0) return 2; // unload
    if (cargo >= cargo_max) return 3; // head to base
    if (on_resource != 0) return 1; // harvest
    return 6; // seek the deposit FARTHEST from base first, then work back inward
}
