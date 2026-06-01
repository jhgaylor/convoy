defmodule Convoy.Engine.RenderTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Sim, Render}

  test "grid has one row per world row" do
    world = World.generate(seed: 1)
    rows = world |> Render.grid() |> String.split("\n")
    assert length(rows) == world.height
  end

  test "the base shows as B once harvesters move off it" do
    # a few ticks so the harvesters leave the base cell (they all start on it)
    grid =
      World.generate(seed: 1)
      |> World.add_player("p1")
      |> Sim.run(&Convoy.Bots.seeker/2, 3)
      |> Render.grid()

    assert grid =~ "B"
  end

  test "frame includes the stats line" do
    frame = World.generate(seed: 1) |> Render.frame()
    assert frame =~ "tick 0"
    assert frame =~ "refined 0"
    assert frame =~ "bases"
    assert frame =~ "ore-left"
  end

  test "harvesters render as their id digit" do
    world = World.generate(seed: 1) |> World.add_player("p1")
    # all harvesters start on the base cell, so the base shows a digit, not B
    assert Render.grid(world) =~ "1"
  end
end
