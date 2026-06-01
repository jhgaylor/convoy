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

  alias Convoy.Engine.Colony.{World, Sim, Market, Persistence}
  alias Convoy.Engine.ColonyWasm

  @fuel 5_000_000
  @default_ms 400
  @width 16
  @height 12
  @snapshot_every 50

  # Spectator time-series: sample each colony's headline metrics every
  # @history_every ticks, keeping the last @history_max points (newest-first).
  # 240 points × 20 ticks ≈ 4800 ticks (~32 min at the 1x 400ms speed), enough
  # to back the spectator's 30m window.
  @history_every 20
  @history_max 240

  @doc "Bring every persisted colony region back online (called on boot)."
  def restore_all do
    if Application.get_env(:convoy, :restore_on_boot, true) do
      for id <- Persistence.region_ids(), do: ensure(id)
    end

    :ok
  end

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

  @doc "Evict a player: drop their colony, brain, convoys, history, and stop their wasm."
  def kick(id, player), do: call(id, {:kick, clean(player)})

  @doc "Ids of all live colony regions."
  def list, do: Registry.select(Convoy.Engine.ColonyRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @doc "Stop a region's process (it snapshots on the way out, so it resumes when next opened)."
  def stop(id) do
    case Registry.lookup(Convoy.Engine.ColonyRegistry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Convoy.Engine.RegionSupervisor, pid)
      [] -> :ok
    end
  end

  @doc "Stop a region and delete its snapshot for good."
  def delete(id) do
    stop(id)
    Persistence.delete(id)
  end

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
    # trap exits so terminate/2 runs on supervisor shutdown → we snapshot on the
    # way out (a deploy/restart resumes the colonies where they left off).
    Process.flag(:trap_exit, true)

    state = %{
      id: Keyword.fetch!(opts, :id),
      seed: Keyword.get(opts, :seed, 1),
      colonies: %{},
      brains: %{},
      market: Market.new(@width, @height),
      status: :running,
      tick: 0,
      tick_ms: Keyword.get(opts, :tick_ms, @default_ms),
      last_fuel: %{},
      history: %{},
      observers: MapSet.new()
    }

    # Restore a persisted snapshot if one exists; otherwise seed the bundled bot
    # colonies (every region gets `demo`; `main` also gets `shipper` + `builder`).
    {:ok, schedule(restore_or_seed(state))}
  end

  @impl true
  def terminate(_reason, state), do: persist(state)

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:submit, player, exec, display}, _from, state) do
    case ColonyWasm.instantiate(exec) do
      {:ok, inst} ->
        ColonyWasm.stop(get_in(state.brains, [player, :inst]))
        state =
          state
          |> ensure_colony(player)
          |> put_in([Access.key(:brains), player], %{inst: inst, exec: exec, display: display, error: nil})
          |> Map.put(:status, :running)
          |> persist()

        broadcast(state)
        {:reply, :ok, schedule(state)}

      {:error, msg} ->
        state = update_in(state.brains, &Map.put(&1, player, %{inst: nil, exec: exec, display: display, error: msg}))
        broadcast(state)
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:kick, player}, _from, state) do
    ColonyWasm.stop(get_in(state.brains, [player, :inst]))

    state =
      state
      |> update_in([Access.key(:colonies)], &Map.delete(&1, player))
      |> update_in([Access.key(:brains)], &Map.delete(&1, player))
      |> update_in([Access.key(:last_fuel)], &Map.delete(&1, player))
      |> update_in([Access.key(:history)], &Map.delete(&1, player))
      |> update_in([Access.key(:market)], &Market.drop_owner(&1, player))
      |> persist()

    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:play, state), do: {:noreply, schedule(%{state | status: :running})}
  def handle_cast(:pause, state), do: {:noreply, %{state | status: :paused}}
  def handle_cast(:step, state), do: {:noreply, broadcast(advance(state))}
  def handle_cast({:set_speed, ms}, state), do: {:noreply, %{state | tick_ms: clamp_ms(ms)}}

  def handle_cast({:reset, seed}, state) do
    # regenerate every player's colony + a fresh market, keep their brains
    colonies = Map.new(state.colonies, fn {p, _} -> {p, World.generate(seed: colony_seed(seed, p))} end)
    state = %{state | seed: seed, colonies: colonies, market: Market.new(@width, @height), tick: 0, history: %{}}
    {:noreply, broadcast(persist(state))}
  end

  def handle_cast({:observe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | observers: MapSet.put(state.observers, pid)}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if state.status == :running, do: advance(state), else: state
    {:noreply, schedule(broadcast(maybe_persist(state)))}
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
    |> record_history()
  rescue
    _ -> state
  end

  # Append a metrics sample for every colony every @history_every ticks. Stored
  # newest-first, trimmed to @history_max — bounded memory, snapshot-friendly.
  defp record_history(%{tick: t} = state) when rem(t, @history_every) == 0 do
    history =
      Enum.reduce(state.colonies, state.history, fn {p, w}, acc ->
        point = %{
          t: t,
          credits: w.credits,
          refined: w.refined_total,
          pop: World.population(w),
          convoys: length(Market.convoys_of(state.market, p))
        }

        series = [point | Map.get(acc, p, [])] |> Enum.take(@history_max)
        Map.put(acc, p, series)
      end)

    %{state | history: history}
  end

  defp record_history(state), do: state

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
          cmd.op == @op_hunt and MapSet.member?(own_ids, cmd.target) -> {cc, Map.put(ci, cmd.target, hunt_intent(cmd))}
          cmd.op == @op_move and MapSet.member?(own_ids, cmd.target) -> {cc, Map.put(ci, cmd.target, {:move, {cmd.a, cmd.b}})}
          Market.convoy_id?(cmd.target) -> {cc, ci}
          true -> {[cmd | cc], ci}
        end
      end)

    {Enum.reverse(colony), convoy}
  end

  # hunt(convoy, dx, dy): a nonzero direction steers the raider (intercept where the
  # shipment will be); dx=dy=0 auto-homes onto the nearest enemy (legacy behavior).
  defp hunt_intent(%{a: 0, b: 0}), do: {:hunt}
  defp hunt_intent(%{a: dx, b: dy}), do: {:hunt, {dx, dy}}

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
      |> put_in([Access.key(:brains), name], %{inst: inst, exec: bytes, display: display, error: nil})
    else
      _ -> state
    end
  end

  # --- persistence (snapshot + restore across restarts/deploys) ---

  defp restore_or_seed(state) do
    case Persistence.load(state.id) do
      {:ok, snap} -> rebuild(state, snap)
      :error -> seed_residents(state)
    end
  rescue
    _ -> seed_residents(state)
  end

  # Rebuild a region from a snapshot: restore the colonies + market + tick, and
  # re-instantiate each player's brain from its stored bytes + memory. A snapshot
  # whose struct shape doesn't match the current code is discarded (fresh seed).
  defp rebuild(state, snap) do
    if valid_snapshot?(snap) do
      colonies = Map.new(snap.colonies, fn {p, w} -> {p, World.ensure_config(w)} end)
      brains = Map.new(snap.players, fn {p, pl} -> {p, reinstantiate(pl)} end)

      %{
        state
        | seed: snap.seed,
          tick: snap.tick,
          tick_ms: Map.get(snap, :tick_ms, @default_ms),
          status: snap.status,
          colonies: colonies,
          market: snap.market,
          history: Map.get(snap, :history, %{}),
          brains: brains
      }
    else
      seed_residents(state)
    end
  end

  defp reinstantiate(%{exec: exec} = pl) when is_binary(exec) do
    case ColonyWasm.instantiate(exec) do
      {:ok, inst} ->
        ColonyWasm.restore_memory(inst, pl[:memory])
        %{inst: inst, exec: exec, display: pl[:display], error: nil}

      {:error, msg} ->
        %{inst: nil, exec: exec, display: pl[:display], error: msg}
    end
  end

  defp reinstantiate(pl), do: %{inst: nil, exec: nil, display: pl[:display], error: pl[:error]}

  defp valid_snapshot?(snap) do
    is_map(Map.get(snap, :colonies)) and match?(%Market{}, Map.get(snap, :market)) and
      same_shape?(snap.market, %Market{}) and
      Enum.all?(Map.values(snap.colonies), fn w -> match?(%World{}, w) and same_shape?(w, %World{}) end)
  rescue
    _ -> false
  end

  defp same_shape?(a, b), do: Map.keys(a) == Map.keys(b)

  # Snapshot every @snapshot_every ticks (cheap insurance between event-driven saves).
  defp maybe_persist(%{tick: t} = state) when rem(t, @snapshot_every) == 0, do: persist(state)
  defp maybe_persist(state), do: state

  defp persist(state) do
    players =
      Map.new(state.brains, fn {p, b} ->
        {p, %{exec: b[:exec], display: b[:display], error: b[:error], memory: ColonyWasm.snapshot_memory(b[:inst])}}
      end)

    Persistence.save(%{
      region_id: state.id,
      seed: state.seed,
      tick: state.tick,
      tick_ms: state.tick_ms,
      status: state.status,
      colonies: state.colonies,
      market: state.market,
      history: state.history,
      players: players
    })

    state
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
      history: state.history,
      last_fuel: state.last_fuel |> Map.values() |> Enum.sum()
    }
  end

  defp clamp_ms(ms) when ms < 50, do: 50
  defp clamp_ms(ms) when ms > 2000, do: 2000
  defp clamp_ms(ms), do: ms
end
