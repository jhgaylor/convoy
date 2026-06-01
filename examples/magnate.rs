// Forge & Convoy v2 — the Magnate: build the biggest economy the rules allow,
// then raid the market with the surplus. A fusion of the builder (throughput)
// and the raider (PvP), tuned against the real engine limits.
//
// What actually caps a colony's economy (from the sim, not guesswork):
//   - POP CAP IS 4. You can't build spawners and there are no upgrades, so the
//     fleet maxes at 4 harvesters. That's the hard mining ceiling.
//   - Refinery throughput = base(1) + 2 per finished refinery. One refinery
//     already out-paces steady ore; extra refineries only help DRAIN the early
//     240-ore burst faster (more goods sooner = more early convoys).
//   - Sustained ore is replenish-capped (~2.2/tick) — BUT only if harvesters can
//     deliver that fast. Haul distance is the real binding constraint: a fleet
//     dropping ore at a far spawner clears far less than 2.2/tick. So the biggest
//     lever we control is PLACEMENT — put refineries ON the ore so trips are ~0.
//
// The plan:
//   1. Rush ONE refinery, placed on the deposit nearest the spawner (harvesters
//      spawn at (0,0), so the first drop-off should be close + on ore).
//   2. Fill the 4-harvester cap.
//   3. Each harvester hauls to its NEAREST built building (not one fixed drop),
//      so spread-out refineries each shorten the trips around them.
//   4. While ore is piling (supply > throughput), add up to 2 more refineries,
//      each placed on the nearest still-uncovered deposit — drains the burst and
//      spreads drop-offs across the field.
//   5. Launch every spare 20 goods. Convoys are both the score AND the hunters.
//   6. Raid: steer our convoys with a forward, DIAGONAL predicted-cell intercept
//      (same as raider.rs) — escort-safe, passive-lethal — so they rob rivals on
//      the way to the sell point.
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

fn rd_u8(i: usize) -> u32 {
    unsafe { *addr_of!(IN[i]) as u32 }
}
fn rd_u16(i: usize) -> u32 {
    rd_u8(i) | (rd_u8(i + 1) << 8)
}
fn rd_u32(i: usize) -> u32 {
    rd_u16(i) | (rd_u16(i + 2) << 16)
}

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
const OP_HUNT: u32 = 9; // target=our convoy id — raider: a=dx b=dy steer

const UNIT_HARVESTER: u32 = 0;
const BLD_REFINERY: u32 = 1;
const PROGRESS_DONE: u32 = 255;

// Engine limits we play to (from world.ex / sim.ex).
const POP_CAP: usize = 4; // spawner is level-locked → fleet maxes at 4
const MAX_REFINERIES: u32 = 3; // throughput past ~2 only helps the early burst
const REFINERY_COST: u32 = 40;
const SHIPMENT_SIZE: u32 = 20;
const BASE_SHIPMENT: u32 = 30; // a fresh convoy's cargo (host shipment_value)

// View header offsets.
const H_WIDTH: usize = 4;
const H_HEIGHT: usize = 6;
const H_ORE: usize = 8;
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
const MKT_SZ: usize = 10; // id:u32, owner:u8, x:u8, y:u8, cargo:u16

#[no_mangle]
pub extern "C" fn tick(_view_len: i32) -> i32 {
    let mut out = Out { n: 0 };
    colony_logic(&mut out);
    out.n as i32
}

