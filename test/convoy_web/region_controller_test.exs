defmodule ConvoyWeb.RegionControllerTest do
  use ConvoyWeb.ConnCase, async: true

  alias Convoy.Engine

  test "POST loads a rules program and starts the region", %{conn: conn} do
    id = "test-#{System.unique_integer([:positive])}"

    conn = post(conn, ~p"/api/region/#{id}/program", %{language: "rules", source: "otherwise idle"})

    assert %{"status" => "ok", "region" => ^id, "backend" => "rules"} = json_response(conn, 200)

    # The region now exists and is running the loaded program.
    snap = Engine.snapshot(id)
    assert snap.status == :running
    assert snap.backend == :rules
  end

  test "POST with WAT loads on the wasm backend", %{conn: conn} do
    id = "test-#{System.unique_integer([:positive])}"
    wat = "(module (func (export \"decide\") (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 4)))"

    conn = post(conn, ~p"/api/region/#{id}/program", %{language: "wat", source: wat})
    assert %{"status" => "ok", "backend" => "wasm"} = json_response(conn, 200)
  end

  test "unknown language returns 422", %{conn: conn} do
    conn = post(conn, ~p"/api/region/x/program", %{language: "cobol", source: "x"})
    assert %{"status" => "error", "message" => msg} = json_response(conn, 422)
    assert msg =~ "language"
  end

  test "invalid rules source returns 422 with a compiler message", %{conn: conn} do
    conn = post(conn, ~p"/api/region/y/program", %{language: "rules", source: "when bogus harvest"})
    assert %{"status" => "error", "message" => msg} = json_response(conn, 422)
    assert msg =~ "unknown condition"
  end

  test "base64 wasm upload is decoded and loaded", %{conn: conn} do
    id = "test-#{System.unique_integer([:positive])}"
    wat = "(module (func (export \"decide\") (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 4)))"
    # WAT compiled? No — for upload path we send raw bytes; here send the WAT
    # text base64'd, which Wasmtime still accepts as a text module.
    b64 = Base.encode64(wat)

    conn = post(conn, ~p"/api/region/#{id}/program", %{language: "wasm", source: b64, encoding: "base64"})
    assert %{"status" => "ok", "backend" => "wasm"} = json_response(conn, 200)
  end
end
