defmodule Convoy.WasmTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Program, Sim, Wasm}

  defp wasm_decider(instance) do
    fn entity, world ->
      {:ok, intent, _used} = Wasm.decide(instance, entity, world, 50_000)
      intent
    end
  end

  # primer §9.1 — instantiate a module with a constrained import set.
  test "instantiates the default harvester and exports decide" do
    assert {:ok, instance} = Wasm.instantiate(Wasm.default_source())
    e = %{id: 1, x: 0, y: 0, cargo: 0, cargo_max: 5, last_action: :idle}
    world = World.generate(seed: 1)

    assert {:ok, intent, used} = Wasm.decide(instance, e, world, 50_000)
    # Empty at base → seek a resource (to_resource = a move intent).
    assert match?({:move, _}, intent)
    assert used > 0
    Wasm.stop(instance)
  end

  test "a module without a decide export is rejected" do
    assert {:error, msg} = Wasm.instantiate("(module)")
    assert msg =~ "decide"
  end

  test "invalid WAT returns a compile error, not a crash" do
    assert {:error, _msg} = Wasm.instantiate("(this is not wat")
  end

  # primer §9.2 — fuel metering is deterministic across runs.
  test "fuel consumption is deterministic for the same input" do
    {:ok, instance} = Wasm.instantiate(Wasm.default_source())
    e = %{id: 1, x: 2, y: 2, cargo: 0, cargo_max: 5, last_action: :idle}
    world = World.generate(seed: 1)

    {:ok, _i1, used1} = Wasm.decide(instance, e, world, 50_000)
    {:ok, _i2, used2} = Wasm.decide(instance, e, world, 50_000)
    assert used1 == used2
    Wasm.stop(instance)
  end

  # primer §9.3 — a misbehaving module (infinite loop) is contained.
  test "an infinite loop is contained by fuel and degrades to idle" do
    spinner = """
    (module
      (func (export "decide")
        (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)
        (loop $l (br $l))
        (i32.const 4)))
    """

    {:ok, instance} = Wasm.instantiate(spinner)
    e = %{id: 1, x: 0, y: 0, cargo: 0, cargo_max: 5, last_action: :idle}
    world = World.generate(seed: 1)

    # Should not raise / crash; the trap is caught and the entity idles.
    assert {:ok, :idle, used} = Wasm.decide(instance, e, world, 5_000)
    assert used == 5_000
    assert Process.alive?(instance.pid)
    Wasm.stop(instance)
  end

  @abi "(param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)"

  # primer §7 — fuel bounds CPU; StoreLimits bounds allocation. A module
  # demanding more linear memory than the cap is rejected at instantiation,
  # and crucially the failure is CONTAINED: the caller (a region) survives.
  test "a module exceeding the memory limit is rejected, not fatal" do
    # 2000 pages = ~125 MB initial memory, over the 16 MB store cap.
    bomb = "(module (memory 2000) (func (export \"decide\") #{@abi} (i32.const 4)))"

    caller_alive =
      try do
        assert {:error, msg} = Wasm.instantiate(bomb)
        assert msg =~ "memory"
        true
      catch
        _, _ -> false
      end

    assert caller_alive, "instantiation failure must not kill the calling process"
    # And the test process is demonstrably still running afterwards.
    assert Process.alive?(self())
  end

  test "a module that grows memory without bound is contained by fuel + caps" do
    grower = """
    (module (memory 1)
      (func (export "decide") #{@abi}
        (loop $l (drop (memory.grow (i32.const 64))) (br $l))
        (i32.const 4)))
    """

    {:ok, instance} = Wasm.instantiate(grower)
    e = %{id: 1, x: 0, y: 0, cargo: 0, cargo_max: 5, last_action: :idle}
    world = World.generate(seed: 1)

    assert {:ok, :idle, used} = Wasm.decide(instance, e, world, 50_000)
    assert used == 50_000
    assert Process.alive?(instance.pid)
    Wasm.stop(instance)
  end

  test "intent code 6 routes toward the farthest resource, code 4 toward the nearest" do
    seek = fn code -> "(module (func (export \"decide\") #{@abi} (i32.const #{code})))" end

    # Base at (0,0). Near node east (1,0); far-from-base node south (0,10).
    world = %{World.generate(seed: 1) | base: {0, 0}, resources: %{{1, 0} => 5, {0, 10} => 5}}
    e = %{id: 1, x: 0, y: 0, cargo: 0, cargo_max: 5, last_action: :idle}

    {:ok, near} = Wasm.instantiate(seek.(4))
    {:ok, far} = Wasm.instantiate(seek.(6))

    assert {:ok, {:move, {1, 0}}, _} = Wasm.decide(near, e, world, 50_000)
    assert {:ok, {:move, {0, 1}}, _} = Wasm.decide(far, e, world, 50_000)

    Wasm.stop(near)
    Wasm.stop(far)
  end

  # Regression: code 6 measures distance from BASE, not the harvester, so the
  # target doesn't flip as the harvester approaches it (no oscillation loop).
  test "code 6 keeps heading to the far node instead of turning back" do
    far = "(module (func (export \"decide\") #{@abi} (i32.const 6)))"
    {:ok, inst} = Wasm.instantiate(far)

    # Base (0,0). Near node (2,0); far-from-base node (10,0). Harvester sits at
    # (9,0) — almost on the far node. Farthest-from-*harvester* would be the near
    # node (turn back); farthest-from-*base* is still (10,0) (keep going).
    world = %{World.generate(seed: 1) | base: {0, 0}, resources: %{{2, 0} => 5, {10, 0} => 5}}
    e = %{id: 1, x: 9, y: 0, cargo: 0, cargo_max: 5, last_action: :idle}

    assert {:ok, {:move, {1, 0}}, _} = Wasm.decide(inst, e, world, 50_000)
    Wasm.stop(inst)
  end

  # The payoff: the WAT harvester reproduces the rule-DSL behaviour exactly.
  test "the WAT harvester delivers identically to the equivalent rule program" do
    {:ok, rules} =
      Program.compile("""
      when can_unload  unload
      when cargo_full  to_base
      when on_resource harvest
      otherwise        to_resource
      """)

    {:ok, instance} = Wasm.instantiate(Wasm.default_source())

    rules_world = World.generate(seed: 9) |> Sim.run(rules, 200)
    wasm_world = World.generate(seed: 9) |> Sim.run(wasm_decider(instance), 200)

    assert wasm_world.delivered == rules_world.delivered
    assert wasm_world.delivered > 0
    assert wasm_world.resources == rules_world.resources

    Wasm.stop(instance)
  end

  # WASM runs through the same authoritative Sim, so the anti-cheat / replay
  # guarantees still hold: two runs of the same module are bit-identical.
  test "the wasm-driven sim is deterministic across runs" do
    {:ok, a} = Wasm.instantiate(Wasm.default_source())
    {:ok, b} = Wasm.instantiate(Wasm.default_source())

    run_a = World.generate(seed: 4) |> Sim.run(wasm_decider(a), 150)
    run_b = World.generate(seed: 4) |> Sim.run(wasm_decider(b), 150)
    assert run_a == run_b

    Wasm.stop(a)
    Wasm.stop(b)
  end
end
