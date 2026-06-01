// A Memory-using strategist for Forge & Convoy, in AssemblyScript.
//   mix convoy.run examples/strategist.ts --watch
//
// Same idea as strategist.rs, in the JS/TS-flavoured language. It keeps
// persistent scratch state in LINEAR memory, which the engine snapshots, so the
// state survives both tick-to-tick and a freeze/thaw (primer §8).
//
// We use the raw `load`/`store` builtins over a compiler-reserved static buffer
// (`memory.data`) rather than an array: the sandbox provides ZERO host imports,
// and AssemblyScript's bounds-checked arrays (and `StaticArray`) pull in an
// `env.abort` import that would fail to instantiate. `memory.data(n)` hands back
// a safe, zero-initialized address in the data segment (no allocation, no
// abort), and raw load/store are plain wasm memory ops with no imports. (A
// module-level `let` would become a wasm *global* — persists live but is NOT
// snapshotted — so write to linear memory.)
//
// Strategy: compound refine early, then ship convoys on a cooldown so they
// don't bunch up at the market and get ambushed (PvP capture takes any convoy
// sharing a cell with an enemy).
//
// Intent codes: 1 harvest · 2 unload · 3 to_base · 4 to_resource · 20/21/22
// build refine/cargo/fuel · 30 launch a convoy to market · else idle.

// 64 bytes of persistent scratch in linear memory. Offset 0 holds one i32:
// the tick we last launched a convoy.
const LAST_LAUNCH: usize = memory.data(64);

const WARMUP: i32 = 80;
const SHIP_COOLDOWN: i32 = 12;

export function decide(
  cargo: i32, cargoMax: i32, atBase: i32, onResource: i32,
  resDx: i32, resDy: i32, baseDx: i32, baseDy: i32, tick: i32,
  baseOre: i32, baseGoods: i32, canRefine: i32, canCargo: i32, canFuel: i32,
  canLaunch: i32
): i32 {
  if (atBase && cargo > 0) return 2; // unload into the forge
  if (atBase) {
    if (tick < WARMUP && canRefine) return 20; // compound refine early
    // Ship on a cooldown; the value at LAST_LAUNCH (our Memory) is when we
    // last launched.
    if (canLaunch && tick - load<i32>(LAST_LAUNCH) >= SHIP_COOLDOWN) {
      store<i32>(LAST_LAUNCH, tick);
      return 30;
    }
    if (canCargo) return 21; // else scale the operation
    if (canFuel)  return 22;
  }
  if (cargo >= cargoMax) return 3; // head to base
  if (onResource)        return 1; // harvest
  return 4;                        // seek nearest ore
}
