defmodule Convoy.Engine do
  @moduledoc """
  Public entry point for the simulation engine.

  Regions are started on demand (one per LiveView session in v1) under a
  `DynamicSupervisor` and located through a `Registry` — the BEAM-native
  version of the "region registry + scale-to-zero" model in primer §10.
  A region that nobody starts simply doesn't exist (cold); starting one
  brings it warm/hot.
  """

  alias Convoy.Engine.{Region, World}
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

  @doc "Operational stats for a running region, or nil if it's gone/unresponsive."
  def region_stats(id) do
    Region.stats(id)
  catch
    :exit, _ -> nil
  end

  @doc "Ids of regions with a persisted snapshot (running or not)."
  def persisted_regions, do: Persistence.region_ids()

  @doc """
  A stats row for a *stopped* (persisted but not running) region, built from
  its snapshot so the admin page can still show and delete it. No live process
  means no memory/reductions.
  """
  def stopped_region_stats(id) do
    case Persistence.load(id) do
      {:ok, %{world: %World{} = world} = snap} ->
        %{
          region_id: id,
          status: :stopped,
          tick: world.tick,
          tick_ms: Map.get(snap, :tick_ms, 0),
          last_fuel: 0,
          players: map_size(Map.get(snap, :players, %{})),
          scores: World.scoreboard(world),
          entities: length(world.entities),
          ore_remaining: World.ore_remaining(world),
          delivered: World.total_refined(world),
          persist: true,
          wasm_instances: 0,
          memory: 0,
          reductions: 0
        }

      _ ->
        nil
    end
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

  @doc "Stop a simulation and delete its persisted snapshot + event log."
  def delete_region(id) do
    stop_region(id)
    Persistence.delete(id)
    Convoy.EventLog.delete(id)
  end

  @doc "A region's durable control-event history (primer §8), most-recent `n`."
  def history(id, n \\ 50), do: Convoy.EventLog.tail(id, n)

  defdelegate observe(id, pid), to: Region
  defdelegate receive_convoy(id, convoy), to: Region
  defdelegate snapshot(id), to: Region
  defdelegate load_program(id, backend, exec, display), to: Region
  defdelegate submit_player(id, player_id, backend, exec, display), to: Region
  defdelegate kick_player(id, player_id), to: Region
  defdelegate play(id), to: Region
  defdelegate pause(id), to: Region
  defdelegate step(id), to: Region
  defdelegate reset(id, seed), to: Region
  defdelegate set_speed(id, tick_ms), to: Region
  defdelegate topic(id), to: Region
end
