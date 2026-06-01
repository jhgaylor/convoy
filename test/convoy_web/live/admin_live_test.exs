defmodule ConvoyWeb.AdminLiveTest do
  use ConvoyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Convoy.Engine

  setup do
    id = "adm-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)
    Engine.submit_player(id, "p1", :wasm, Convoy.Bots.wat_idle(), "idle")
    on_exit(fn -> Engine.stop_region(id) end)
    %{id: id}
  end

  test "the overview lists a running region", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ id
  end

  test "expanding a region reveals the live game-value editor", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    html = view |> element("button[phx-click=toggle][phx-value-id=#{id}]") |> render_click()

    assert html =~ "game values"
    assert html =~ "Ore per node"
    assert html =~ "Shipment value (credits)"
    # the input is seeded with the current (default) value.
    assert html =~ ~s(name="config[resource_amount]")
  end

  test "submitting the editor retunes the region in real time", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("button[phx-click=toggle][phx-value-id=#{id}]") |> render_click()

    params = %{
      "region" => id,
      "config" => %{"resource_amount" => "64", "shipment_value" => "99"}
    }

    view |> element("form[phx-submit=set_config]") |> render_submit(params)

    cfg = Engine.region_stats(id).config
    assert cfg.resource_amount == 64
    assert cfg.shipment_value == 99
  end
end
