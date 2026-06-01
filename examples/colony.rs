// Forge & Convoy v2 — the simplest colony brain.
//
// This is the Phase 0 ergonomics test for the colony ABI (see
// docs/colony-v2-design.md). It is one self-contained file because the hosted
// compiler runs single-file `rustc` with no cargo and no dependencies — so the
// "SDK" ships as the boilerplate block below, not as a crate. A player edits
// only `colony_logic`; everything above it is the fixed engine glue.
//
// What this bot does: keep harvesters mining and hauling ore to a refinery (or
// the spawner if no refinery exists yet), build a second refinery once it can
// afford one, and spawn more harvesters while under a soft cap. That exercises
// the whole command surface: move / harvest / transfer / build / spawn.
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

const UNIT_HARVESTER: u32 = 0;
const BLD_SPAWNER: u32 = 0;
const BLD_REFINERY: u32 = 1;
const PROGRESS_DONE: u32 = 255;

// View header offsets (tick is at 0; this bot doesn't read it).
const H_GOODS: usize = 12;
const H_N_UNITS: usize = 20;
const H_N_BUILDINGS: usize = 22;
const H_N_DEPOSITS: usize = 24;
const ARRAYS: usize = 28;

// Record strides.
const UNIT_SZ: usize = 12; // id:u32, kind:u8, x:u8, y:u8, cargo:u16, cargo_max:u16
const BLD_SZ: usize = 10; // id:u32, kind:u8, x:u8, y:u8, level:u8, progress:u8
const DEP_SZ: usize = 4; // x:u8, y:u8, amount:u16

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
    let goods = rd_u32(H_GOODS);

    let units = ARRAYS;
    let bld = units + n_units * UNIT_SZ;
    let dep = bld + n_bld * BLD_SZ;

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
        // o+7 = level (unused here), o+8 = construction progress (255 = done).
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
                // Prefer a finished refinery as the drop-off.
                drop_id = id;
                drop_x = bx;
                drop_y = by;
                have_drop = true;
            } else {
                refinery_building = true;
            }
        }
    }

    // Per-unit orders: full → haul to drop-off; otherwise mine.
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

        // Find nearest deposit with ore.
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
            out.push(OP_HARVEST, id, 0, 0); // sits idle if its cell is empty
        }
    }

    // Colony-level: build a second refinery when flush, then grow the fleet.
    // Invalid placements/over-cap spawns are no-ops the sim rejects — we don't
    // have to be perfect, just intentful.
    if goods >= 40 && refineries < 2 && !refinery_building {
        // throughput first: build up to two refineries before shipping.
        let (px, py) = (spawner_x + 1, spawner_y); // sim validates the cell
        out.push(OP_BUILD, 0, BLD_REFINERY as i32, ((px << 8) | py) as i32);
    } else if refineries >= 1 && goods >= 25 {
        // once refining, ship surplus goods to the market for credits (the score).
        // Convoys auto-advance to market; collisions with rivals are PvP.
        out.push(OP_LAUNCH, 0, 0, 0);
    } else if goods >= 20 && n_units < 6 {
        out.push(OP_SPAWN, 0, UNIT_HARVESTER as i32, 0);
    }
}
