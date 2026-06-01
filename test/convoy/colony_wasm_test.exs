defmodule Convoy.ColonyWasmTest do
  @moduledoc """
  Sandbox/containment tests for the v2 colony runner (`Convoy.Engine.ColonyWasm`).
  This is the v2 successor to the deleted v1 `wasm_test.exs`: it proves the same
  primer §7/§9 properties — constrained instantiation, deterministic fuel, and
  containment of misbehaving modules — against the colony ABI (`inbuf`/`outbuf`/
  `tick`) instead of the retired per-entity `decide` ABI.
  """
  use ExUnit.Case, async: true

  alias Convoy.Engine.ColonyWasm

  # A minimal, well-behaved colony module: exports the ABI, issues no commands.
  @ok_module """
  (module
    (memory (export "memory") 1)
    (func (export "inbuf") (result i32) (i32.const 0))
    (func (export "outbuf") (result i32) (i32.const 1024))
    (func (export "tick") (param i32) (result i32) (i32.const 0)))
  """

  # A tiny valid view — enough for ColonyAbi.encode_view (arrays default to []).
  defp view,
    do: %{tick: 0, width: 8, height: 8, units: [], buildings: [], deposits: [], market: []}

  # primer §9.1 — instantiate a module with the constrained ABI + import set.
  test "instantiates a well-behaved colony module and runs one tick" do
    assert {:ok, inst} = ColonyWasm.instantiate(@ok_module)
    assert {:ok, [], used} = ColonyWasm.tick(inst, view(), 50_000)
    assert used > 0
    ColonyWasm.stop(inst)
  end

  test "a module missing the colony ABI is rejected" do
    assert {:error, msg} = ColonyWasm.instantiate("(module)")
    assert msg =~ "inbuf" or msg =~ "colony ABI"
  end

  test "invalid WAT returns a compile error, not a crash" do
    assert {:error, _msg} = ColonyWasm.instantiate("(this is not wat")
  end

  # primer §9.2 — fuel metering is deterministic across runs.
  test "fuel consumption is deterministic for the same input" do
    {:ok, inst} = ColonyWasm.instantiate(@ok_module)
    {:ok, [], used1} = ColonyWasm.tick(inst, view(), 50_000)
    {:ok, [], used2} = ColonyWasm.tick(inst, view(), 50_000)
    assert used1 == used2
    ColonyWasm.stop(inst)
  end

  # primer §9.3 — a misbehaving module (infinite loop) is contained by fuel and
  # the colony forfeits its turn (no commands), without crashing the instance.
  test "an infinite loop in tick is contained by fuel; the colony forfeits its turn" do
    spinner = """
    (module
      (memory (export "memory") 1)
      (func (export "inbuf") (result i32) (i32.const 0))
      (func (export "outbuf") (result i32) (i32.const 1024))
      (func (export "tick") (param i32) (result i32)
        (loop $l (br $l)) (i32.const 0)))
    """

    {:ok, inst} = ColonyWasm.instantiate(spinner)
    assert {:ok, [], used} = ColonyWasm.tick(inst, view(), 5_000)
    assert used == 5_000
    assert Process.alive?(inst.pid)
    ColonyWasm.stop(inst)
  end

  # primer §7 — fuel bounds CPU; StoreLimits bounds allocation. A module
  # demanding far more linear memory than the 16 MB cap is rejected, and the
  # failure is CONTAINED: the calling process survives.
  test "a module exceeding the memory limit is rejected, not fatal" do
    # 2000 pages = ~128 MB initial memory, over the 16 MB store cap.
    bomb = """
    (module
      (memory (export "memory") 2000)
      (func (export "inbuf") (result i32) (i32.const 0))
      (func (export "outbuf") (result i32) (i32.const 1024))
      (func (export "tick") (param i32) (result i32) (i32.const 0)))
    """

    assert {:error, _msg} = ColonyWasm.instantiate(bomb)
    assert Process.alive?(self()), "instantiation failure must not kill the calling process"
  end

  # A module that grows memory without bound is contained by fuel + caps.
  test "unbounded memory growth in tick is contained" do
    grower = """
    (module
      (memory (export "memory") 1)
      (func (export "inbuf") (result i32) (i32.const 0))
      (func (export "outbuf") (result i32) (i32.const 1024))
      (func (export "tick") (param i32) (result i32)
        (loop $l (drop (memory.grow (i32.const 64))) (br $l))
        (i32.const 0)))
    """

    {:ok, inst} = ColonyWasm.instantiate(grower)
    assert {:ok, [], used} = ColonyWasm.tick(inst, view(), 50_000)
    assert used == 50_000
    assert Process.alive?(inst.pid)
    ColonyWasm.stop(inst)
  end
end
