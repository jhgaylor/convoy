defmodule Convoy.Engine.Colony.UpgradeTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.Colony.{World, Sim}

  @upgrade_spawner %{op: 6, target: 1, a: 0, b: 0}

  defp rich(seed \\ 1, goods \\ 500), do: %{World.generate(seed: seed) | goods: goods}

  test "upgrading the spawner is time-gated, then lifts the pop cap" do
    w = rich()
    assert World.pop_cap(w) == 4
    assert World.building(w, 1).level == 0

    # Issuing the upgrade spends goods and starts a timer; level holds meanwhile.
    w = Sim.apply_commands(w, [@upgrade_spawner])
    assert World.building(w, 1).remaining > 0
    assert World.building(w, 1).level == 0
    assert World.pop_cap(w) == 4
    assert w.goods == 500 - 30

    # After the build time elapses, the level (and pop cap) rises one step.
    w = Enum.reduce(1..25, w, fn _i, acc -> Sim.apply_commands(acc, []) end)
    assert World.building(w, 1).level == 1
    assert World.pop_cap(w) == 6
  end

  test "upgrade cost scales with level and respects max_level" do
    # Spam the upgrade with deep pockets; it should climb to max_level and stop,
    # charging base*(level+1) each step (30, 60, 90, 120 by default).
    brain = fn _ -> [@upgrade_spawner] end
    w = Sim.run(rich(1, 10_000), brain, 400)

    assert World.building(w, 1).level == World.max_level(w)
    # base 30 * (1+2+3+4) = 300 across four upgrades; nothing more once maxed.
    assert w.goods == 10_000 - 300
  end

  test "an in-flight upgrade is not double-charged and refinery upgrades lift throughput" do
    # Build a refinery, let it finish, then upgrade it. Throughput = 1 + 2*(level+1).
    w = %{World.generate(seed: 1) | goods: 500}
    # build a refinery at (1,1): packed b = (x <<< 8) ||| y = 257
    w = Sim.apply_commands(w, [%{op: 4, target: 0, a: 1, b: 257}])
    ref_id = Enum.find(w.buildings, &(&1.kind == 1)).id
    w = Enum.reduce(1..31, w, fn _i, acc -> Sim.apply_commands(acc, []) end)
    assert World.building(w, ref_id).built
    base_through = World.refine_throughput(w)

    # Re-issue the upgrade every tick. For the first 10 ticks (< the 25-tick build
    # time) the upgrade is still in flight: charged exactly once, level unchanged.
    goods_before = w.goods
    upg = %{op: 6, target: ref_id, a: 0, b: 0}
    w = Enum.reduce(1..10, w, fn _i, acc -> Sim.apply_commands(acc, [upg]) end)
    assert World.building(w, ref_id).level == 0
    assert World.building(w, ref_id).remaining > 0
    assert goods_before - w.goods == 30

    # Let it finish (stop re-issuing): the level and throughput rise one step.
    w = Enum.reduce(1..20, w, fn _i, acc -> Sim.apply_commands(acc, []) end)
    assert World.building(w, ref_id).level == 1
    assert World.refine_throughput(w) == base_through + 2
  end

  test "replays stay bit-identical with upgrades in the mix" do
    brain = fn _ -> [@upgrade_spawner] end
    a = Sim.run(rich(7, 1_000), brain, 200)
    b = Sim.run(rich(7, 1_000), brain, 200)
    assert a == b
  end
end
