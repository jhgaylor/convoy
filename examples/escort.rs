// Forge & Convoy v2 — the Escort: the answer to the Raider.
//
// The Raider runs a lean economy and steers its convoys to HUNT, predicting
// where your shipments will step and intercepting to seize their cargo. Its
// whole game is theft: it banks little of its own and wins by taking everyone
// else's. The Escort beats it on the one weakness baked into the rules.
//
// THE STANCE TRIANGLE (host PvP rule, see Market moduledoc):
//   hunt   ⊳ passive   — a raider plunders an unguarded shipment
//   defend ⊳ hunt      — an escort turns the tables, taking the raider's haul
//   defend ⊳ passive   — NO. a defender lets peaceful traffic pass.
//
// A passive shipment loses to a hunter; a DEFENDING one *beats* it. But a
// defending convoy holds its cell (it doesn't advance), so you can't just
// defend the whole way — you'd never reach the market to sell. The trick is to
// travel passive (auto-advance toward the market, emitting nothing) and flip to
// DEFEND only on the ticks a hunter is actually about to land on us:
//
//   - The host advances passive convoys greedily toward the market (x first,
//     then y), so a raider predicts our next cell and steers a hunter onto it.
//   - Each tick we compute OUR next cell and, if any rival convoy can reach it
//     (or our current cell) this step, we DEFEND instead of advancing. We hold,
//     the hunter lands on an empty cell — and if it lands on US, defend beats
//     hunt and we seize ITS cargo (often fat with everyone else's stolen goods).
//   - When no hunter is in striking range we emit nothing and sail on to sell.
//
// Net effect: a hunter can delay an escorted convoy by a tick or two but can
// never take it, and a committed hunter just leapfrogs ahead of us to the market
// while we follow it in. So the Raider's offense is neutralised — and since the
// Escort also runs a real shipping economy (fill the harvester fleet, one
// refinery, then launch every surplus), it simply out-banks a bot that lives on
// theft once the theft stops working.
//
// Only `colony_logic` is the player's part; everything above it is fixed glue.
#![no_std]

use core::ptr::{addr_of, addr_of_mut};

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

// ---------------------------------------------------------------------------
// ENGINE GLUE — do not edit. The host writes the world view into IN, calls
// tick(view_len), then reads `count` 16-byte command records out of OUT.
// Zero host imports: the host learns the buffer addresses from inbuf()/outbuf().
// ---------------------------------------------------------------------------

static mut IN: [u8; 16384] = [0; 16384];
static mut OUT: [u8; 8192] = [0; 8192];

#[no_mangle]
pub extern "C" fn inbuf() -> *mut u8 {
    addr_of_mut!(IN) as *mut u8
}

#[no_mangle]
pub extern "C" fn outbuf() -> *mut u8 {
    addr_of_mut!(OUT) as *mut u8
}

// Little-endian readers over the view buffer (addr_of! → no &static refs).
fn rd_u8(i: usize) -> u32 {
    unsafe { *addr_of!(IN[i]) as u32 }
}
fn rd_u16(i: usize) -> u32 {
    rd_u8(i) | (rd_u8(i + 1) << 8)
}
fn rd_u32(i: usize) -> u32 {
    rd_u16(i) | (rd_u16(i + 2) << 16)
}

// A command writer with a running cursor. Each record is 16 bytes:
//   op:u8, _pad:u8, _pad:u16, target:u32, a:i32, b:i32   (all little-endian)
struct Out {
    n: usize,
}
impl Out {
    fn wr_u32(&self, off: usize, v: u32) {
        unsafe {
            *addr_of_mut!(OUT[off]) = (v & 0xff) as u8;
            *addr_of_mut!(OUT[off + 1]) = ((v >> 8) & 0xff) as u8;
            *addr_of_mut!(OUT[off + 2]) = ((v >> 16) & 0xff) as u8;
            *addr_of_mut!(OUT[off + 3]) = ((v >> 24) & 0xff) as u8;
        }
    }
    fn push(&mut self, op: u32, target: u32, a: i32, b: i32) {
        let base = self.n * 16;
        if base + 16 > 8192 {
            return; // out buffer full; host also caps via fuel + command cap
        }
        self.wr_u32(base, op & 0xff);
        self.wr_u32(base + 4, target);
        self.wr_u32(base + 8, a as u32);
        self.wr_u32(base + 12, b as u32);
        self.n += 1;
    }
}

