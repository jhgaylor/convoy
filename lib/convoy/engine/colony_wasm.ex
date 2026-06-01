defmodule Convoy.Engine.ColonyWasm do
  @moduledoc """
  Host side of the v2 **colony ABI** (see `Convoy.Engine.ColonyAbi` and
  `docs/colony-v2-design.md`). Instantiates a colony module (which exports
  `memory`, `inbuf`, `outbuf`, `tick`) under a fuel-metered, import-free
  Wasmtime store, and runs one tick: write the encoded view into the guest's IN
  buffer, call `tick(view_len)`, read the returned command records back.

  This is the v2 counterpart to `Convoy.Engine.Wasm` (the v1 per-entity `decide`
  runner). Phase 1: prove the round-trip + determinism. Folding it into `Region`
  / `Sim` (one colony-wide fuel budget per tick, commands resolved
  authoritatively in id order) comes next.
  """

  alias Wasmex.{Engine, EngineConfig, Store, StoreLimits, Module, StoreOrCaller}
  alias Convoy.Engine.ColonyAbi

  @type instance :: %{pid: pid(), store: Wasmex.StoreOrCaller.t()}

  # Same allocation caps as the v1 tier (fuel bounds CPU; these bound memory).
  @store_limits %StoreLimits{
    memory_size: 16 * 1024 * 1024,
    table_elements: 100_000,
    memories: 1,
    tables: 4,
    instances: 4
  }

  @required_exports ~w(inbuf outbuf tick)

  @doc """
  Compile + instantiate a colony module from WAT or `.wasm` bytes. Returns
  `{:ok, instance}` or `{:error, message}` (never raises). Rejects a module that
  doesn't export the colony ABI (`inbuf`/`outbuf`/`tick`).
  """
  @spec instantiate(binary()) :: {:ok, instance()} | {:error, String.t()}
  def instantiate(source) when is_binary(source) do
    with {:ok, engine} <- Engine.new(%EngineConfig{consume_fuel: true}),
         {:ok, store} <- Store.new(@store_limits, engine),
         {:ok, module} <- Module.compile(store, source),
         {:ok, pid} <- start_instance(store, module),
         :ok <- assert_exports(pid) do
      {:ok, %{pid: pid, store: store}}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Stop a running instance. Safe with nil."
  @spec stop(instance() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%{pid: pid}) do
    if Process.alive?(pid),
      do: DynamicSupervisor.terminate_child(Convoy.Engine.WasmSupervisor, pid)

    :ok
  end

  @doc """
  Run one colony tick: write `encode_view(view)` into the guest IN buffer, call
  `tick`, decode the command list. `view` is either a raw binary (already
  encoded) or a view map (encoded here). Returns `{:ok, commands, fuel_used}`;
  a trap / fuel exhaustion is contained and returns `{:ok, [], fuel_budget}` (the
  colony forfeits its turn, exactly like the v1 tier degrades an entity to idle).
  """
  @spec tick(instance(), binary() | map(), pos_integer()) ::
          {:ok, [map()], non_neg_integer()}
  def tick(%{pid: pid, store: store}, view, fuel_budget) do
    view_bin = if is_binary(view), do: view, else: ColonyAbi.encode_view(view)

    # Fuel must be set BEFORE any guest call — the store consumes fuel, and even
    # the tiny inbuf/outbuf accessors trap on a zero budget. One budget covers the
    # whole tick (inbuf/outbuf cost is negligible vs. the brain's tick()).
    StoreOrCaller.set_fuel(store, fuel_budget)
    {:ok, [in_ptr]} = Wasmex.call_function(pid, "inbuf", [])
    {:ok, mem} = Wasmex.memory(pid)
    # write_binary is side-effecting; it does not return a bare :ok, so don't gate on it.
    Wasmex.Memory.write_binary(store, mem, in_ptr, view_bin)

    case Wasmex.call_function(pid, "tick", [byte_size(view_bin)]) do
      {:ok, [count]} ->
        {:ok, [out_ptr]} = Wasmex.call_function(pid, "outbuf", [])
        bytes = Wasmex.Memory.read_binary(store, mem, out_ptr, count * 16)
        used = fuel_budget - remaining_fuel(store, 0)
        {:ok, ColonyAbi.decode_commands(bytes, count), used}

      {:error, _reason} ->
        # Trap / fuel exhaustion: contained — the colony forfeits its turn.
        {:ok, [], fuel_budget}
    end
  rescue
    _ -> {:ok, [], fuel_budget}
  end

  # --- player memory (for persistence across restarts/deploys) ---
  #
  # A bot's persistent scratch state lives in its linear memory. The instance is
  # a live process we can't serialize, so on snapshot we read a capped slice of
  # its memory; on restore we re-instantiate from the program bytes and write the
  # memory back. Capped hard, treated as opaque untrusted bytes.
  @mem_cap 4 * 1024 * 1024

  @doc "Read a module's linear memory (capped) for persistence, or nil if unavailable."
  def snapshot_memory(%{pid: pid, store: store}) do
    case Wasmex.memory(pid) do
      {:ok, mem} ->
        len = min(Wasmex.Memory.size(store, mem), @mem_cap)

        case Wasmex.Memory.read_binary(store, mem, 0, len) do
          bin when is_binary(bin) -> bin
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def snapshot_memory(_), do: nil

  @doc "Write previously-snapshotted bytes back into a fresh module's linear memory."
  def restore_memory(%{pid: pid, store: store}, bin) when is_binary(bin) and byte_size(bin) > 0 do
    case Wasmex.memory(pid) do
      {:ok, mem} ->
        if Wasmex.Memory.size(store, mem) >= byte_size(bin),
          do: Wasmex.Memory.write_binary(store, mem, 0, bin)

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def restore_memory(_inst, _bin), do: :ok

  # --- helpers ---

  defp start_instance(store, module) do
    spec = %{
      id: {:colony_wasm, System.unique_integer([:positive])},
      start: {Wasmex, :start_link, [%{store: store, module: module}]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(Convoy.Engine.WasmSupervisor, spec)
  end

  defp assert_exports(pid) do
    if Enum.all?(@required_exports, &Wasmex.function_exists(pid, &1)) do
      :ok
    else
      {:error, "module must export the colony ABI (inbuf, outbuf, tick)"}
    end
  end

  defp remaining_fuel(store, default) do
    case StoreOrCaller.get_fuel(store) do
      {:ok, n} -> n
      _ -> default
    end
  end
end
