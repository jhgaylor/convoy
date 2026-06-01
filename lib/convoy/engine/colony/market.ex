defmodule Convoy.Engine.Colony.Market do
  @moduledoc """
  The single **shared contested market** for a colony region (Forge & Convoy v2,
  primer §1). The only place convoys from different colonies meet. A convoy is
  loaded at a colony (spending goods) and runs across this room to the market
  sell-point for credits — the score. When convoys from two colonies share a
  cell, one **seizes** the others' shipments (PvP). Bases are never attacked; the
  stake is only the shipment in transit.

  Deterministic: convoys move per their owner's per-tick intent (advance / defend
  / hunt / steer), capture resolves per-cell as a **stance triangle**, then
  arrivals sell. Convoy ids are region-global and start at `@id_base` so they
  never collide with per-colony unit/building ids (which lets the Region route a
  brain's command to a unit vs. a convoy by id range).

  ## The stance triangle (PvP)

  Each tick a convoy's stance is set by the intent it was issued: `:hunt` (raider),
  `:defend` (escort), or passive (`:advance`/`:move`/just-launched). When enemy
  convoys share a cell, a convoy is **defeated** (cargo seized, removed) when an
  enemy on that cell holds a stance that *beats* it:

      hunt  ⊳ passive   — a raider plunders an unguarded shipment
      defend ⊳ hunt     — an escort turns the tables on the raider, taking its haul
      defend ⊳ passive  — NO. a defender lets peaceful traffic pass.

  No stance dominates: passive→(beaten by)→hunt→defend→(beats nothing else). A
  defeated convoy's cargo goes to the lowest-id *surviving* enemy that beat it
  (else it's lost in the melee). Two passive convoys crossing a cell don't fight —
  raiding is an opt-in, counterable act, not an accident of geometry. This is what
  kills the "park a defender on the drop point and farm everyone" exploit: a lone
  defender seizes nothing from the passive stream; to plunder you must `hunt`
  (which can be steered onto a target but loses to a co-located defender escort).
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

  @doc "Remove every convoy owned by `owner` (used when a player is kicked)."
  def drop_owner(%Market{convoys: cs} = m, owner), do: %{m | convoys: Enum.reject(cs, &(&1.owner == owner))}

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

  # Steered hunt: hold the aggressive stance while the brain aims the step itself
  # (predict where the shipment will be and intercept). Stance is :hunt regardless.
  defp move_one(m, c, {:hunt, {dx, dy}}) do
    %{c | x: clamp(c.x + sign(dx), m.width), y: clamp(c.y + sign(dy), m.height), last_action: :hunt}
  end

  # Auto-homing hunt: step toward the nearest enemy convoy (op 9 with dx=dy=0).
  defp move_one(m, c, {:hunt}) do
    case nearest_enemy(m, c) do
      nil -> %{advance(m, c) | last_action: :hunt}
      e -> {dx, dy} = step_toward({c.x, c.y}, {e.x, e.y}); %{c | x: c.x + dx, y: c.y + dy, last_action: :hunt}
    end
  end

  defp move_one(m, c, _advance), do: advance(m, c)

  defp advance(m, c) do
    {dx, dy} = step_toward({c.x, c.y}, m.market)
    %{c | x: c.x + dx, y: c.y + dy, last_action: :advance}
  end

  # --- capture (PvP): the stance triangle. See the moduledoc. On a shared cell a
  # convoy is defeated when an enemy there holds a stance that beats it; its cargo
  # goes to the lowest-id surviving enemy that beat it. ---

  defp capture(%Market{convoys: cs} = m) do
    cs
    |> Enum.group_by(fn c -> {c.x, c.y} end)
    |> Enum.reduce(m, fn {cell, group}, acc -> capture_cell(acc, cell, group) end)
  end

  defp capture_cell(m, cell, group) do
    sorted = Enum.sort_by(group, & &1.id)
    losers = Enum.filter(sorted, fn c -> beaten?(sorted, c) end)

    if losers == [] do
      m
    else
      loser_ids = MapSet.new(losers, & &1.id)
      survivors = Enum.reject(sorted, &MapSet.member?(loser_ids, &1.id))

      # award each loser's cargo to the lowest-id surviving enemy that beat it
      awards =
        Enum.reduce(losers, %{}, fn l, acc ->
          case Enum.find(survivors, fn s -> s.owner != l.owner and beats?(stance(s), stance(l)) end) do
            nil -> acc
            captor -> Map.update(acc, captor.id, l.cargo, &(&1 + l.cargo))
          end
        end)

      convoys =
        m.convoys
        |> Enum.reject(&MapSet.member?(loser_ids, &1.id))
        |> Enum.map(fn c ->
          case Map.get(awards, c.id) do
            nil -> c
            gained -> %{c | cargo: c.cargo + gained, last_action: :seize}
          end
        end)

      # notes in captor-id order so the event log is replay-deterministic
      awards
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.reduce(%{m | convoys: convoys}, fn {captor_id, gained}, acc ->
        captor = Enum.find(survivors, &(&1.id == captor_id))
        note(acc, "#{captor.owner}/C#{captor.id} seized #{gained} credits' worth at #{fmt(cell)}.")
      end)
    end
  end

  # A convoy is beaten if any ENEMY on its cell holds a stance that beats its own.
  defp beaten?(group, c), do: Enum.any?(group, fn e -> e.owner != c.owner and beats?(stance(e), stance(c)) end)

  defp stance(%{last_action: :defend}), do: :defend
  defp stance(%{last_action: :hunt}), do: :hunt
  defp stance(_), do: :passive

  # the triangle: hunt plunders the passive, defend plunders hunters, nothing else.
  defp beats?(:hunt, :passive), do: true
  defp beats?(:defend, :hunt), do: true
  defp beats?(_, _), do: false

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
