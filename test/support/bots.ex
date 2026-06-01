defmodule Convoy.Bots do
  @moduledoc """
  Test helpers that replace the old rule-DSL programs.

  `harvester/2` is the canonical harvester as a plain Elixir decider (for
  Sim-level tests, no language involved). `wat_harvester/0` and `wat_idle/0` are
  WAT modules for Region/API tests that need a real submitted program.
  """
  alias Convoy.Engine.World

  @abi "(param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)"

  @doc "Canonical harvester behaviour, matching the default WAT module."
  def harvester(entity, world) do
    pos = {entity.x, entity.y}

    cond do
      pos == world.base and entity.cargo > 0 -> :unload
      entity.cargo >= entity.cargo_max -> {:move, World.step_toward(pos, world.base)}
      World.resource_at(world, pos) > 0 -> :harvest
      true -> seek(pos, World.nearest_resource(world, pos), world.base)
    end
  end

  defp seek(pos, nil, base), do: {:move, World.step_toward(pos, base)}
  defp seek(pos, target, _base), do: {:move, World.step_toward(pos, target)}

  @doc "Always heads to the nearest ore and never returns (leaves the base cell)."
  def seeker(entity, world) do
    pos = {entity.x, entity.y}

    case World.nearest_resource(world, pos) do
      nil -> :idle
      target -> {:move, World.step_toward(pos, target)}
    end
  end

  @doc "The canonical harvester as WAT (the engine's default program)."
  def wat_harvester, do: Convoy.Engine.Wasm.default_source()

  @doc "A WAT module that always idles (returns code 0)."
  def wat_idle, do: "(module (func (export \"decide\") #{@abi} (i32.const 0)))"

  @doc "A WAT module that always seeks the nearest resource (code 4)."
  def wat_seeker, do: "(module (func (export \"decide\") #{@abi} (i32.const 4)))"
end
