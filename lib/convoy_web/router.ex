defmodule ConvoyWeb.Router do
  use ConvoyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConvoyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ConvoyWeb do
    pipe_through :browser

    # Forge & Convoy — the colony game (program one brain per colony, ship convoys
    # across the shared contested market). This is the game.
    live "/", ColonyLive, :index
    # Ops overview of colony regions. Put behind auth before exposing publicly.
    live "/admin", ColonyAdminLive, :index
  end

  scope "/api", ConvoyWeb do
    pipe_through :api

    # Push player code into a region from outside the browser (the convoy.run CLI).
    post "/region/:id/program", RegionController, :load
    # Same, but the raw request body is the source/`.wasm` (easy `curl @file`).
    post "/region/:id/upload", RegionController, :upload
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:convoy, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ConvoyWeb.Telemetry
    end
  end
end
