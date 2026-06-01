defmodule ConvoyWeb.SimLiveTrendsTest do
  use ConvoyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Convoy.Engine

  setup do
    id = "trends-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id, seed: 1)
    Engine.submit_player(id, "p1", :wasm, Convoy.Bots.wat_harvester(), "harvester")
    on_exit(fn -> Engine.stop_region(id) end)
    %{id: id}
  end

  test "the trends panel renders sparklines once history accumulates", %{conn: conn, id: id} do
    # Step the region a handful of times so the telemetry buffer fills.
    for _ <- 1..6, do: Engine.step(id)

    {:ok, view, html} = live(conn, ~p"/?region=#{id}")

    # Panel header is always present.
    assert html =~ "rate &amp; acceleration"
    # With history, we render actual SVG sparklines (not the "gathering" notice).
    assert html =~ "<svg"
    assert html =~ "<polyline"
    assert html =~ "d²/dt²"
    refute html =~ "Gathering data"

    # The collapse toggle hides the body.
    html = view |> element("button[phx-click=toggle_trends]") |> render_click()
    refute html =~ "<polyline"
    assert html =~ "show ▼"
  end

  test "shows a gathering-data notice before enough samples exist", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, ~p"/?region=#{id}")
    assert html =~ "Gathering data"
  end
end
