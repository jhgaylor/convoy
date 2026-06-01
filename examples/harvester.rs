// A harvester + forge that clears the FARTHEST deposit first, in Rust.
//   mix convoy.run examples/harvester.rs --watch
//
// Export `decide`; return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource (nearest) · 5 wander
//   6 to_far_resource (farthest from base) · 10/11/12/13 move ±x/±y
//   20/21/22 build refine/cargo/fuel · 30 launch a convoy to market · else idle
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
    _base_ore: i32,
    _base_goods: i32,
    can_refine: i32,
    can_cargo: i32,
    can_fuel: i32,
    can_launch: i32,
) -> i32 {
    if at_base != 0 && cargo > 0 {
        return 2; // unload into the forge
    }
    if at_base != 0 {
        // Empty-handed at base: ship goods to market, else climb the tech ladder.
        if can_launch != 0 { return 30; } // load a convoy bound for market (credits)
        if can_refine != 0 { return 20; } // faster refining
        if can_cargo != 0  { return 21; } // bigger cargo
        if can_fuel != 0   { return 22; } // more fuel budget
    }
    if cargo >= cargo_max {
        return 3; // head to base
    }
    if on_resource != 0 {
        return 1; // harvest
    }
    6 // seek the deposit FARTHEST from base first, then work back inward
}
