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

  Commands: `load_program/3`, `play/1`, `pause/1`, `step/1`, `reset/2`,
  `set_speed/2`.
  """

  use GenServer

  alias Convoy.Engine.{World, Program, Wasm, Sim}

  @default_tick_ms 400
  # Per-entity, per-tick fuel budget (primer §7, §12 — a key tuning knob).
  # Generous enough for real logic; an infinite loop still exhausts it fast.
  @default_fuel_budget 50_000

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :world,
      :backend,
      :rules,
      :wasm,
      :source,
      :status,
      :tick_ms,
      :timer,
      :fuel_budget,
      :last_fuel,
      :compile_error
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
  of binary (or a compiled blob) through PubSub when the player wrote Rust.
  Returns `:ok` or `{:error, msg}`.
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
    source = Program.default_source()
    {:ok, rules} = Program.compile(source)

    state = %State{
      id: id,
      world: World.generate(seed: seed, region_id: id),
      backend: :rules,
      rules: rules,
      wasm: nil,
      source: source,
      status: :paused,
      tick_ms: @default_tick_ms,
      timer: nil,
      fuel_budget: @default_fuel_budget,
      last_fuel: 0,
      compile_error: nil
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state), do: Wasm.stop(state.wasm)

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:load_program, backend, exec, display}, _from, state) do
    case load(backend, exec, display, state) do
      {:ok, state} ->
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
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:pause, state) do
    state = %{cancel_timer(state) | status: :paused}
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
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  # --- program loading ---

  defp load(:rules, exec, display, state) do
    case Program.compile(exec) do
      {:ok, rules} ->
        # Switching away from WASM: free its instance.
        Wasm.stop(state.wasm)
        {:ok, %{state | backend: :rules, rules: rules, wasm: nil, source: display, compile_error: nil}}

      {:error, msg} ->
        {:error, msg, %{state | backend: :rules, source: display, compile_error: msg}}
    end
  end

  defp load(:wasm, exec, display, state) do
    # Always retire the previous instance before standing up the new one.
    Wasm.stop(state.wasm)

    case Wasm.instantiate(exec) do
      {:ok, instance} ->
        {:ok, %{state | backend: :wasm, wasm: instance, source: display, compile_error: nil}}

      {:error, msg} ->
        {:error, msg, %{state | backend: :wasm, wasm: nil, source: display, compile_error: msg}}
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
