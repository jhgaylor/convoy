defmodule ConvoyWeb.RegionControllerTest do
  use ConvoyWeb.ConnCase, async: true

  alias Convoy.Engine

  test "upload: raw body with ?lang compiles and loads the player", %{conn: conn} do
    id = "up-#{System.unique_integer([:positive])}"

    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/region/#{id}/upload?player=bob&lang=rules", "otherwise to_resource")

    assert %{"status" => "ok", "player" => "bob", "backend" => "rules"} = json_response(conn, 200)
    assert "bob" in Map.keys(Engine.snapshot(id).scores)
  end

  test "upload: language inferred from ?file extension", %{conn: conn} do
    id = "up-#{System.unique_integer([:positive])}"
    wat = "(module (func (export \"decide\") (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 4)))"

    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/region/#{id}/upload?player=p&file=bot.wat", wat)

    assert %{"status" => "ok", "backend" => "wasm"} = json_response(conn, 200)
  end

  test "upload: missing language is a clear 422", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/region/up-x/upload", "otherwise idle")

    assert %{"status" => "error", "message" => msg} = json_response(conn, 422)
    assert msg =~ "lang"
  end

  test "POST loads a rules program and starts the region", %{conn: conn} do
    id = "test-#{System.unique_integer([:positive])}"

    conn = post(conn, ~p"/api/region/#{id}/program", %{language: "rules", source: "otherwise idle"})

    assert %{"status" => "ok", "region" => ^id, "player" => "p1", "backend" => "rules"} =
             json_response(conn, 200)

    # The region now exists, the default player joined, and it's running.
    snap = Engine.snapshot(id)
    assert snap.status == :running
    assert snap.players["p1"].backend == :rules
    assert Enum.any?(snap.world.entities, &(&1.owner == "p1"))
  end

  test "submitting two players shares one world", %{conn: conn} do
    id = "test-#{System.unique_integer([:positive])}"
    prog = "otherwise to_resource"

    post(conn, ~p"/api/region/#{id}/program", %{player: "alice", language: "rules", source: prog})
    post(conn, ~p"/api/region/#{id}/program", %{player: "bob", language: "rules", source: prog})

    snap = Engine.snapshot(id)
    assert Enum.sort(Map.keys(snap.scores)) == ["alice", "bob"]
    owners = snap.world.entities |> Enum.map(& &1.owner) |> Enum.uniq() |> Enum.sort()
    assert owners == ["alice", "bob"]
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
