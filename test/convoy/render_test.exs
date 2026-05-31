defmodule Convoy.Engine.RenderTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Program, Sim, Render}

  test "grid has one row per world row" do
    world = World.generate(seed: 1)
    rows = world |> Render.grid() |> String.split("\n")
    assert length(rows) == world.height
  end

  test "the base shows as B once harvesters move off it" do
    {:ok, rules} = Program.compile("otherwise to_resource")
    # a few ticks so the harvesters leave the base cell (they all start on it)
    grid = World.generate(seed: 1) |> Sim.run(rules, 3) |> Render.grid()
    assert grid =~ "B"
  end

  test "frame includes the stats line" do
    frame = World.generate(seed: 1) |> Render.frame()
    assert frame =~ "tick 0"
    assert frame =~ "delivered 0"
    assert frame =~ "ore-left"
  end

  test "harvesters render as their id digit" do
    world = World.generate(seed: 1)
    # all harvesters start on the base cell, so the base shows a digit, not B
    assert Render.grid(world) =~ "1"
  end
end
