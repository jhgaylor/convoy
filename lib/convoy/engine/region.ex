defmodule Convoy.Engine.Region do
  @moduledoc """
  A GenServer that is the single authoritative owner of one region's state
  and tick loop (primer §4, §9). Single-writer semantics fall out of the
  process model for free.

  The region advances autonomously on a timer when running, independent of
  whether anyone is watching — a small taste of the primer's "continuous
  liveness" goal (§2). State changes are broadcast over `Phoenix.PubSub` so
  any number of LiveView clients can observe without owning the state.

  A region runs player code through one of two backends, chosen per program:

  - `:rules` — the sandboxed rule DSL (`Convoy.Engine.Program`).
  - `:wasm`  — untrusted WebAssembly with fuel metering (`Convoy.Engine.Wasm`,
    primer §7). Each entity's `decide` call runs under a per-tick fuel budget;
    traps are contained and reported, never crash the region.

  ## Persistence (primer §8)

  A `:persist` region snapshots its full state durably (periodically, on code
  load, on reset, and on shutdown) and restores it on start. That's the
  freeze/thaw guarantee: a code deploy restarts the process, the new version
  loads the snapshot, and the simulation resumes at the exact tick it stopped —
  still running whatever program was loaded. The live WASM instance can't be
  serialized, so we persist the program *bytes* and re-instantiate on restore.

  Commands: `load_program/4`, `play/1`, `pause/1`, `step/1`, `reset/2`,
  `set_speed/2`.
  """

  use GenServer
  require Logger

  alias Convoy.Engine.{World, Program, Wasm, Sim}
  alias Convoy.Persistence

  @default_tick_ms 400
  # Per-entity, per-tick fuel budget (primer §7, §12 — a key tuning knob).
  # Generous enough for real logic; an infinite loop still exhausts it fast.
  @default_fuel_budget 50_000
  # Snapshot durably every N ticks while running (bounds loss on a hard crash;
  # graceful shutdown also snapshots). ~20s at the default tick rate.
  @snapshot_every 50
  # Bump when the persisted shape changes; older snapshots are discarded
  # (fresh start) rather than crashing the new code.
  @snapshot_version 1

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :world,
      :backend,
      :rules,
      :wasm,
      :source,
      :exec,
      :status,
      :tick_ms,
      :timer,
      :fuel_budget,
      :last_fuel,
      :compile_error,
      :persist
    ]
  end

  # --- client API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Convoy.Engine.RegionRegistry, id}}

  def topic(id), do: "region:#{id}"

  @doc "Current world + status, for a freshly-mounted observer."
  def snapshot(id), do: GenServer.call(via(id), :snapshot)

  @doc """
  Load a program for a backend (`:rules` or `:wasm`).

  `exec` is what actually runs: rule-DSL text for `:rules`, or WAT text / raw
  `.wasm` bytes for `:wasm`. `display` is the human-facing source shown in the
  editor and broadcast to observers — kept separate so we never push megabytes
  of binary (or a compiled blob) through PubSub when the player wrote Rust. The
  `exec` is also what gets persisted so the program can be re-instantiated on
  restore. A failed load leaves the previously-loaded program running and
  reports the error. Returns `:ok` or `{:error, msg}`.
  """
  def load_program(id, backend, exec, display \\ nil),
    do: GenServer.call(via(id), {:load_program, backend, exec, display || exec})

  def play(id), do: GenServer.cast(via(id), :play)
  def pause(id), do: GenServer.cast(via(id), :pause)
  def step(id), do: GenServer.cast(via(id), :step)
  def reset(id, seed), do: GenServer.cast(via(id), {:reset, seed})
  def set_speed(id, tick_ms), do: GenServer.cast(via(id), {:set_speed, tick_ms})

  # --- server ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    seed = Keyword.get(opts, :seed, 1)
    persist = Keyword.get(opts, :persist, false)

    state =
      id
      |> default_state(seed, persist)
      |> maybe_restore()

    # Resume ticking if we restored a region that was running.
    state = if state.status == :running, do: schedule_tick(state), else: state
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist_now(state)
    Wasm.stop(state.wasm)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:load_program, backend, exec, display}, _from, state) do
    case load(backend, exec, display, state) do
      {:ok, state} ->
        persist_now(state)
        broadcast(state)
        {:reply, :ok, state}

      {:error, msg, state} ->
        broadcast(state)
        {:reply, {:error, msg}, state}
    end
  end

  @impl true
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
    world = World.generate(seed: seed, region_id: state.id)
    state = %{state | world: world, status: :paused, last_fuel: 0}
    # A reset is a deliberate fresh start — persist it so the deploy resumes
    # from the reset world, not the pre-reset one.
    persist_now(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:set_speed, tick_ms}, state) do
    state = %{state | tick_ms: tick_ms}
    state = if state.status == :running, do: state |> cancel_timer() |> schedule_tick(), else: state
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

  # --- initial state + restore ---

  defp default_state(id, seed, persist) do
    source = Program.default_source()
    {:ok, rules} = Program.compile(source)

    %State{
      id: id,
      world: World.generate(seed: seed, region_id: id),
      backend: :rules,
      rules: rules,
      wasm: nil,
      source: source,
      exec: source,
      status: :paused,
      tick_ms: @default_tick_ms,
      timer: nil,
      fuel_budget: @default_fuel_budget,
      last_fuel: 0,
      compile_error: nil,
      persist: persist
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

  # Only restore a snapshot whose shape matches the current code (same version
  # and same World field set), so a deploy that changes the schema starts fresh
  # instead of crashing on a stale struct.
  defp valid_snapshot?(%{version: @snapshot_version, world: %World{} = world}) do
    Map.keys(world) == Map.keys(%World{})
  end

  defp valid_snapshot?(_), do: false

  defp restore(state, snap) do
    restored = %{
      state
      | world: snap.world,
        backend: snap.backend,
        exec: snap.exec,
        source: snap.display,
        tick_ms: snap.tick_ms,
        fuel_budget: snap.fuel_budget,
        status: snap.status,
        last_fuel: 0,
        compile_error: nil
    }

    reinstantiate(restored)
  end

  # Rebuild the live program from the persisted bytes.
  defp reinstantiate(%{backend: :rules, exec: exec} = state) do
    case Program.compile(exec) do
      {:ok, rules} -> %{state | rules: rules, wasm: nil}
      {:error, msg} -> %{state | status: :paused, compile_error: msg}
    end
  end

  defp reinstantiate(%{backend: :wasm, exec: exec} = state) do
    case Wasm.instantiate(exec) do
      {:ok, instance} -> %{state | wasm: instance}
      {:error, msg} -> %{state | status: :paused, wasm: nil, compile_error: msg}
    end
  end

  # --- program loading ---

  defp load(:rules, exec, display, state) do
    case Program.compile(exec) do
      {:ok, rules} ->
        Wasm.stop(state.wasm)

        {:ok,
         %{state | backend: :rules, rules: rules, wasm: nil, source: display, exec: exec, compile_error: nil}}

      {:error, msg} ->
        # Keep the previously-loaded program running; just surface the error.
        {:error, msg, %{state | source: display, compile_error: msg}}
    end
  end

  defp load(:wasm, exec, display, state) do
    case Wasm.instantiate(exec) do
      {:ok, instance} ->
        # Retire the old instance only once the new one is live.
        Wasm.stop(state.wasm)

        {:ok,
         %{state | backend: :wasm, wasm: instance, source: display, exec: exec, compile_error: nil}}

      {:error, msg} ->
        {:error, msg, %{state | source: display, compile_error: msg}}
    end
  end

  # --- ticking ---

  # WASM backend: run each entity's module under the fuel budget, summing the
  # fuel consumed this tick. Intents are resolved by the same authoritative Sim.
  defp advance(%{backend: :wasm, wasm: inst} = state) when not is_nil(inst) do
    world = state.world

    {intents, fuel} =
      world.entities
      |> Enum.sort_by(& &1.id)
      |> Enum.map_reduce(0, fn e, acc ->
        {:ok, intent, used} = Wasm.decide(inst, e, world, state.fuel_budget)
        {{e.id, intent}, acc + used}
      end)

    %{state | world: Sim.apply_intents(world, intents), last_fuel: fuel}
  end

  # WASM selected but no valid instance (compile error): hold position.
  defp advance(%{backend: :wasm} = state), do: state

  # Rules backend: the pure tick loop. No fuel concept.
  defp advance(state) do
    %{state | world: Sim.tick(state.world, state.rules), last_fuel: 0}
  end

  defp schedule_tick(state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  # --- persistence ---

  defp maybe_persist(%{persist: true} = state) do
    if rem(state.world.tick, @snapshot_every) == 0, do: persist_now(state)
  end

  defp maybe_persist(_state), do: :ok

  defp persist_now(%{persist: true} = state), do: Persistence.save(state.id, snapshot_map(state))
  defp persist_now(_state), do: :ok

  defp snapshot_map(state) do
    %{
      version: @snapshot_version,
      region_id: state.id,
      world: state.world,
      backend: state.backend,
      exec: state.exec,
      display: state.source,
      tick_ms: state.tick_ms,
      fuel_budget: state.fuel_budget,
      status: state.status
    }
  end

  # --- broadcast / view ---

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Convoy.PubSub, topic(state.id), {:region_update, public(state)})
  end

  defp public(state) do
    %{
      id: state.id,
      world: state.world,
      backend: state.backend,
      status: state.status,
      source: state.source,
      tick_ms: state.tick_ms,
      fuel_budget: state.fuel_budget,
      last_fuel: state.last_fuel,
      compile_error: state.compile_error
    }
  end
end
