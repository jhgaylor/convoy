defmodule Convoy.Engine.Colony.Market do
  @moduledoc """
  The single **shared contested market** for a colony region (Forge & Convoy v2,
  primer §1). The only place convoys from different colonies meet. A convoy is
  loaded at a colony (spending goods) and runs across this room to the market
  sell-point for credits — the score. When convoys from two colonies share a
  cell, one **seizes** the others' shipments (PvP). Bases are never attacked; the
  stake is only the shipment in transit.

  Deterministic: convoys move per their owner's per-tick intent (advance / defend
  / hunt / steer), capture resolves per-cell (defender beats a mover, else lowest
  id), then arrivals sell. Convoy ids are region-global and start at
  `@id_base` so they never collide with per-colony unit/building ids (which lets
  the Region route a brain's command to a unit vs. a convoy by id range).
  """

  alias Convoy.Engine.Colony.Market

  @id_base 1_000_000

  defstruct width: 16, height: 12, market: {15, 11}, entry: {0, 0}, convoys: [], next_id: @id_base, events: []

  @type convoy :: %{id: pos_integer(), owner: String.t(), x: non_neg_integer(), y: non_neg_integer(), cargo: non_neg_integer(), last_action: atom()}

  @max_events 30

  def id_base, do: @id_base

  @doc "A fresh market sized to the region; sell-point at the far corner, entry at (0,0)."
  def new(width, height), do: %Market{width: width, height: height, market: {width - 1, height - 1}, entry: {0, 0}}

  @doc "Inject a convoy owned by `owner` carrying `cargo` credits at the entry cell."
  def launch(%Market{} = m, owner, cargo) do
    c = %{id: m.next_id, owner: owner, x: elem(m.entry, 0), y: elem(m.entry, 1), cargo: cargo, last_action: :launch}
    %{m | convoys: m.convoys ++ [c], next_id: m.next_id + 1}
  end

  @doc "Is `id` a convoy id (vs. a per-colony unit/building id)?"
  def convoy_id?(id), do: is_integer(id) and id >= @id_base

  @doc "Convoys owned by `owner` (for building a colony's market view)."
  def convoys_of(%Market{convoys: cs}, owner), do: Enum.filter(cs, &(&1.owner == owner))

  @doc """
  Advance the market one tick: move convoys per `intents` (`%{convoy_id =>
  :advance | :defend | {:hunt} | {:move, {dx,dy}}}`, default `:advance`), resolve
  capture (PvP), then sell arrivals. Returns `{market, credits}` where `credits`
  is `%{owner => amount}` to apply to each colony's score.
  """
  @spec step(t :: %Market{}, map()) :: {%Market{}, %{String.t() => non_neg_integer()}}
  def step(%Market{} = m, intents \\ %{}) do
    m
    |> move(intents)
    |> capture()
    |> sell()
  end

  # --- movement ---

  defp move(%Market{convoys: cs} = m, intents) do
    moved = Enum.map(cs, fn c -> move_one(m, c, Map.get(intents, c.id, :advance)) end)
    %{m | convoys: moved}
  end

  defp move_one(_m, c, :defend), do: %{c | last_action: :defend}

  defp move_one(m, c, {:move, {dx, dy}}) do
    %{c | x: clamp(c.x + sign(dx), m.width), y: clamp(c.y + sign(dy), m.height), last_action: :move}
  end

  defp move_one(m, c, {:hunt}) do
    case nearest_enemy(m, c) do
      nil -> advance(m, c)
      e -> {dx, dy} = step_toward({c.x, c.y}, {e.x, e.y}); %{c | x: c.x + dx, y: c.y + dy, last_action: :hunt}
    end
  end

  defp move_one(m, c, _advance), do: advance(m, c)

  defp advance(m, c) do
    {dx, dy} = step_toward({c.x, c.y}, m.market)
    %{c | x: c.x + dx, y: c.y + dy, last_action: :advance}
  end

  # --- capture (PvP): on a shared cell, one convoy seizes the others' shipments ---

  defp capture(%Market{convoys: cs} = m) do
    cs
    |> Enum.group_by(fn c -> {c.x, c.y} end)
    |> Enum.reduce(m, fn {cell, group}, acc -> capture_cell(acc, cell, group) end)
  end

  defp capture_cell(m, cell, group) do
    owners = group |> Enum.map(& &1.owner) |> Enum.uniq()

    if length(owners) >= 2 do
      sorted = Enum.sort_by(group, & &1.id)
      winner = Enum.find(sorted, hd(sorted), &(&1.last_action == :defend))
      losers = Enum.reject(sorted, &(&1.id == winner.id))
      seized = losers |> Enum.map(& &1.cargo) |> Enum.sum()
      loser_ids = MapSet.new(losers, & &1.id)

      convoys =
        m.convoys
        |> Enum.reject(&MapSet.member?(loser_ids, &1.id))
        |> Enum.map(fn c -> if c.id == winner.id, do: %{c | cargo: c.cargo + seized, last_action: :seize}, else: c end)

      note(%{m | convoys: convoys}, "#{winner.owner}/C#{winner.id} seized #{seized} credits' worth at #{fmt(cell)}.")
    else
      m
    end
  end

  # --- selling: convoys reaching the market sell, crediting their owner ---

  defp sell(%Market{convoys: cs, market: mk} = m) do
    {arrived, rest} = Enum.split_with(cs, fn c -> {c.x, c.y} == mk end)

    credits = Enum.reduce(arrived, %{}, fn c, acc -> Map.update(acc, c.owner, c.cargo, &(&1 + c.cargo)) end)

    m =
      Enum.reduce(arrived, %{m | convoys: rest}, fn c, acc ->
        note(acc, "#{c.owner}/C#{c.id} delivered a shipment (+#{c.cargo} credits).")
      end)

    {m, credits}
  end

  # --- helpers ---

  defp nearest_enemy(%Market{convoys: cs}, %{owner: owner, x: x, y: y}) do
    cs
    |> Enum.reject(&(&1.owner == owner))
    |> Enum.sort_by(& &1.id)
    |> Enum.min_by(fn e -> abs(e.x - x) + abs(e.y - y) end, fn -> nil end)
  end

  defp step_toward({x, y}, {tx, ty}) do
    cond do
      x < tx -> {1, 0}
      x > tx -> {-1, 0}
      y < ty -> {0, 1}
      y > ty -> {0, -1}
      true -> {0, 0}
    end
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  defp clamp(v, _s) when v < 0, do: 0
  defp clamp(v, s) when v >= s, do: s - 1
  defp clamp(v, _s), do: v

  defp note(%Market{events: e} = m, msg), do: %{m | events: Enum.take([msg | e], @max_events)}
  defp fmt({x, y}), do: "(#{x},#{y})"
end