// Greedy unit step toward (tx,ty): close x first, then y. Matches World.step_toward.
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
    let ore = rd_u32(H_ORE);

    let units = ARRAYS;
    let bld = units + n_units * UNIT_SZ;
    let dep = bld + n_bld * BLD_SZ;
    let mkt = dep + n_dep * DEP_SZ;

    // Scan buildings once: finished-refinery count, any refinery still building,
    // and the spawner cell (always finished, our fallback drop + build anchor).
    let mut refineries: u32 = 0;
    let mut refinery_building = false;
    let mut spawner_x: u32 = 0;
    let mut spawner_y: u32 = 0;
    for b in 0..n_bld {
        let o = bld + b * BLD_SZ;
        let kind = rd_u8(o + 4);
        let prog = rd_u8(o + 8);
        if kind == 0 {
            spawner_x = rd_u8(o + 5);
            spawner_y = rd_u8(o + 6);
        }
        if kind == BLD_REFINERY {
            if prog >= PROGRESS_DONE {
                refineries += 1;
            } else {
                refinery_building = true;
            }
        }
    }

    // --- harvesters: full → haul to NEAREST built building; else mine nearest ore.
    // Hauling to the nearest drop-off (not one fixed building) is what makes
    // spread-out refineries pay off — each shortens the trips in its neighborhood.
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

        if cargo >= cargo_max {
            // nearest finished building
            let mut bd = u32::MAX;
            let mut bx = 0;
            let mut by = 0;
            let mut bid = 0;
            let mut have = false;
            for b in 0..n_bld {
                let ob = bld + b * BLD_SZ;
                if rd_u8(ob + 8) < PROGRESS_DONE {
                    continue; // skip buildings still under construction
                }
                let x2 = rd_u8(ob + 5);
                let y2 = rd_u8(ob + 6);
                let d = manhattan(ux, uy, x2, y2);
                if d < bd {
                    bd = d;
                    bx = x2;
                    by = y2;
                    bid = rd_u32(ob);
                    have = true;
                }
            }
            if have {
                if manhattan(ux, uy, bx, by) <= 1 {
                    out.push(OP_TRANSFER, id, bid as i32, 0);
                } else {
                    let (dx, dy) = step_toward(ux, uy, bx, by);
                    out.push(OP_MOVE, id, dx, dy);
                }
                continue;
            }
        }

        // mine nearest deposit with ore
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
            out.push(OP_HARVEST, id, 0, 0); // no ore in sight — idle in place
        }
    }

    // --- raid: forward, DIAGONAL predicted-cell intercept (see raider.rs). Aim at
    // a rival's vacated cell so a defending escort is dodged, not walked into; the
    // diagonal steer (a hunt move applies sign(dx) AND sign(dy)) lets a convoy cut
    // off the lane and actually land the seize instead of trailing on one axis.
    let market_x = rd_u16(H_WIDTH).saturating_sub(1);
    let market_y = rd_u16(H_HEIGHT).saturating_sub(1);
    for c in 0..n_mkt {
        let o = mkt + c * MKT_SZ;
        if rd_u8(o + 4) != 0 {
            continue; // steer only our own convoys
        }
        let id = rd_u32(o);
        let cx = rd_u8(o + 5);
        let cy = rd_u8(o + 6);
        let cargo = rd_u16(o + 7);

        if cargo > BASE_SHIPMENT {
            continue; // carrying plunder → ride home and sell, don't re-gamble it
        }

        let my_dist = manhattan(cx, cy, market_x, market_y);
        let mut best = u32::MAX;
        let mut aim_x = 0;
        let mut aim_y = 0;
        let mut found = false;
        for e in 0..n_mkt {
            let p = mkt + e * MKT_SZ;
            if rd_u8(p + 4) != 1 {
                continue; // rivals only
            }
            let rx = rd_u8(p + 5);
            let ry = rd_u8(p + 6);
            let (rdx, rdy) = step_toward(rx, ry, market_x, market_y);
            let px = (rx as i32 + rdx).max(0) as u32;
            let py = (ry as i32 + rdy).max(0) as u32;
            if manhattan(px, py, market_x, market_y) > my_dist {
                continue; // forward intercepts only — a whiff still drifts us to the sale
            }
            let d = manhattan(cx, cy, px, py);
            if d < best {
                best = d;
                aim_x = px;
                aim_y = py;
                found = true;
            }
        }
        if found {
            let dx = (aim_x as i32 - cx as i32).signum();
            let dy = (aim_y as i32 - cy as i32).signum();
            if dx != 0 || dy != 0 {
                out.push(OP_HUNT, id, dx, dy);
            }
        }
    }

    // --- economy ladder. Emission order = funding priority (the sim spends goods
    // in command order and rejects what it can't afford).
    if refineries == 0 {
        // Rush the first refinery onto the deposit nearest the spawner: harvesters
        // start at (0,0), so the first drop-off wants to be close AND on the ore.
        if !refinery_building && goods >= REFINERY_COST {
            let (px, py) = pick_refinery_cell(bld, n_bld, dep, n_dep, spawner_x, spawner_y, refineries);
            out.push(OP_BUILD, 0, BLD_REFINERY as i32, ((px << 8) | py) as i32);
        }
        return; // no spawning/launching until the forge is multiplied
    }

    // Fill the harvester cap (cheap, lifts ore delivery). n_units is live-only, so
    // an over-emit while a spawn is in flight is just rejected by the pop cap.
    if n_units < POP_CAP && goods >= 20 {
        out.push(OP_SPAWN, 0, UNIT_HARVESTER as i32, 0);
    }

    // Add refineries only while ore is genuinely piling (supply outruns the current
    // throughput) — that's the early burst, when faster conversion = more convoys.
    if !refinery_building && refineries < MAX_REFINERIES && goods >= REFINERY_COST {
        let surplus = if refineries == 1 { 25 } else { 50 };
        if ore >= surplus {
            let (px, py) = pick_refinery_cell(bld, n_bld, dep, n_dep, spawner_x, spawner_y, refineries);
            out.push(OP_BUILD, 0, BLD_REFINERY as i32, ((px << 8) | py) as i32);
        }
    }

    // Launch every spare 20 goods — flood the board (deliveries + hunters). Emitted
    // last, so spawns/builds are funded first; the sim caps the rest by goods.
    let mut launches = goods / SHIPMENT_SIZE;
    if launches > 4 {
        launches = 4;
    }
    for _ in 0..launches {
        out.push(OP_LAUNCH, 0, 0, 0);
    }
}

// Pick a build cell for the next refinery: the deposit nearest the spawner that
// has ore and no building within distance 1 (so refineries spread across the
// field instead of stacking). Build ON the deposit → harvesters mine + transfer
// in place for ~zero haul until it depletes. Fallback: a cell beside the spawner.
fn pick_refinery_cell(
    bld: usize,
    n_bld: usize,
    dep: usize,
    n_dep: usize,
    spawner_x: u32,
    spawner_y: u32,
    refineries: u32,
) -> (u32, u32) {
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
        // reject deposits that already have a building on/next to them
        let mut blocked = false;
        for b in 0..n_bld {
            let ob = bld + b * BLD_SZ;
            if manhattan(dx, dy, rd_u8(ob + 5), rd_u8(ob + 6)) <= 1 {
                blocked = true;
                break;
            }
        }
        if blocked {
            continue;
        }
        let dist = manhattan(spawner_x, spawner_y, dx, dy);
        if dist < best {
            best = dist;
            bx = dx;
            by = dy;
            found = true;
        }
    }
    if found {
        (bx, by)
    } else {
        // no free deposit — drop it beside the spawner (offset by count so each is
        // a distinct, in-grid cell).
        (spawner_x + 1 + refineries, spawner_y)
    }
}
