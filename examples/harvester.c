// A harvester + forge that clears the FARTHEST deposit first, in C.
//   mix convoy.run examples/harvester.c --watch
//
// Compiled single-file to wasm32 with no libc and no imports (the linker
// exports `decide` and drops the entry point), which is what the sim requires.
// Return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource (nearest) · 5 wander
//   6 to_far_resource (farthest from base) · 10/11/12/13 move ±x/±y
//   20/21/22 build refine/cargo/fuel · 30 launch a convoy to market · else idle
int decide(
    int cargo, int cargo_max, int at_base, int on_resource,
    int res_dx, int res_dy, int base_dx, int base_dy, int tick,
    int base_ore, int base_goods, int can_refine, int can_cargo, int can_fuel,
    int can_launch
) {
  if (at_base && cargo > 0) return 2; // unload into the forge
  if (at_base) {                      // empty-handed at base:
    if (can_launch) return 30;        //   ship a convoy to market for credits
    if (can_refine) return 20;        //   else climb the tech ladder: refining
    if (can_cargo)  return 21;        //   bigger cargo
    if (can_fuel)   return 22;        //   more fuel budget
  }
  if (cargo >= cargo_max) return 3;   // head to base
  if (on_resource)        return 1;   // harvest
  return 6; // seek the deposit FARTHEST from base first, then work back inward
}
