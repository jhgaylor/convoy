defmodule Convoy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ConvoyWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:convoy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Convoy.PubSub},
      # Region registry + dynamic supervisor: regions are started on demand
      # and located by id (primer §10 region registry / scale-to-zero).
      {Registry, keys: :unique, name: Convoy.Engine.RegionRegistry},
      # Separate registry for v2 colony regions so the v1 enumeration
      # (Engine.list_regions / admin :stats polling) never touches them.
      {Registry, keys: :unique, name: Convoy.Engine.ColonyRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Convoy.Engine.RegionSupervisor},
      # WASM instances live here, not linked to their region: a module that
      # crashes on instantiation (e.g. a memory-bomb rejected by StoreLimits)
      # is contained by the supervisor and surfaced as an error, instead of
      # taking the region process down with it.
      {DynamicSupervisor, strategy: :one_for_one, name: Convoy.Engine.WasmSupervisor},
      # Start to serve requests, typically the last entry
      ConvoyWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Convoy.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConvoyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