// Command ops + entity kinds (kept in sync with the host).
const OP_HARVEST: u32 = 1;
const OP_MOVE: u32 = 2; // a=dx, b=dy
const OP_TRANSFER: u32 = 3; // a=destination building id
const OP_BUILD: u32 = 4; // a=building kind, b=(x<<8 | y)
const OP_SPAWN: u32 = 5; // a=unit kind
const OP_LAUNCH: u32 = 7; // load a convoy and run it to the market for credits
const OP_DEFEND: u32 = 8; // target=our convoy id — escort: hold cell, seize a hunter

const UNIT_HARVESTER: u32 = 0;
const BLD_SPAWNER: u32 = 0;
const BLD_REFINERY: u32 = 1;
const PROGRESS_DONE: u32 = 255;

// Default spawner pop cap (pop_cap_base in the host config). The engine doesn't
// implement spawner upgrades yet, so the cap is fixed; over-spawning is a no-op
// host-side anyway, so this only avoids wasting command slots.
const POP_CAP: usize = 4;

// View header offsets (tick is at 0; this bot doesn't read it).
const H_WIDTH: usize = 4;
const H_HEIGHT: usize = 6;
const H_GOODS: usize = 12;
const H_N_UNITS: usize = 20;
const H_N_BUILDINGS: usize = 22;
const H_N_DEPOSITS: usize = 24;
const H_N_MARKET: usize = 26;
const ARRAYS: usize = 28;

// Record strides.
const UNIT_SZ: usize = 12; // id:u32, kind:u8, x:u8, y:u8, cargo:u16, cargo_max:u16
const BLD_SZ: usize = 10; // id:u32, kind:u8, x:u8, y:u8, level:u8, progress:u8
const DEP_SZ: usize = 4; // x:u8, y:u8, amount:u16
const MKT_SZ: usize = 10; // id:u32, owner:u8, x:u8, y:u8, cargo:u16  (owner 0=ours,1=rival)

#[no_mangle]
pub extern "C" fn tick(_view_len: i32) -> i32 {
    let mut out = Out { n: 0 };
    colony_logic(&mut out);
    out.n as i32
}

// Greedy unit step toward (tx,ty): close x first, then y. Matches the host's
// World.step_toward, so movement is identical regardless of language.
fn step_toward(x: u32, y: u32, tx: u32, ty: u32) -> (i32, i32) {
    if x < tx {
        (1, 0)
    } else if x > tx {
        (-1, 0)
    } else if y < ty {
        (0, 1)
    } else if y > ty {
        (0, -1)
    } else {
        (0, 0)
    }
}

fn manhattan(x: u32, y: u32, tx: u32, ty: u32) -> u32 {
    let dx = if x > tx { x - tx } else { tx - x };
    let dy = if y > ty { y - ty } else { ty - y };
    dx + dy
}

