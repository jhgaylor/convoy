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
