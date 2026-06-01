defmodule Convoy.Engine.Region do
  @moduledoc """
  A GenServer that is the single authoritative owner of one region's state
  and tick loop (primer §4, §9). Single-writer semantics fall out of the
  process model for free.

  ## Multiplayer

  A region is a **shared world** with multiple players. Each player submits
  their own program and owns a set of harvesters; the tick loop runs each
  entity's *owner's* program to collect that entity's intent, then resolves all
  intents authoritatively in entity-id order — so two players' harvesters
  competing for the same ore are arbitrated fairly (single-writer). Scoring is
  per-player (`World.scoreboard/1`, from each player's base).

  Players join via `submit_player/5` (the CLI / HTTP API / browser upload). Each
  player's program is untrusted WebAssembly run with fuel metering
  (`Convoy.Engine.Wasm`, primer §7) — a per-player fuel budget, traps contained.
  Any language (Rust, Go, AssemblyScript, Zig, C, hand-written WAT) compiles to it.

  ## Persistence (primer §8)

  A `:persist` region snapshots its full state — world plus every player's
  program *bytes* — and restores it on start, re-instantiating each player's
  module. A code deploy resumes the shared game at the tick it stopped.

  Commands: `submit_player/5`, `load_program/4` (→ editor player), `play/1`,
  `pause/1`, `step/1`, `reset/2`, `set_speed/2`.
  """

  use GenServer
  require Logger

  alias Convoy.Engine.{World, Wasm, Sim}
  alias Convoy.Persistence

  @default_tick_ms 400
  @snapshot_every 50
  # Bumped to 6: per-player private harvesting rooms + a shared market room —
  # the world dropped the single shared `resources` map for a `rooms` map and
  # gained `market_entry`, and entities carry a `room`. v5 = cross-region
  # border-crossing fields; v4 = player Memory; v3 = the Forge bases shape.
  @snapshot_version 6

  # Scale-to-zero activation (primer §5). A running region with no spectators is
  # **warm**: it still advances (it's a persistent world) but ticks much more
  # slowly, so most of the map — idle at any moment — costs a fraction of the
  # compute. A spectator connecting snaps it back to **hot** (full rate). Cold
  # (process killed, state in the snapshot) is the existing admin Stop.
  @warm_factor 8

  defmodule State do
    @moduledoc false
    # players: %{player_id => player()} where player is the map built by player/4.
    # observers: MapSet of monitor refs for connected spectators (drives hot/warm).
    defstruct [
      :id,
      :world,
      :players,
      :status,
      :tick_ms,
      :timer,
      :last_fuel,
      :persist,
      :observers
    ]
  end

  # --- client API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Convoy.Engine.RegionRegistry, id}}

  def topic(id), do: "region:#{id}"

  @doc "Current world + per-player state, for a freshly-mounted observer."
  def snapshot(id), do: GenServer.call(via(id), :snapshot)

  @doc """
  Operational stats for the admin/overview page: world summary plus this
  region's resource use (the region process *and* its players' WASM instance
  processes). `reductions` is cumulative — the caller diffs it for a rate.
  """
  def stats(id), do: GenServer.call(via(id), :stats)

  @doc """
  Submit (add or replace) a player's program. A new player joins the shared
  world with their own harvesters; an existing player swaps program and keeps
  their entities. `exec` is rule text / WAT / wasm bytes; `display` is the
  human-facing source. Returns `:ok` or `{:error, msg}`.
  """
  def submit_player(id, player_id, backend, exec, display \\ nil),
    do: GenServer.call(via(id), {:submit, player_id, backend, exec, display || exec})

  @doc "Load a program for the editor player (\"p1\"). See `submit_player/5`."
  def load_program(id, backend, exec, display \\ nil),
    do: submit_player(id, World.default_player(), backend, exec, display)

  @doc "Remove a player from the region — stops their program, drops their harvesters and score."
  def kick_player(id, player_id), do: GenServer.call(via(id), {:kick, player_id})

  @doc """
  Register `pid` as a live spectator of this region (primer §5). The region
  monitors it and ticks at full **hot** rate while at least one observer is
  connected, dropping to the slow **warm** rate when the last one leaves.
  """
  def observe(id, pid), do: GenServer.cast(via(id), {:observe, pid})

  @doc "Deliver a convoy that crossed in from another region (primer §4)."
  def receive_convoy(id, convoy), do: GenServer.cast(via(id), {:receive_convoy, convoy})

  @doc "Credit a player here for a shipment that sold in another region (credit-back, §4)."
  def credit(id, owner, amount), do: GenServer.cast(via(id), {:credit, owner, amount})

  def play(id), do: GenServer.cast(via(id), :play)
  def pause(id), do: GenServer.cast(via(id), :pause)
  def step(id), do: GenServer.cast(via(id), :step)
  def reset(id, seed), do: GenServer.cast(via(id), {:reset, seed})
  def set_speed(id, tick_ms), do: GenServer.cast(via(id), {:set_speed, tick_ms})

  # --- server ---

  @impl true
  def init(opts) do
    # Trap exits so a supervisor-initiated shutdown (admin Stop, or app shutdown
    # on deploy) runs terminate/2 and writes a final snapshot — without this,
    # exit(:shutdown) kills the process before it can persist.
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    seed = Keyword.get(opts, :seed, 1)
    persist = Keyword.get(opts, :persist, false)
    neighbor = Keyword.get(opts, :neighbor)

    state =
      id
      |> default_state(seed, persist, neighbor)
      |> maybe_restore()

    state = if state.status == :running, do: schedule_tick(state), else: state
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist_now(state)
    Enum.each(state.players, fn {_id, p} -> Wasm.stop(p.wasm) end)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call(:stats, _from, state), do: {:reply, stats(self(), state), state}

  def handle_call({:submit, player_id, backend, exec, display}, _from, state) do
    case build_player(player_id, backend, exec, display) do
      {:ok, player} ->
        state = put_player(state, player_id, player)

        Convoy.EventLog.append(state.id, state.world.tick, :submit, %{
          player: player_id,
          backend: backend
        })

        persist_now(state)
        broadcast(state)
        {:reply, :ok, state}

      {:error, msg} ->
        # Keep any existing program for this player running; just report.
        state = mark_error(state, player_id, msg)
        broadcast(state)
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:kick, player_id}, _from, state) do
    case Map.pop(state.players, player_id) do
      {nil, _players} ->
        {:reply, {:error, :not_found}, state}

      {player, players} ->
        Wasm.stop(player.wasm)
        state = %{state | players: players, world: World.remove_player(state.world, player_id)}
        Convoy.EventLog.append(state.id, state.world.tick, :kick, %{player: player_id})
        persist_now(state)
        broadcast(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:observe, pid}, state) do
    was_idle = MapSet.size(state.observers) == 0
    ref = Process.monitor(pid)
    state = %{state | observers: MapSet.put(state.observers, ref)}
    # First spectator on a running region: snap warm -> hot (reschedule faster).
    state = if was_idle, do: reschedule(state), else: state
    {:noreply, state}
  end

  # A convoy crossed in from another region (primer §4, phase 2 of the handoff).
  def handle_cast({:receive_convoy, convoy}, state) do
    world = World.receive_convoy(state.world, convoy)
    state = %{state | world: world}

    Convoy.EventLog.append(state.id, world.tick, :arrival, %{
      player: convoy.owner,
      cargo: convoy.cargo,
      from: convoy.origin_region
    })

    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  # A shipment that originated here sold in another region — credit it back.
  def handle_cast({:credit, owner, amount}, state) do
    state = %{state | world: World.credit_market(state.world, owner, amount)}
    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:play, %{status: :running} = state), do: {:noreply, state}

  def handle_cast(:play, state) do
    state = %{state | status: :running} |> schedule_tick()
    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:pause, state) do
    state = %{cancel_timer(state) | status: :paused}
    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:step, state) do
    state = state |> cancel_timer() |> Map.put(:status, :paused) |> advance()
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:reset, seed}, state) do
    state = cancel_timer(state)
    # Fresh world, but keep the players and re-add their harvesters.
    world = rebuild_world(seed, state)
    state = %{state | world: world, status: :paused, last_fuel: 0}
    Convoy.EventLog.append(state.id, 0, :reset, %{seed: seed})
    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:set_speed, tick_ms}, state) do
    state = %{state | tick_ms: tick_ms}

    state =
      if state.status == :running, do: state |> cancel_timer() |> schedule_tick(), else: state

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, %{status: :running} = state) do
    state = state |> advance() |> schedule_tick()
    maybe_persist(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  # A spectator's LiveView process went away. Drop it; if it was the last one,
  # the region falls back to the slow warm tick rate (primer §5).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    observers = MapSet.delete(state.observers, ref)
    became_idle = MapSet.size(observers) == 0 and MapSet.size(state.observers) > 0
    state = %{state | observers: observers}
    state = if became_idle, do: reschedule(state), else: state
    {:noreply, state}
  end

  # Trapping exits surfaces stray {:EXIT, _, _} from any links as messages;
  # ignore them (the parent's shutdown is handled by GenServer → terminate/2).
  def handle_info(_msg, state), do: {:noreply, state}

  # --- players ---

  defp build_player(player_id, backend, exec, display) do
    case compile_program(backend, exec) do
      {:ok, runnable} ->
        {:ok,
         Map.merge(runnable, %{
           id: player_id,
           backend: backend,
           exec: exec,
           source: display,
           compile_error: nil
         })}

      {:error, msg} ->
        {:error, msg}
    end
  end

  # Instantiate the player's WASM module (everything compiles to wasm).
  defp compile_program(:wasm, exec) do
    case Wasm.instantiate(exec) do
      {:ok, instance} -> {:ok, %{wasm: instance}}
      {:error, _} = err -> err
    end
  end

  # Insert/replace a player; spawn entities for a new one; retire old wasm.
  defp put_player(state, player_id, player) do
    world =
      if Map.has_key?(state.players, player_id),
        do: state.world,
        else: World.add_player(state.world, player_id)

    if old = state.players[player_id], do: Wasm.stop(old.wasm)

    %{state | world: world, players: Map.put(state.players, player_id, player)}
  end

  defp mark_error(state, player_id, msg) do
    case state.players[player_id] do
      nil ->
        state

      player ->
        %{state | players: Map.put(state.players, player_id, %{player | compile_error: msg})}
    end
  end

  # --- ticking ---

  # Run each entity's owner program and resolve via the Sim. The fuel budget is
  # per-player and tech-driven (`World.fuel_budget/2`, primer §7) — derived from
  # world state, so it stays deterministic across replays.
  defp advance(state) do
    world = state.world

    {intents, fuel} =
      world.entities
      # Convoys are auto-piloted by the Sim — only harvesters run player code.
      |> Enum.filter(&(&1.kind == :harvester))
      |> Enum.sort_by(& &1.id)
      |> Enum.map_reduce(0, fn e, acc ->
        budget = World.fuel_budget(world, e.owner)
        {intent, used} = decide_for(state.players[e.owner], e, world, budget)
        {{e.id, intent}, acc + used}
      end)

    world = Sim.apply_intents(world, intents)
    # Drain this tick's cross-region outbox into casts to the neighbor / origin
    # regions (primer §4 border handoff + credit-back). Empty for a region with
    # no neighbor, so single-region play does no extra work.
    {departing, credits, world} = World.take_outbox(world)
    dispatch_outbox(departing, credits)
    %{state | world: world, last_fuel: fuel}
  end

  # Phase 2 of the handoff and the credit-back. Both are asynchronous casts —
  # never synchronous Region→Region calls — so regions can't deadlock on each
  # other. `ensure_region` brings a cold destination hot first.
  defp dispatch_outbox([], []), do: :ok

  defp dispatch_outbox(departing, credits) do
    Enum.each(departing, fn %{to: to, convoy: convoy} ->
      Convoy.Engine.ensure_region(to, persist: true)
      play(to)
      receive_convoy(to, convoy)
    end)

    Enum.each(credits, fn %{region: region, owner: owner, amount: amount} ->
      Convoy.Engine.ensure_region(region, persist: true)
      credit(region, owner, amount)
    end)
  end

  defp decide_for(%{wasm: inst}, e, world, budget) when not is_nil(inst) do
    {:ok, intent, used} = Wasm.decide(inst, e, world, budget)
    {intent, used}
  end

  # No program (player gone, or load failed): the entity idles.
  defp decide_for(_player, _e, _world, _budget), do: {:idle, 0}

  defp schedule_tick(state) do
    %{state | timer: Process.send_after(self(), :tick, tick_interval(state))}
  end

  # Cancel and re-arm the timer at the current activation rate (used when a
  # region crosses the hot/warm boundary as spectators come and go).
  defp reschedule(%{status: :running} = state), do: state |> cancel_timer() |> schedule_tick()
  defp reschedule(state), do: state

  # Full rate when watched; @warm_factor slower when no one is (primer §5).
  defp tick_interval(state) do
    if MapSet.size(state.observers) == 0, do: state.tick_ms * @warm_factor, else: state.tick_ms
  end

  # Hot (watched) / warm (running, unwatched) / the raw status otherwise.
  defp activation(%{status: :running} = state) do
    if MapSet.size(state.observers) == 0, do: :warm, else: :hot
  end

  defp activation(state), do: state.status

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  # --- initial state + restore ---

  # A fresh region has no players — it's an empty world waiting for submissions.
  defp default_state(id, seed, persist, neighbor) do
    %State{
      id: id,
      world: World.generate(seed: seed, region_id: id, neighbor: neighbor),
      players: %{},
      status: :paused,
      tick_ms: @default_tick_ms,
      timer: nil,
      last_fuel: 0,
      persist: persist,
      observers: MapSet.new()
    }
  end

  defp maybe_restore(%{persist: false} = state), do: state

  defp maybe_restore(state) do
    with {:ok, snap} <- Persistence.load(state.id),
         true <- valid_snapshot?(snap) do
      Logger.info("region #{state.id} resumed from snapshot at tick #{snap.world.tick}")
      restore(state, snap)
    else
      _ -> state
    end
  end

  defp valid_snapshot?(%{version: @snapshot_version, world: %World{} = world}) do
    Map.keys(world) == Map.keys(%World{})
  end

  defp valid_snapshot?(_), do: false

  defp restore(state, snap) do
    players =
      Map.new(snap.players, fn {pid, p} ->
        {pid, reinstantiate(pid, p)}
      end)

    %{
      state
      | world: snap.world,
        players: players,
        tick_ms: snap.tick_ms,
        status: snap.status,
        last_fuel: 0
    }
  end

  # Rebuild a player's live program from persisted bytes.
  defp reinstantiate(pid, %{backend: backend, exec: exec} = persisted) do
    base = %{
      id: pid,
      backend: backend,
      exec: exec,
      source: persisted.source,
      wasm: nil,
      compile_error: nil
    }

    case compile_program(backend, exec) do
      {:ok, runnable} ->
        merged = Map.merge(base, runnable)
        # Restore the bot's persisted Memory (primer §8) into the fresh instance,
        # so its scratch state survives the freeze/thaw (deploy, stop/resume).
        Wasm.restore_memory(merged.wasm, persisted[:memory])
        merged

      {:error, msg} ->
        %{base | compile_error: msg}
    end
  end

  defp rebuild_world(seed, state) do
    fresh = World.generate(seed: seed, region_id: state.id, neighbor: state.world.neighbor)
    # generate already seeded the default player; add the rest back.
    Enum.reduce(Map.keys(state.players), fresh, fn pid, world ->
      World.add_player(world, pid)
    end)
  end

  # --- persistence ---

  defp maybe_persist(%{persist: true} = state) do
    if rem(state.world.tick, @snapshot_every) == 0, do: persist_now(state)
  end

  defp maybe_persist(_state), do: :ok

  defp persist_now(%{persist: true} = state), do: Persistence.save(state.id, snapshot_map(state))
  defp persist_now(_state), do: :ok

  defp snapshot_map(state) do
    # Persist only the serializable bits of each player (not the live wasm pid).
    players =
      Map.new(state.players, fn {pid, p} ->
        # Capture the bot's linear memory so its persistent state (primer §8)
        # survives a freeze/thaw, not just live ticks.
        %{
          backend: p.backend,
          exec: p.exec,
          source: p.source,
          memory: Wasm.snapshot_memory(p.wasm)
        }
        |> then(&{pid, &1})
      end)

    %{
      version: @snapshot_version,
      region_id: state.id,
      world: state.world,
      players: players,
      tick_ms: state.tick_ms,
      status: state.status
    }
  end

  # --- broadcast / view ---

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Convoy.PubSub, topic(state.id), {:region_update, public(state)})
  end

  # The region is a spectator surface: it broadcasts the shared world + the
  # roster, not any one "editor" program. The browser holds its own draft and
  # submits as whatever player the user names.
  defp public(state) do
    %{
      id: state.id,
      world: state.world,
      status: state.status,
      activation: activation(state),
      tick_ms: state.tick_ms,
      last_fuel: state.last_fuel,
      fuel_budget: World.base_fuel_budget(),
      scores: World.scoreboard(state.world),
      bases: state.world.bases,
      players: player_summaries(state)
    }
  end

  defp player_summaries(state) do
    Map.new(state.players, fn {pid, p} ->
      {pid, %{backend: p.backend, compile_error: p.compile_error}}
    end)
  end

  # World summary + process-level resource use (this region + its wasm pids).
  defp stats(self_pid, state) do
    # player.wasm is the instance struct %{pid:, store:} (or nil) — we want the pid.
    wasm_pids =
      state.players
      |> Map.values()
      |> Enum.map(& &1.wasm)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.pid)

    {wasm_mem, wasm_red} =
      Enum.reduce(wasm_pids, {0, 0}, fn pid, {m, r} ->
        case Process.info(pid, [:memory, :reductions]) do
          [{:memory, mm}, {:reductions, rr}] -> {m + mm, r + rr}
          _ -> {m, r}
        end
      end)

    [{:memory, mem}, {:reductions, red}] = Process.info(self_pid, [:memory, :reductions])

    %{
      region_id: state.id,
      status: state.status,
      activation: activation(state),
      tick: state.world.tick,
      tick_ms: state.tick_ms,
      last_fuel: state.last_fuel,
      players: map_size(state.players),
      scores: World.scoreboard(state.world),
      entities: length(state.world.entities),
      ore_remaining: World.ore_remaining(state.world),
      delivered: World.total_refined(state.world),
      persist: state.persist,
      wasm_instances: length(wasm_pids),
      memory: mem + wasm_mem,
      reductions: red + wasm_red
    }
  end
end
