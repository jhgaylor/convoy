defmodule Convoy.Engine.RenderTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.{World, Sim, Render}

  test "a room grid has one row per world row" do
    world = World.generate(seed: 1) |> World.add_player("p1")
    rows = world |> Render.room_grid("p1") |> String.split("\n")
    assert length(rows) == world.height
  end

  test "the base shows as B once harvesters move off it" do
    # a few ticks so the harvesters leave the base cell (they all start on it)
    grid =
      World.generate(seed: 1)
      |> World.add_player("p1")
      |> Sim.run(&Convoy.Bots.seeker/2, 3)
      |> Render.room_grid("p1")

    assert grid =~ "B"
  end

  test "frame includes the stats line and labels each room" do
    frame = World.generate(seed: 1) |> World.add_player("p1") |> Render.frame()
    assert frame =~ "tick 0"
    assert frame =~ "refined 0"
    assert frame =~ "bases"
    assert frame =~ "ore-left"
    assert frame =~ "room p1"
    assert frame =~ "market"
  end

  test "harvesters render as their id digit in their room" do
    world = World.generate(seed: 1) |> World.add_player("p1")
    # all harvesters start on the base cell, so the base shows a digit, not B
    assert Render.room_grid(world, "p1") =~ "1"
  end

  test "the market room shows the sell-point and convoy entry" do
    grid = World.generate(seed: 1) |> World.add_player("p1") |> Render.market_grid()
    assert grid =~ "M"
    assert grid =~ "E"
  end
end
