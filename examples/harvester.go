// The classic harvester + forge, in Go (compiled with TinyGo).
//   mix convoy.run examples/harvester.go --watch
//
// Built for the freestanding `wasm-unknown` target (no WASI, no JS host) so the
// module has zero imports, which is what the sim requires. Export `decide`;
// return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource (nearest) · 5 wander
//   10/11/12/13 move ±x/±y · 20/21/22 build refine/cargo/fuel
//   30 launch a convoy to market · else idle
package main

//export decide
func decide(cargo, cargoMax, atBase, onResource, resDx, resDy, baseDx, baseDy, tick,
	baseOre, baseGoods, canRefine, canCargo, canFuel, canLaunch int32) int32 {
	if atBase != 0 && cargo > 0 {
		return 2 // unload into the forge
	}
	if atBase != 0 { // empty-handed at base
		if canLaunch != 0 {
			return 30 // ship a convoy to market for credits
		}
		if canRefine != 0 {
			return 20 // else climb the tech ladder: faster refining
		}
		if canCargo != 0 {
			return 21 // bigger cargo
		}
		if canFuel != 0 {
			return 22 // more fuel budget
		}
	}
	if cargo >= cargoMax {
		return 3 // head to base
	}
	if onResource != 0 {
		return 1 // harvest
	}
	return 4 // seek nearest ore
}

// TinyGo needs a main, even though the sim only ever calls `decide`.
func main() {}
