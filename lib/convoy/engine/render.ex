defmodule Convoy.Engine.Render do
  @moduledoc """
  Renders a `World` to text for the terminal — the headless counterpart to the
  LiveView grid, so `convoy.run --headless` can show a bot running without a
  browser.

  Legend: `B` base · `1..9` harvester (its id) · `*` ore · `·` empty.
  """

  alias Convoy.Engine.World

  @doc "A full frame: the grid plus a stats line and recent events."
  @spec frame(World.t()) :: String.t()
  def frame(%World{} = world) do
    [grid(world), "\n", stats(world), "\n", events(world)]
    |> IO.iodata_to_binary()
  end

  @doc "Just the grid rows."
  @spec grid(World.t()) :: String.t()
  def grid(%World{} = world) do
    for y <- 0..(world.height - 1) do
      for x <- 0..(world.width - 1) do
        cell(world, {x, y})
      end
    end
    |> Enum.map_join("\n", &Enum.join(&1, " "))
  end

  @doc "One-line summary of the world's headline numbers."
  @spec stats(World.t()) :: String.t()
  def stats(%World{} = world) do
    cargo = world.entities |> Enum.map(& &1.cargo) |> Enum.sum()

    scores =
      world.bases
      |> Enum.sort_by(fn {_p, b} -> -b.refined_total end)
      |> Enum.map_join("  ", fn {p, b} ->
        t = b.tech
        "#{p}:#{b.refined_total}(ore #{b.ore}/goods #{b.goods}/R#{t.refine}C#{t.cargo}F#{t.fuel})"
      end)

    "tick #{world.tick}  refined #{World.total_refined(world)}  stockpile #{World.total_stockpile(world)}  " <>
      "in-cargo #{cargo}  ore-left #{World.ore_remaining(world)}\nbases  #{scores}"
  end

  defp events(%World{events: []}), do: ""

  defp events(%World{events: events}) do
    events
    |> Enum.take(3)
    |> Enum.map_join("\n", &("  · " <> &1))
  end

  defp cell(world, pos) do
    cond do
      entity = entity_at(world, pos) -> Integer.to_string(rem(entity.id, 10))
      pos == world.base -> "B"
      World.resource_at(world, pos) > 0 -> "*"
      true -> "·"
    end
  end

  defp entity_at(world, {x, y}) do
    Enum.find(world.entities, &(&1.x == x and &1.y == y))
  end
end
