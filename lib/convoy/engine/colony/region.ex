defmodule Convoy.Engine.Colony.Region do
  @moduledoc """
  A single-writer process owning one **colony** (Forge & Convoy v2). The v2
  counterpart to `Convoy.Engine.Region`: it advances a `Colony.World` on a timer,
  drives it with one colony brain per tick (`ColonyWasm.tick`), and broadcasts
  snapshots to spectators over PubSub. Single-writer falls out of the GenServer
  (primer §4, §9).

  Additive: keyed `{:colony, id}` in the shared `RegionRegistry`, started under
  the shared `RegionSupervisor`, so it lives alongside the v1 game without
  touching it. No disk persistence yet (in-memory world) — a later chunk, like
  the shared market + multiplayer.
  """
  use GenServer

  alias Convoy.Engine.Colony.{World, Sim}
  alias Convoy.Engine.ColonyWasm

  # Default per-tick colony-wide fuel budget (one brain call per tick).
  @fuel 5_000_000
  @default_ms 400

  # --- client API ---

  def ensure(id, opts \\ []) do
    spec = %{id: {:colony, id}, start: {__MODULE__, :start_link, [[{:id, id} | opts]]}, restart: :transient}

    case DynamicSupervisor.start_child(Convoy.Engine.RegionSupervisor, spec) do
      {:ok, _} -> id
      {:error, {:already_started, _}} -> id
    end
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  defp via(id), do: {:via, Registry, {Convoy.Engine.ColonyRegistry, id}}

  def topic(id), do: "colony:#{id}"
  def snapshot(id), do: call(id, :snapshot)
  def play(id), do: cast(id, :play)
  def pause(id), do: cast(id, :pause)
  def step(id), do: cast(id, :step)
  def set_speed(id, ms), do: cast(id, {:set_speed, ms})
  def reset(id, seed), do: cast(id, {:reset, seed})
  def observe(id, pid), do: cast(id, {:observe, pid})

  @doc "Load a compiled colony module (wasm/wat bytes) as this colony's brain."
  def submit_bot(id, exec, display), do: call(id, {:submit_bot, exec, display})

  defp call(id, msg), do: GenServer.call(via(id), msg)
  defp cast(id, msg), do: GenServer.cast(via(id), msg)

  # --- server ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    seed = Keyword.get(opts, :seed, 1)
    world = World.generate(seed: seed)

    state = %{
      id: id,
      world: world,
      inst: nil,
      bot_display: nil,
      status: :running,
      tick_ms: Keyword.get(opts, :tick_ms, @default_ms),
      last_fuel: 0,
      last_error: nil,
      observers: MapSet.new()
    }

    # Try to load the bundled default bot so the page runs out of the box.
    state = maybe_load_default(state)
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:submit_bot, exec, display}, _from, state) do
    case ColonyWasm.instantiate(exec) do
      {:ok, inst} ->
        ColonyWasm.stop(state.inst)
        state = %{state | inst: inst, bot_display: display, last_error: nil, status: :running}
        broadcast(state)
        {:reply, :ok, schedule(state)}

      {:error, msg} ->
        state = %{state | last_error: msg}
        broadcast(state)
        {:reply, {:error, msg}, state}
    end
  end

  @impl true
  def handle_cast(:play, state), do: {:noreply, schedule(%{state | status: :running})}
  def handle_cast(:pause, state), do: {:noreply, %{state | status: :paused}}

  def handle_cast(:step, state) do
    state = advance(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:set_speed, ms}, state), do: {:noreply, %{state | tick_ms: clamp_ms(ms)}}

  def handle_cast({:reset, seed}, state) do
    state = %{state | world: World.generate(seed: seed)}
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:observe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | observers: MapSet.put(state.observers, pid)}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if state.status == :running, do: advance(state), else: state
    broadcast(state)
    {:noreply, schedule(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, %{state | observers: MapSet.delete(state.observers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internals ---

  # Advance one tick: run the brain (if loaded), resolve its commands, refine, etc.
  # Wrapped so a transient error (e.g. a module purge during dev hot-reload, or an
  # unexpected host fault) skips the tick instead of taking the region down.
  defp advance(%{inst: nil} = state) do
    %{state | world: Sim.apply_commands(state.world, [])}
  rescue
    _ -> state
  end

  defp advance(%{inst: inst} = state) do
    {:ok, cmds, used} = ColonyWasm.tick(inst, World.to_view(state.world), @fuel)
    %{state | world: Sim.apply_commands(state.world, cmds), last_fuel: used}
  rescue
    _ -> state
  end

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
    w = state.world

    %{
      region_id: state.id,
      world: w,
      status: state.status,
      tick_ms: state.tick_ms,
      has_bot: state.inst != nil,
      bot_display: state.bot_display,
      last_fuel: state.last_fuel,
      last_error: state.last_error,
      pop: World.population(w),
      pop_cap: World.pop_cap(w),
      storage_cap: World.storage_cap(w),
      ore_remaining: World.ore_remaining(w)
    }
  end

  # Best-effort load of priv/colony/default.wasm so a fresh region demos itself.
  defp maybe_load_default(state) do
    path = Path.join(:code.priv_dir(:convoy), "colony/default.wasm")

    with true <- File.exists?(path),
         {:ok, bytes} <- File.read(path),
         {:ok, inst} <- ColonyWasm.instantiate(bytes) do
      %{state | inst: inst, bot_display: "default colony bot (examples/colony.rs)"}
    else
      _ -> state
    end
  end

  defp clamp_ms(ms) when ms < 50, do: 50
  defp clamp_ms(ms) when ms > 2000, do: 2000
  defp clamp_ms(ms), do: ms
end
