// The classic harvester + forge, in AssemblyScript. Compiled in-game with `asc`.
//   mix convoy.run examples/harvester.ts --watch
//
// Export `decide`; return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource · 5 wander
//   10/11/12/13 move +x/-x/+y/-y · 20/21/22 build refine/cargo/fuel · else idle
export function decide(
  cargo: i32, cargoMax: i32, atBase: i32, onResource: i32,
  resDx: i32, resDy: i32, baseDx: i32, baseDy: i32, tick: i32,
  baseOre: i32, baseGoods: i32, canRefine: i32, canCargo: i32, canFuel: i32
): i32 {
  if (atBase && cargo > 0) return 2; // unload into the forge
  if (atBase) {                      // empty-handed at base: climb the tech ladder
    if (canRefine) return 20;        //   faster refining
    if (canCargo)  return 21;        //   bigger cargo
    if (canFuel)   return 22;        //   more fuel budget
  }
  if (cargo >= cargoMax) return 3;   // head to base
  if (onResource)        return 1;   // harvest
  return 4;                          // seek nearest ore
}