// ---------------------------------------------------------------------------
// YOUR COLONY LOGIC — this is the part a player writes.
// ---------------------------------------------------------------------------
fn colony_logic(out: &mut Out) {
    let n_units = rd_u16(H_N_UNITS) as usize;
    let n_bld = rd_u16(H_N_BUILDINGS) as usize;
    let n_dep = rd_u16(H_N_DEPOSITS) as usize;
    let n_mkt = rd_u16(H_N_MARKET) as usize;
    let goods = rd_u32(H_GOODS);

    let units = ARRAYS;
    let bld = units + n_units * UNIT_SZ;
    let dep = bld + n_bld * BLD_SZ;
    let mkt = dep + n_dep * DEP_SZ;

    // Find a drop-off building: a finished refinery if any, else the spawner.
    let mut drop_id: u32 = 0;
    let mut drop_x: u32 = 0;
    let mut drop_y: u32 = 0;
    let mut have_drop = false;
    let mut refineries = 0;
    let mut refinery_building = false;
    let mut spawner_x = 0;
    let mut spawner_y = 0;
    for b in 0..n_bld {
        let o = bld + b * BLD_SZ;
        let id = rd_u32(o);
        let kind = rd_u8(o + 4);
        let bx = rd_u8(o + 5);
        let by = rd_u8(o + 6);
        let prog = rd_u8(o + 8);
        if kind == BLD_SPAWNER {
            spawner_x = bx;
            spawner_y = by;
            if !have_drop {
                drop_id = id;
                drop_x = bx;
                drop_y = by;
                have_drop = true;
            }
        }
        if kind == BLD_REFINERY {
            if prog >= PROGRESS_DONE {
                refineries += 1;
                drop_id = id;
                drop_x = bx;
                drop_y = by;
                have_drop = true;
            } else {
                refinery_building = true;
            }
        }
    }

    // Per-unit orders: full → haul to drop-off; otherwise mine the nearest ore.
    for u in 0..n_units {
        let o = units + u * UNIT_SZ;
        let id = rd_u32(o);
        let kind = rd_u8(o + 4);
        let ux = rd_u8(o + 5);
        let uy = rd_u8(o + 6);
        let cargo = rd_u16(o + 7);
        let cargo_max = rd_u16(o + 9);
        if kind != UNIT_HARVESTER {
            continue;
        }

        if cargo >= cargo_max && have_drop {
            if manhattan(ux, uy, drop_x, drop_y) <= 1 {
                out.push(OP_TRANSFER, id, drop_id as i32, 0);
            } else {
                let (dx, dy) = step_toward(ux, uy, drop_x, drop_y);
                out.push(OP_MOVE, id, dx, dy);
            }
            continue;
        }

        let mut best = u32::MAX;
        let mut bx = 0;
        let mut by = 0;
        let mut found = false;
        for d in 0..n_dep {
            let p = dep + d * DEP_SZ;
            let dx = rd_u8(p);
            let dy = rd_u8(p + 1);
            let amt = rd_u16(p + 2);
            if amt == 0 {
                continue;
            }
            let dist = manhattan(ux, uy, dx, dy);
            if dist < best {
                best = dist;
                bx = dx;
                by = dy;
                found = true;
            }
        }
        if found {
            if ux == bx && uy == by {
                out.push(OP_HARVEST, id, 0, 0);
            } else {
                let (dx, dy) = step_toward(ux, uy, bx, by);
                out.push(OP_MOVE, id, dx, dy);
            }
        } else {
            out.push(OP_HARVEST, id, 0, 0);
        }
    }

    // THE ESCORT: protect our own shipments. The market array carries every
    // convoy in transit with an owner flag (0 = ours, 1 = a rival). We let our
    // convoys auto-advance to the market (emit nothing) UNLESS a rival can land
    // on the cell we're about to move into (or the one we're on) this tick — then
    // we DEFEND. Holding + the defend stance dodges the predicted-cell intercept,
    // and if the hunter lands on us, defend ⊳ hunt: we take its cargo instead.
    let market_x = rd_u16(H_WIDTH).saturating_sub(1);
    let market_y = rd_u16(H_HEIGHT).saturating_sub(1);
    for c in 0..n_mkt {
        let o = mkt + c * MKT_SZ;
        if rd_u8(o + 4) != 0 {
            continue; // only steer our own convoys
        }
        let id = rd_u32(o);
        let cx = rd_u8(o + 5);
        let cy = rd_u8(o + 6);

        // the cell we'd auto-advance into next (greedy step toward the market)
        let (ndx, ndy) = step_toward(cx, cy, market_x, market_y);
        let nx = (cx as i32 + ndx).max(0) as u32;
        let ny = (cy as i32 + ndy).max(0) as u32;

        // can any rival reach our current or next cell this tick? (a greedy step
        // covers one cell, so "within manhattan 1" = "can land on it now")
        let mut threatened = false;
        for e in 0..n_mkt {
            let p = mkt + e * MKT_SZ;
            if rd_u8(p + 4) != 1 {
                continue; // rivals only
            }
            let rx = rd_u8(p + 5);
            let ry = rd_u8(p + 6);
            if manhattan(rx, ry, nx, ny) <= 1 || manhattan(rx, ry, cx, cy) <= 1 {
                threatened = true;
                break;
            }
        }

        if threatened {
            // hold this cell in the defend stance: immune to hunt, and a hunter
            // that lands here forfeits its cargo to us.
            out.push(OP_DEFEND, id, 0, 0);
        }
        // else: emit nothing — the convoy advances toward the market and sells.
    }

    // Economy: a real shipping engine, not a lean raider's. Grow the harvester
    // fleet early — the 20-39 goods band before a refinery exists is otherwise
    // idle (can't build one, can't ship yet), so we spend it on miners — then
    // stand up one refinery and launch every surplus. Each delivered convoy banks
    // credits the Raider can no longer steal; with raids neutralised, raw
    // throughput decides the game, so we out-ship a bot that lives on theft.
    if goods >= 40 && refineries < 1 && !refinery_building {
        let (px, py) = (spawner_x + 1, spawner_y);
        out.push(OP_BUILD, 0, BLD_REFINERY as i32, ((px << 8) | py) as i32);
    } else if refineries >= 1 && goods >= 20 {
        out.push(OP_LAUNCH, 0, 0, 0);
    } else if goods >= 20 && n_units < POP_CAP {
        out.push(OP_SPAWN, 0, UNIT_HARVESTER as i32, 0);
    }
}
