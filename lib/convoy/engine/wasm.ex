defmodule Convoy.Engine.Wasm do
  @moduledoc """
  The WASM execution tier (primer §7, §11).

  Player code is arbitrary WebAssembly, run through Wasmtime (via `wasmex`)
  with **fuel metering** — Wasmtime counts instructions, which is the right
  basis for fairness and bit-identical replays (§7). The host exposes a tiny,
  fixed ABI and *nothing else*: the module has zero ambient authority (no
  imports, no memory growth needed, no host calls). It can read the situation
  we hand it and return one intent code. That is the whole capability surface.

  ## ABI (host → guest → host)

  The host computes a read-only per-entity view and calls the module's
  exported `decide` function with these `i32` params, in order:

      decide(cargo, cargo_max, at_base, on_resource,
             res_dx, res_dy, base_dx, base_dy, tick) -> i32

  - `at_base`, `on_resource`: 0/1 flags
  - `res_dx`/`res_dy`: sign (-1/0/1) of the step toward the nearest ore
  - `base_dx`/`base_dy`: sign of the step toward base

  The returned `i32` is an **intent code** the host resolves authoritatively
  (the player can never mutate the world — primer §3):

  | code | intent |
  |------|--------|
  | 1 | harvest |
  | 2 | unload |
  | 3 | move toward base |
  | 4 | move toward nearest resource |
  | 5 | wander (deterministic) |
  | 6 | move toward the resource farthest from base |
  | 10/11/12/13 | move +x / -x / +y / -y |
  | anything else (incl. 0) | idle |

  ## Failure isolation

  Fuel exhaustion (e.g. an infinite loop) traps; `wasmex` surfaces the trap as
  an `{:error, _}` tuple rather than crashing the BEAM scheduler. `decide/4`
  catches every failure and degrades that entity to `:idle` for the tick, so a
  misbehaving program wastes its own turn and nothing more.

  Fuel bounds CPU; `Wasmex.StoreLimits` bounds allocation (linear memory,
  tables, instances). A module that declares or grows memory past the cap is
  rejected at instantiation or denied the growth, instead of OOMing the node.
  Together these are the in-BEAM isolation layer. OS-level isolation
  (gVisor/Firecracker, separate process for NIF-crash blast radius) from §7
  is the *next* layer and is genuinely a higher-level (infra) concern.
  """

  alias Wasmex.{Engine, EngineConfig, Store, StoreLimits, Module, StoreOrCaller}
  alias Convoy.Engine.World

  @type instance :: %{pid: pid(), store: Wasmex.StoreOrCaller.t()}

  # Per-store resource caps (the in-app memory-isolation layer, alongside fuel).
  # Fuel bounds CPU; these bound allocation. A module that declares or grows
  # past these is rejected/denied rather than OOMing the BEAM node. Generous
  # for a decision function (which needs ~one page), fatal to a memory bomb.
  @store_limits %StoreLimits{
    memory_size: 16 * 1024 * 1024,
    table_elements: 100_000,
    memories: 1,
    tables: 4,
    instances: 4
  }

  @default_wat """
  ;; Default harvester — the rule-DSL behaviour, written in WebAssembly.
  ;; Compile your own (Rust, TinyGo, AssemblyScript, Zig, C, or WAT) to a `decide`
  ;; export with the ABI in the docs, and it runs under the same fuel budget.
  (module
    (func (export "decide")
      (param $cargo i32) (param $cargo_max i32)
      (param $at_base i32) (param $on_resource i32)
      (param $res_dx i32) (param $res_dy i32)
      (param $base_dx i32) (param $base_dy i32)
      (param $tick i32)
      (result i32)

      ;; can_unload: at base AND carrying cargo -> unload (2)
      (if (i32.and (local.get $at_base) (i32.gt_s (local.get $cargo) (i32.const 0)))
        (then (return (i32.const 2))))

      ;; cargo_full: cargo >= cargo_max -> head to base (3)
      (if (i32.ge_s (local.get $cargo) (local.get $cargo_max))
        (then (return (i32.const 3))))

      ;; on a resource -> harvest (1)
      (if (local.get $on_resource)
        (then (return (i32.const 1))))

      ;; otherwise -> seek the nearest resource (4)
      (i32.const 4)))
  """

  @doc "The starter WASM program (WAT text) shown in the editor."
  @spec default_source() :: String.t()
  def default_source, do: @default_wat

  @doc """
  Compile and instantiate a player module from WAT or `.wasm` bytes, with a
  fuel-metered engine and an empty import set.

  Returns `{:ok, instance}` or `{:error, message}` (compile/instantiation
  failures are caught and returned, never raised).
  """
  @spec instantiate(binary()) :: {:ok, instance()} | {:error, String.t()}
  def instantiate(source) when is_binary(source) do
    with {:ok, engine} <- Engine.new(%EngineConfig{consume_fuel: true}),
         {:ok, store} <- Store.new(@store_limits, engine),
         {:ok, module} <- Module.compile(store, source),
         {:ok, pid} <- start_instance(store, module),
         :ok <- assert_export(pid) do
      {:ok, %{pid: pid, store: store}}
    else
      {:error, reason} -> {:error, humanize(reason)}
    end
  rescue
    e -> {:error, humanize(Exception.message(e))}
  end

  @doc "Stop a running instance's process. Safe to call with nil."
  @spec stop(instance() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(%{pid: pid}), do: terminate(pid)

  # Start the wasmex GenServer under WasmSupervisor (temporary restart) rather
  # than linked to the caller. If instantiation crashes — e.g. a module whose
  # declared memory exceeds StoreLimits — the supervisor contains it and we get
  # {:error, reason} back, instead of the crash propagating to the region.
  defp start_instance(store, module) do
    spec = %{
      id: {:wasm, System.unique_integer([:positive])},
      start: {Wasmex, :start_link, [%{store: store, module: module}]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(Convoy.Engine.WasmSupervisor, spec)
  end

  defp terminate(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Convoy.Engine.WasmSupervisor, pid)
    end

    :ok
  end

  @doc """
  Run the player module for one entity under a fuel budget.

  Returns `{:ok, intent, fuel_used}`. On a trap, fuel exhaustion, or any other
  failure the entity is degraded to `:idle` and `fuel_used` is the full budget
  (the program spent its turn and got nothing for it).
  """
  @spec decide(instance(), World.entity(), World.t(), pos_integer()) ::
          {:ok, term(), non_neg_integer()}
  def decide(%{pid: pid, store: store}, entity, %World{} = world, fuel_budget) do
    args = build_view(entity, world)
    StoreOrCaller.set_fuel(store, fuel_budget)

    case Wasmex.call_function(pid, "decide", args) do
      {:ok, [code]} ->
        used = fuel_budget - remaining_fuel(store, 0)
        {:ok, code_to_intent(code, entity, world), used}

      {:error, _reason} ->
        # Trap / fuel exhaustion: contained, entity idles this tick.
        {:ok, :idle, fuel_budget}
    end
  end

  # --- host → guest view ---

  defp build_view(entity, world) do
    pos = {entity.x, entity.y}
    {bdx, bdy} = World.step_toward(pos, world.base)

    {rdx, rdy} =
      case World.nearest_resource(world, pos) do
        nil -> {0, 0}
        target -> World.step_toward(pos, target)
      end

    at_base = bool(pos == world.base)
    on_resource = bool(World.resource_at(world, pos) > 0)

    [entity.cargo, entity.cargo_max, at_base, on_resource, rdx, rdy, bdx, bdy, world.tick]
  end

  # --- guest → host intent ---

  defp code_to_intent(1, _e, _w), do: :harvest
  defp code_to_intent(2, _e, _w), do: :unload
  defp code_to_intent(3, e, w), do: {:move, World.step_toward({e.x, e.y}, w.base)}

  defp code_to_intent(4, e, w), do: seek(e, w, World.nearest_resource(w, {e.x, e.y}))
  defp code_to_intent(5, e, w), do: {:move, World.wander_dir(w.seed, w.tick, e.id)}
  # Farthest is measured from the BASE, not the harvester — a fixed reference, so
  # the target stays put as the harvester approaches (no oscillation between two
  # nodes). Nearest (code 4) is harvester-relative and stable on its own.
  defp code_to_intent(6, e, w), do: seek(e, w, World.farthest_resource(w, w.base))
  defp code_to_intent(10, _e, _w), do: {:move, {1, 0}}
  defp code_to_intent(11, _e, _w), do: {:move, {-1, 0}}
  defp code_to_intent(12, _e, _w), do: {:move, {0, 1}}
  defp code_to_intent(13, _e, _w), do: {:move, {0, -1}}
  defp code_to_intent(_other, _e, _w), do: :idle

  # Step toward a target resource (or home if the map is empty).
  defp seek(e, w, nil), do: {:move, World.step_toward({e.x, e.y}, w.base)}
  defp seek(e, _w, target), do: {:move, World.step_toward({e.x, e.y}, target)}

  # --- helpers ---

  defp assert_export(pid) do
    if Wasmex.function_exists(pid, "decide") do
      :ok
    else
      terminate(pid)
      {:error, "module must export a `decide` function (see the ABI docs)"}
    end
  end

  defp remaining_fuel(store, default) do
    case StoreOrCaller.get_fuel(store) do
      {:ok, n} -> n
      _ -> default
    end
  end

  defp bool(true), do: 1
  defp bool(false), do: 0

  defp humanize(reason) when is_binary(reason), do: reason
  # Dig the readable message out of a supervisor/init crash tuple.
  defp humanize({{:badmatch, inner}, stack}) when is_list(stack), do: humanize(inner)
  defp humanize({:error, reason}), do: humanize(reason)
  defp humanize({reason, stack}) when is_list(stack), do: humanize(reason)
  defp humanize(reason), do: inspect(reason)
end
