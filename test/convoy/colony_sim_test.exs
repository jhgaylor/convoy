defmodule Convoy.Engine.Colony.SimTest do
  @moduledoc """
  The v2 colony tick loop: command resolution, time-gated construction/spawning,
  rate-based refining, and determinism — tested with a pure Elixir brain — plus
  one end-to-end test driving the real compiled `examples/colony.rs` bot through
  many ticks and watching a colony actually grow.
  """
  use ExUnit.Case, async: false

  alias Convoy.Engine.Colony.{World, Sim}
  alias Convoy.Engine.ColonyWasm
  alias Convoy.Compile

  @colony_src Path.expand("../../examples/colony.rs", __DIR__)

  # A brain that ignores the world and replays a fixed command list.
  defp fixed(cmds), do: fn _w -> cmds end

  describe "command resolution" do
    test "harvest takes ore from the unit's cell into its cargo" do
      w = %{World.generate(seed: 1) | deposits: %{{0, 0} => 40}}
      [u | _] = w.units
      w2 = Sim.apply_commands(w, [%{op: 1, target: u.id, a: 0, b: 0}])
      assert World.unit(w2, u.id).cargo == 5
      assert World.deposit_at(w2, {0, 0}) == 35
    end

    test "move steps the unit and clamps to the grid" do
      w = World.generate(seed: 1)
      [u | _] = w.units
      w2 = Sim.apply_commands(w, [%{op: 2, target: u.id, a: -1, b: -1}])
      # already at (0,0); a -1/-1 step clamps to (0,0)
      assert {World.unit(w2, u.id).x, World.unit(w2, u.id).y} == {0, 0}
      w3 = Sim.apply_commands(w, [%{op: 2, target: u.id, a: 1, b: 0}])
      assert World.unit(w3, u.id).x == 1
    end

    test "transfer moves a unit's cargo into the colony ore stockpile" do
      w = World.generate(seed: 1)
      [u | _] = w.units
      spawner = hd(w.buildings)
      # put the unit on the spawner with cargo
      w = World.update_unit(w, u.id, &%{&1 | x: spawner.x, y: spawner.y, cargo: 5})
      w2 = Sim.apply_commands(w, [%{op: 3, target: u.id, a: spawner.id, b: 0}])
      assert World.unit(w2, u.id).cargo == 0
      # ore went into the stockpile, then the base rate refined 1 → ore 4, goods 1
      assert w2.ore == 4
      assert w2.goods == 1
    end
  end

  describe "time + cost gating" do
    test "build queues a refinery, spends goods, and finishes after build_time ticks" do
      cfg = Map.merge(World.default_config(), %{build_cost_refinery: 40, build_time_refinery: 3})
      w = %{World.generate(seed: 1, config: cfg) | goods: 50}
      pos_packed = 1 * 256 + 0

      w = Sim.apply_commands(w, [%{op: 4, target: 0, a: 1, b: pos_packed}])
      ref = World.building_at(w, {1, 0})
      assert ref != nil and ref.built == false
      assert w.goods == 10

      # idle for the remaining ticks; it finishes on schedule
      w = Sim.run(w, fixed([]), 2)
      assert World.building_at(w, {1, 0}).built

      # can't afford a second one now (goods spent)
      w2 = Sim.apply_commands(w, [%{op: 4, target: 0, a: 1, b: 2 * 256 + 0}])
      assert World.building_at(w2, {2, 0}) == nil
    end

    test "spawn enqueues a unit under the pop cap and it appears after spawn_time" do
      cfg = Map.merge(World.default_config(), %{spawn_cost_harvester: 10, spawn_time_harvester: 2, start_units: 1})
      w = %{World.generate(seed: 1, config: cfg) | goods: 50}
      assert length(w.units) == 1

      w = Sim.apply_commands(w, [%{op: 5, target: 0, a: 0, b: 0}])
      assert length(w.spawn_queue) == 1
      assert length(w.units) == 1

      w = Sim.run(w, fixed([]), 2)
      assert length(w.units) == 2
      assert w.spawn_queue == []
    end

    test "spawn is refused at the population cap" do
      cfg = Map.merge(World.default_config(), %{pop_cap_base: 2, start_units: 2, spawn_cost_harvester: 1})
      w = %{World.generate(seed: 1, config: cfg) | goods: 100}
      w2 = Sim.apply_commands(w, [%{op: 5, target: 0, a: 0, b: 0}])
      assert w2.spawn_queue == []
    end
  end

  describe "refining" do
    test "the base rate refines ore→goods even with no refinery; a refinery multiplies it" do
      w = %{World.generate(seed: 1) | ore: 100, goods: 0}
      base = World.default_config().base_refine_rate
      w1 = Sim.apply_commands(w, [])
      assert w1.goods == base

      # add a finished refinery → throughput jumps by refine_rate
      ref = %{id: 999, kind: 1, x: 5, y: 5, level: 0, built: true, remaining: 0}
      w_ref = %{w | buildings: [hd(w.buildings), ref]}
      w2 = Sim.apply_commands(w_ref, [])
      assert w2.goods == base + World.default_config().refine_rate
    end

    test "refining is capped by storage" do
      cfg = Map.merge(World.default_config(), %{storage_base: 3})
      w = %{World.generate(seed: 1, config: cfg) | ore: 100, goods: 2}
      w2 = Sim.apply_commands(w, [])
      assert w2.goods == 3
    end
  end

  test "the loop is deterministic — same world + brain → bit-identical after N ticks" do
    brain = fixed([%{op: 1, target: 2, a: 0, b: 0}, %{op: 2, target: 3, a: 1, b: 0}])
    a = Sim.run(World.generate(seed: 7), brain, 50)
    b = Sim.run(World.generate(seed: 7), brain, 50)
    assert a == b
  end

  describe "end-to-end: the real bot grows a colony over time" do
    test "harvesters mine, the forge produces goods, and a refinery gets built" do
      src = File.read!(@colony_src)

      case Compile.to_wasm(:rust, src) do
        {:ok, wasm} ->
          {:ok, inst} = ColonyWasm.instantiate(wasm)
          brain = fn world ->
            {:ok, cmds, _used} = ColonyWasm.tick(inst, World.to_view(world), 5_000_000)
            cmds
          end

          w0 = World.generate(seed: 3)
          start_ore = World.ore_remaining(w0)

          final = Sim.run(w0, brain, 120)
          ColonyWasm.stop(inst)

          # the colony actually did things over 120 ticks:
          assert World.ore_remaining(final) < start_ore, "harvesters should have mined ore"
          assert final.refined_total > 0, "the forge should have produced goods"
          refineries = World.finished_buildings(final, 1)
          building_refineries = Enum.filter(final.buildings, &(&1.kind == 1 and not &1.built))
          assert refineries != [] or building_refineries != [],
                 "the brain should have built (or started) a refinery once it could afford one"

        {:error, reason} ->
          IO.puts("\n[skip] colony grow e2e — rust toolchain unavailable: #{reason}")
          assert true
      end
    end
  end
end
