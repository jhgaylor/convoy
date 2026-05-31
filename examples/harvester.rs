// The classic harvester, in Rust. Compiled single-file to wasm32.
//   mix convoy.run examples/harvester.rs --watch
//
// Export `decide`; return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource · 5 wander
//   10/11/12/13 move +x/-x/+y/-y · anything else idle
#![no_std]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

#[no_mangle]
pub extern "C" fn decide(
    cargo: i32,
    cargo_max: i32,
    at_base: i32,
    on_resource: i32,
    _res_dx: i32,
    _res_dy: i32,
    _base_dx: i32,
    _base_dy: i32,
    _tick: i32,
) -> i32 {
    if at_base != 0 && cargo > 0 {
        return 2; // unload
    }
    if cargo >= cargo_max {
        return 3; // head to base
    }
    if on_resource != 0 {
        return 1; // harvest
    }
    4 // seek nearest ore
}
