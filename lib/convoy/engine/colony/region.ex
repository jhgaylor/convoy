defmodule Convoy.Engine.Colony.Region do
  @moduledoc """
  A single-writer process owning one colony **region** (Forge & Convoy v2). Holds
  many players' private colonies + the single shared contested market, advances
  them in lockstep on a timer, drives each colony with its own brain, and runs the
  market (convoys + PvP) once per tick. Broadcasts snapshots to spectators over
  PubSub. Single-writer falls out of the GenServer (primer §4, §9).

  Each tick, in player-id order: build that player's view (their colony + the
  shared market), run their brain, resolve colony commands on their world, drain
  any launched convoys into the market. Then move + resolve all convoys (capture,
  sell) once, and credit each owner's colony. The browser spectates until a bot is
  submitted; a bundled `demo` colony runs the default bot so the page is alive and
  every soloist has an opponent to ambush.
  """
  use GenServer

  alias Convoy.Engine.Colony.{World, Sim, Market}
  alias Convoy.Engine.ColonyWasm

  @fuel 5_000_000
  @default_ms 400
  @width 16
  @height 12

  # convoy-steering ops (match Convoy.Engine.ColonyAbi)
  @op_move 2
  @op_defend 8
  @op_hunt 9

  # --- client API ---

  def ensure(id, opts \\ []) do
    spec = %{id: {:colony, id}, start: {__MODULE__, :start_link, [[{:id, id} | opts]]}, restart: :transient}

    case DynamicSupervisor.start_child(Convoy.Engine.RegionSupervisor, spec) do
      {:ok, _} -> id
      {:error, {:already_started, _}} -> id
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  defp via(id), do: {:via, Registry, {Convoy.Engine.ColonyRegistry, id}}

  def topic(id), do: "colony:#{id}"
  def snapshot(id), do: call(id, :snapshot)
  def play(id), do: cast(id, :play)
  def pause(id), do: cast(id, :pause)
  def step(id), do: cast(id, :step)
  def set_speed(id, ms), do: cast(id, {:set_speed, ms})
  def reset(id, seed), do: cast(id, {:reset, seed})
  def observe(id, pid), do: cast(id, {:observe, pid})

  @doc "Submit/replace a player's colony brain (compiled wasm/wat bytes). Joins the player if new."
  def submit_player(id, player, exec, display), do: call(id, {:submit, clean(player), exec, display})

  defp call(id, msg), do: GenServer.call(via(id), msg)
  defp cast(id, msg), do: GenServer.cast(via(id), msg)

  defp clean(p) do
    case to_string(p) |> String.replace(~r/[^a-zA-Z0-9_-]/, "") do
      "" -> "p1"
      s -> s
    end
  end

  # --- server ---

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, 1)

    state = %{
      id: Keyword.fetch!(opts, :id),
      seed: seed,
      colonies: %{},
      brains: %{},
      market: Market.new(@width, @height),
      status: :running,
      tick: 0,
      tick_ms: Keyword.get(opts, :tick_ms, @default_ms),
      last_fuel: %{},
      observers: MapSet.new()
    }

    # Seed bundled bot colonies so the room is alive out of the box. Every region
    # gets `demo`; the public `main` room also gets a `shipper` and a `builder`
    # with distinct strategies, so its market is genuinely contested.
    state = seed_residents(state)
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:submit, player, exec, display}, _from, state) do
    case ColonyWasm.instantiate(exec) do
      {:ok, inst} ->
        ColonyWasm.stop(get_in(state.brains, [player, :inst]))
        state =
          state
          |> ensure_colony(player)
          |> put_in([Access.key(:brains), player], %{inst: inst, display: display, error: nil})
          |> Map.put(:status, :running)

        broadcast(state)
        {:reply, :ok, schedule(state)}

      {:error, msg} ->
        state = update_in(state.brains, &Map.put(&1, player, %{inst: nil, display: display, error: msg}))
        broadcast(state)
        {:reply, {:error, msg}, state}
    end
  end

  @impl true
  def handle_cast(:play, state), do: {:noreply, schedule(%{state | status: :running})}
  def handle_cast(:pause, state), do: {:noreply, %{state | status: :paused}}
  def handle_cast(:step, state), do: {:noreply, broadcast(advance(state))}
  def handle_cast({:set_speed, ms}, state), do: {:noreply, %{state | tick_ms: clamp_ms(ms)}}

  def handle_cast({:reset, seed}, state) do
    # regenerate every player's colony + a fresh market, keep their brains
    colonies = Map.new(state.colonies, fn {p, _} -> {p, World.generate(seed: colony_seed(seed, p))} end)
    state = %{state | seed: seed, colonies: colonies, market: Market.new(@width, @height), tick: 0}
    {:noreply, broadcast(state)}
  end

  def handle_cast({:observe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | observers: MapSet.put(state.observers, pid)}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if state.status == :running, do: advance(state), else: state
    {:noreply, schedule(broadcast(state))}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, %{state | observers: MapSet.delete(state.observers, pid)}}
  def handle_info(_other, state), do: {:noreply, state}

  # --- the tick: every colony, then the shared market ---

  defp advance(state) do
    players = state.colonies |> Map.keys() |> Enum.sort()

    {colonies, market, intents, fuels} =
      Enum.reduce(players, {state.colonies, state.market, %{}, %{}}, fn p, {cols, mkt, ints, fs} ->
        colony = Map.fetch!(cols, p)
        {cmds, used} = run_brain(state.brains[p], colony, mkt, p)
        own_ids = MapSet.new(Market.convoys_of(mkt, p), & &1.id)
        {colony_cmds, convoy_ints} = split_commands(cmds, own_ids)

        colony = Sim.apply_commands(colony, colony_cmds)
        {launches, colony} = World.take_launches(colony)
        mkt = Enum.reduce(launches, mkt, fn l, m -> Market.launch(m, p, l.cargo) end)

        {Map.put(cols, p, colony), mkt, Map.merge(ints, convoy_ints), Map.put(fs, p, used)}
      end)

    {market, credits} = Market.step(market, intents)
    colonies = Enum.reduce(credits, colonies, fn {owner, amt}, cs -> Map.update!(cs, owner, &World.credit(&1, amt)) end)

    %{state | colonies: colonies, market: market, tick: state.tick + 1, last_fuel: fuels}
  rescue
    _ -> state
  end

  defp run_brain(%{inst: inst}, colony, market, player) when not is_nil(inst) do
    {:ok, cmds, used} = ColonyWasm.tick(inst, view_for(colony, market, player), @fuel)
    {cmds, used}
  end

  defp run_brain(_no_brain, _colony, _market, _player), do: {[], 0}

  # Build a colony's view: its own world + the shared market (own convoys flagged
  # owner=0, everyone else owner=1 — the public contested space).
  defp view_for(colony, market, player) do
    mkt =
      Enum.map(market.convoys, fn c ->
        %{id: c.id, owner: if(c.owner == player, do: 0, else: 1), x: c.x, y: c.y, cargo: c.cargo}
      end)

    %{World.to_view(colony) | market: mkt}
  end

  # Route a brain's commands: convoy-steering (for the player's OWN convoys) into a
  # per-convoy intent map; everything else stays a colony command. A command aimed
  # at a convoy that isn't the player's is dropped (you can't steer rivals).
  defp split_commands(cmds, own_ids) do
    {colony, convoy} =
      Enum.reduce(cmds, {[], %{}}, fn cmd, {cc, ci} ->
        cond do
          cmd.op == @op_defend and MapSet.member?(own_ids, cmd.target) -> {cc, Map.put(ci, cmd.target, :defend)}
          cmd.op == @op_hunt and MapSet.member?(own_ids, cmd.target) -> {cc, Map.put(ci, cmd.target, {:hunt})}
          cmd.op == @op_move and MapSet.member?(own_ids, cmd.target) -> {cc, Map.put(ci, cmd.target, {:move, {cmd.a, cmd.b}})}
          Market.convoy_id?(cmd.target) -> {cc, ci}
          true -> {[cmd | cc], ci}
        end
      end)

    {Enum.reverse(colony), convoy}
  end

  # --- joins / demo ---

  defp ensure_colony(state, player) do
    if Map.has_key?(state.colonies, player) do
      state
    else
      update_in(state.colonies, &Map.put(&1, player, World.generate(seed: colony_seed(state.seed, player))))
    end
  end

  defp colony_seed(seed, player), do: :erlang.phash2({seed, player})

  defp seed_residents(state) do
    extra =
      if state.id == "main",
        do: [{"shipper", "shipper.wasm", "examples/colony_shipper.rs"}, {"builder", "builder.wasm", "examples/colony_builder.rs"}],
        else: []

    residents = [{"demo", "default.wasm", "examples/colony.rs"} | extra]
    Enum.reduce(residents, state, fn {name, file, display}, acc -> load_resident(acc, name, file, display) end)
  end

  defp load_resident(state, name, file, display) do
    path = Path.join(:code.priv_dir(:convoy), "colony/#{file}")

    with true <- File.exists?(path),
         {:ok, bytes} <- File.read(path),
         {:ok, inst} <- ColonyWasm.instantiate(bytes) do
      state
      |> ensure_colony(name)
      |> put_in([Access.key(:brains), name], %{inst: inst, display: display, error: nil})
    else
      _ -> state
    end
  end

  # --- broadcast / snapshot ---

  defp schedule(%{status: :running} = state) do
    Process.send_after(self(), :tick, state.tick_ms)
    state
  end

  defp schedule(state), do: state

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Convoy.PubSub, topic(state.id), {:colony_update, public(state)})
    state
  end

  defp public(state) do
    players =
      state.colonies
      |> Enum.map(fn {p, w} ->
        %{
          id: p,
          credits: w.credits,
          refined: w.refined_total,
          goods: w.goods,
          ore: w.ore,
          pop: World.population(w),
          pop_cap: World.pop_cap(w),
          buildings: length(w.buildings),
          convoys: length(Market.convoys_of(state.market, p)),
          error: get_in(state.brains, [p, :error]),
          display: get_in(state.brains, [p, :display])
        }
      end)
      |> Enum.sort_by(&{-&1.credits, -&1.refined})

    %{
      region_id: state.id,
      status: state.status,
      tick_ms: state.tick_ms,
      tick: state.tick,
      width: @width,
      height: @height,
      colonies: state.colonies,
      market: state.market,
      players: players,
      last_fuel: state.last_fuel |> Map.values() |> Enum.sum()
    }
  end

  defp clamp_ms(ms) when ms < 50, do: 50
  defp clamp_ms(ms) when ms > 2000, do: 2000
  defp clamp_ms(ms), do: ms
end
