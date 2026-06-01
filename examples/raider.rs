// The Raider: a bot that plays for the AMBUSH, not the sale.
//   mix convoy.run examples/raider.rs --region arena --player raider
//
// It harvests and ships convoys like anyone else, but exports the optional
// `convoy` controller (see docs/writing-bots.md) and uses it to HUNT enemy
// convoys and DEFEND, seizing their shipments. Defending forfeits its own run
// to the market, so the Raider banks few credits of its own — it wins by taking
// everyone else's. A foil to delivery-optimisers; turn several loose and the
// market becomes a brawl.
//
// Two exports:
//   decide(...)  — the 15-param harvester ABI (harvest, forge, launch convoys)
//   convoy(...)  — the 9-param convoy ABI: 1 defend · 2 hunt · 0 advance
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
    _can_cargo: i32,
    _can_fuel: i32,
    can_launch: i32,
) -> i32 {
    if at_base != 0 && cargo > 0 {
        return 2; // unload into the forge
    }
    if at_base != 0 {
        // Empty at base: get convoys out on the board as fast as possible (they
        // are the hunters). Otherwise pour goods into refine so we can launch
        // again sooner. We deliberately skip cargo/fuel — raiding, not hauling.
        if can_launch != 0 { return 30; } // send another convoy to the fray
        if can_refine != 0 { return 20; } // faster refining → more convoys
    }
    if cargo >= cargo_max {
        return 3; // head to base
    }
    if on_resource != 0 {
        return 1; // harvest
    }
    4 // seek the nearest deposit (we want goods quickly, not the long route)
}

#[no_mangle]
pub extern "C" fn convoy(
    _cargo: i32,
    _market_dx: i32,
    _market_dy: i32,
    _dist_market: i32,
    _tick: i32,
    _enemy_dx: i32,
    _enemy_dy: i32,
    enemy_dist: i32,
    enemy_adjacent: i32,
) -> i32 {
    // An enemy is right next to us: hold this cell. If they step onto it we win
    // the collision and seize their shipment (the defend mechanic).
    if enemy_adjacent != 0 {
        return 1; // defend
    }
    // An enemy exists somewhere: close the distance to set up the ambush.
    if enemy_dist >= 0 {
        return 2; // hunt — step toward the nearest enemy convoy
    }
    // Nobody to rob: at least advance and bank this shipment ourselves.
    0 // advance toward market
}
