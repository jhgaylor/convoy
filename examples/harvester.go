// The classic harvester, in Go (compiled with TinyGo).
//   mix convoy.run examples/harvester.go --watch
//
// Built for the freestanding `wasm-unknown` target (no WASI, no JS host) so the
// module has zero imports, which is what the sim requires. Export `decide`;
// return an intent code:
//   1 harvest · 2 unload · 3 to_base · 4 to_resource (nearest) · 5 wander
//   6 to_far_resource (farthest from base) · 10/11/12/13 move ±x/±y · else idle
package main

//export decide
func decide(cargo, cargoMax, atBase, onResource, resDx, resDy, baseDx, baseDy, tick int32) int32 {
	if atBase != 0 && cargo > 0 {
		return 2 // unload
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
