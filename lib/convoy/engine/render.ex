defmodule Convoy.Engine.Render do
  @moduledoc """
  Renders a `World` to text for the terminal — the headless counterpart to the
  LiveView grid, so `convoy.run --headless` can show a bot running without a
  browser.

  Each player harvests in their own **private room**; everyone's convoys share
  one **market room**. We print one grid per player's room, then the market room.

  Legend: `B` base · `M` market · `E` market entry · `1..9` harvester (its id) ·
  `C` convoy · `*` ore · `·` empty.
  """

  alias Convoy.Engine.World

  @doc "A full frame: every room's grid plus a stats line and recent events."
  @spec frame(World.t()) :: String.t()
  def frame(%World{} = world) do
    [rooms(world), "\n", stats(world), "\n", events(world)]
    |> IO.iodata_to_binary()
  end

  # One labelled grid per player room, then the shared market room.
  defp rooms(%World{} = world) do
    player_rooms =
      world
      |> World.room_ids()
      |> Enum.sort()
      |> Enum.map(fn room -> ["room #{room}\n", room_grid(world, room), "\n"] end)

    [player_rooms, "market\n", market_grid(world)]
  end

  @doc "A single harvesting room's grid rows (base, ore, that player's harvesters)."
  @spec room_grid(World.t(), World.room()) :: String.t()
  def room_grid(%World{} = world, room) do
    render_grid(world, fn pos -> room_cell(world, room, pos) end)
  end

  @doc "The shared market room's grid rows (market sell-point, entry, convoys)."
  @spec market_grid(World.t()) :: String.t()
  def market_grid(%World{} = world) do
    render_grid(world, fn pos -> market_cell(world, pos) end)
  end

  defp render_grid(%World{} = world, cell_fun) do
    for y <- 0..(world.height - 1) do
      for x <- 0..(world.width - 1), do: cell_fun.({x, y})
    end
    |> Enum.map_join("\n", &Enum.join(&1, " "))
  end

  @doc "One-line summary of the world's headline numbers."
  @spec stats(World.t()) :: String.t()
  def stats(%World{} = world) do
    cargo = world.entities |> Enum.map(& &1.cargo) |> Enum.sum()

    scores =
      world.bases
      |> Enum.sort_by(fn {_p, b} -> -b.credits end)
      |> Enum.map_join("  ", fn {p, b} ->
        t = b.tech

        "#{p}:#{b.credits}cr(refined #{b.refined_total}/goods #{b.goods}/R#{t.refine}C#{t.cargo}F#{t.fuel})"
      end)

    convoys = World.convoys(world) |> length()

    "tick #{world.tick}  credits #{World.total_credits(world)}  refined #{World.total_refined(world)}  " <>
      "in-cargo #{cargo}  convoys #{convoys}  ore-left #{World.ore_remaining(world)}\nbases  #{scores}"
  end

  defp events(%World{events: []}), do: ""

  defp events(%World{events: events}) do
    events
    |> Enum.take(3)
    |> Enum.map_join("\n", &("  · " <> &1))
  end

  # A cell in one player's private harvesting room: their harvesters, the base,
  # and that room's ore — nothing from any other player.
  defp room_cell(world, room, pos) do
    cond do
      e = entity_in(world, room, pos) ->
        Integer.to_string(rem(e.id, 10))

      pos == world.base ->
        "B"

      World.resource_at(world, room, pos) > 0 ->
        "*"

      true ->
        "·"
    end
  end

  # A cell in the shared market room: the sell-point, the entry, and convoys.
  defp market_cell(world, pos) do
    cond do
      entity_in(world, :market, pos) -> "C"
      pos == World.market(world) -> "M"
      pos == world.market_entry -> "E"
      true -> "·"
    end
  end

  defp entity_in(world, room, {x, y}) do
    Enum.find(world.entities, &(&1.room == room and &1.x == x and &1.y == y))
  end
end
