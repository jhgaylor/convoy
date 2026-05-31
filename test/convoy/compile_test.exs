defmodule Convoy.CompileTest do
  use ExUnit.Case, async: false

  alias Convoy.Compile
  alias Convoy.Engine.{World, Program, Sim, Wasm}

  defp wasm_decider(instance) do
    fn entity, world ->
      {:ok, intent, _used} = Wasm.decide(instance, entity, world, 50_000)
      intent
    end
  end

  defp rules_baseline do
    {:ok, rules} =
      Program.compile("""
      when can_unload  unload
      when cargo_full  to_base
      when on_resource harvest
      otherwise        to_resource
      """)

    World.generate(seed: 9) |> Sim.run(rules, 200)
  end

  # A compiled module must behave exactly like the canonical rule program —
  # that's the proof the ABI + template are correct, end to end.
  defp assert_parity_with_rules(wasm_bytes) do
    {:ok, instance} = Wasm.instantiate(wasm_bytes)
    wasm_world = World.generate(seed: 9) |> Sim.run(wasm_decider(instance), 200)
    baseline = rules_baseline()

    assert wasm_world.delivered == baseline.delivered
    assert wasm_world.delivered > 0
    assert wasm_world.resources == baseline.resources
    Wasm.stop(instance)
  end

  test "WAT passes through untouched (Wasmtime compiles text directly)" do
    assert {:ok, "(module)"} = Compile.to_wasm(:wat, "(module)")
  end

  test "every language ships a template that mentions decide" do
    for lang <- [:assemblyscript, :rust, :tinygo] do
      assert Compile.template(lang) =~ "decide"
    end
  end

  describe "AssemblyScript" do
    @describetag :assemblyscript

    test "compiles the template to a zero-import wasm that matches the rules" do
      if Compile.available?(:assemblyscript) do
        assert {:ok, bytes} = Compile.to_wasm(:assemblyscript, Compile.template(:assemblyscript))
        assert is_binary(bytes)
        assert_parity_with_rules(bytes)
      else
        IO.puts("[skip] AssemblyScript toolchain not installed")
      end
    end

    test "a syntax error returns a message, not a crash" do
      if Compile.available?(:assemblyscript) do
        assert {:error, msg} = Compile.to_wasm(:assemblyscript, "export function decide( {{{ ")
        assert is_binary(msg) and msg != ""
      end
    end
  end

  describe "Rust" do
    @describetag :rust

    test "compiles the template single-file to wasm32 and matches the rules" do
      if Compile.available?(:rust) do
        assert {:ok, bytes} = Compile.to_wasm(:rust, Compile.template(:rust))
        assert_parity_with_rules(bytes)
      else
        IO.puts("[skip] Rust toolchain not installed")
      end
    end

    test "a compile error returns a message, not a crash" do
      if Compile.available?(:rust) do
        assert {:error, msg} = Compile.to_wasm(:rust, "fn this is not rust")
        assert is_binary(msg)
      end
    end
  end

  test "missing toolchains report unavailable with an install hint" do
    for lang <- [:rust, :tinygo, :assemblyscript] do
      unless Compile.available?(lang) do
        assert {:error, msg} = Compile.to_wasm(lang, Compile.template(lang))
        assert msg =~ "not"
        assert is_binary(Compile.install_hint(lang))
      end
    end
  end
end
