defmodule Convoy.Engine do
  @moduledoc """
  Public entry point for the simulation engine.

  Regions are started on demand (one per LiveView session in v1) under a
  `DynamicSupervisor` and located through a `Registry` — the BEAM-native
  version of the "region registry + scale-to-zero" model in primer §10.
  A region that nobody starts simply doesn't exist (cold); starting one
  brings it warm/hot.
  """

  alias Convoy.Engine.Region
  alias Convoy.Persistence

  @doc "Ensure a region process exists for `id`; returns `id`."
  def ensure_region(id, opts \\ []) do
    spec = {Region, [{:id, id} | opts]}

    case DynamicSupervisor.start_child(Convoy.Engine.RegionSupervisor, spec) do
      {:ok, _pid} -> id
      {:error, {:already_started, _pid}} -> id
    end
  end

  @doc """
  Restart every persisted region on boot so the simulation continues across a
  deploy without waiting for someone to open it (primer §2 liveness). Each
  region restores its own snapshot and resumes. Disabled via
  `config :convoy, :restore_on_boot, false` (e.g. in tests).
  """
  def restore_all do
    if Application.get_env(:convoy, :restore_on_boot, true) do
      for id <- Persistence.region_ids(), do: ensure_region(id, persist: true)
    end

    :ok
  end

  @doc "Ids of all live regions (running simulations)."
  def list_regions do
    Registry.select(Convoy.Engine.RegionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Operational stats for a region, or nil if it's gone/unresponsive."
  def region_stats(id) do
    Region.stats(id)
  catch
    :exit, _ -> nil
  end

  @doc """
  Stop a running simulation, freeing its compute. A persisted region snapshots
  on the way out (so it resumes when next opened); use `delete_region/1` to
  remove it for good.
  """
  def stop_region(id) do
    case Registry.lookup(Convoy.Engine.RegionRegistry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Convoy.Engine.RegionSupervisor, pid)
      [] -> :ok
    end
  end

  @doc "Stop a simulation and delete its persisted snapshot."
  def delete_region(id) do
    stop_region(id)
    Persistence.delete(id)
  end

  defdelegate snapshot(id), to: Region
  defdelegate load_program(id, backend, exec, display), to: Region
  defdelegate submit_player(id, player_id, backend, exec, display), to: Region
  defdelegate play(id), to: Region
  defdelegate pause(id), to: Region
  defdelegate step(id), to: Region
  defdelegate reset(id, seed), to: Region
  defdelegate set_speed(id, tick_ms), to: Region
  defdelegate topic(id), to: Region
end
