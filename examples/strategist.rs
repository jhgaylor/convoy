// A Memory-using strategist for Forge & Convoy, in Rust.
//   mix convoy.run examples/strategist.rs --watch
//
// This plays the *full* game and shows off two things the basic harvester
// doesn't:
//
//   1. Persistent Memory (primer §8). It remembers, across ticks, the tick it
//      last shipped a convoy. That's kept in a `static` — which lives in the
//      module's linear memory, so it survives both tick-to-tick AND a
//      freeze/thaw (deploy, stop/resume). The ABI never tells you your own past
//      decisions, so remembering them is exactly what Memory is for.
//
//   2. Strategy. Early game it pumps refine to compound throughput; then it
//      ships convoys on a cooldown so they don't all bunch up at the market and
//      get ambushed (PvP capture takes any convoy sharing a cell with an enemy).
//
// Intent codes: 1 harvest · 2 unload · 3 to_base · 4 to_resource · 20/21/22
// build refine/cargo/fuel · 30 launch a convoy to market · else idle.
#![no_std]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

// Persistent scratch: MEM[0] = the tick we last shipped. We read/write it with
// VOLATILE accesses on purpose — under `-O` the compiler will happily promote a
// plain `static mut` into a wasm *global*, which persists live but is NOT
// snapshotted. Volatile forces real linear-memory loads/stores, so the state
// also survives a freeze/thaw (deploy, stop/resume) — primer §8.
static mut MEM: [i32; 16] = [0; 16];

const WARMUP: i32 = 80; // first 80 ticks: pump refine to compound output
const SHIP_COOLDOWN: i32 = 12; // space launches out so convoys don't pile up

#[no_mangle]
pub extern "C" fn decide(
    cargo: i32, cargo_max: i32, at_base: i32, on_resource: i32,
    _res_dx: i32, _res_dy: i32, _base_dx: i32, _base_dy: i32, tick: i32,
    _base_ore: i32, _base_goods: i32, can_refine: i32, can_cargo: i32, can_fuel: i32,
    can_launch: i32,
) -> i32 {
    if at_base != 0 && cargo > 0 {
        return 2; // unload into the forge
    }
    if at_base != 0 {
        unsafe {
            // black_box hides the address from the optimizer so it can't promote
            // MEM into a wasm global — the state stays in linear memory.
            let slot = core::hint::black_box(core::ptr::addr_of_mut!(MEM[0]));

            // Early game: compound refine throughput before we start shipping.
            if tick < WARMUP && can_refine != 0 {
                return 20;
            }
            // Ship — but only if the cooldown since our last launch has elapsed.
            // Reading our Memory (the last-launch tick) is the point of this bot.
            if can_launch != 0 && tick - core::ptr::read_volatile(slot) >= SHIP_COOLDOWN {
                core::ptr::write_volatile(slot, tick);
                return 30;
            }
            // Otherwise put surplus goods into scaling the operation.
            if can_cargo != 0 {
                return 21;
            }
            if can_fuel != 0 {
                return 22;
            }
        }
    }
    if cargo >= cargo_max {
        return 3; // head to base
    }
    if on_resource != 0 {
        return 1; // harvest
    }
    4 // seek nearest ore
}
