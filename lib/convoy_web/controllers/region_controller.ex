defmodule ConvoyWeb.RegionController do
  @moduledoc """
  HTTP entry point for pushing player code into a region from outside the
  browser — the `convoy.run` CLI uses this so you can develop a bot in your
  editor and watch it run in a `?region=NAME` browser tab.

  `POST /api/region/:id/program` with JSON:

      {"player": "alice", "language": "rust", "source": "...source text..."}
      {"player": "bob", "language": "wasm", "source": "<base64>", "encoding": "base64"}

  `player` is optional (defaults to the editor player). Submitting different
  players into the same region id is how multiplayer works: each becomes an
  independent player in one shared world. Languages: `rules`, `wat`,
  `assemblyscript`, `rust`, `tinygo`, `wasm`. Compilation happens server-side
  (`Convoy.Loader` → `Convoy.Compile`); the region is created if needed, the
  player's program loaded, and the sim started.
  """
  use ConvoyWeb, :controller

  alias Convoy.{Engine, Loader}
  alias Convoy.Engine.World

  @languages %{
    "rules" => :rules,
    "wat" => :wat,
    "assemblyscript" => :assemblyscript,
    "rust" => :rust,
    "tinygo" => :tinygo,
    "wasm" => :wasm
  }

  def load(conn, %{"id" => id} = params) do
    # CLI-driven regions are durable so a deploy resumes them.
    Engine.ensure_region(id, persist: true)
    player = player_id(params)

    with {:ok, lang} <- fetch_language(params),
         {:ok, source} <- fetch_source(params),
         {:ok, backend, exec, display} <- Loader.prepare(lang, source),
         :ok <- Engine.submit_player(id, player, backend, exec, display) do
      Engine.play(id)
      json(conn, %{status: "ok", region: id, player: player, backend: backend, source: short(display)})
    else
      {:error, status, msg} -> fail(conn, status, msg)
      {:error, msg} -> fail(conn, 422, msg)
    end
  end

  defp player_id(params) do
    case params["player"] do
      p when is_binary(p) and p != "" ->
        # keep ids tame and filesystem/registry-safe
        String.replace(p, ~r/[^a-zA-Z0-9_-]/, "") |> default_if_blank()

      _ ->
        World.default_player()
    end
  end

  defp default_if_blank(""), do: World.default_player()
  defp default_if_blank(p), do: p

  defp fetch_language(params) do
    case Map.get(@languages, params["language"]) do
      nil -> {:error, 422, "unknown or missing language (got #{inspect(params["language"])})"}
      lang -> {:ok, lang}
    end
  end

  defp fetch_source(%{"source" => source} = params) when is_binary(source) do
    case params["encoding"] do
      "base64" ->
        case Base.decode64(source) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, 422, "invalid base64 in source"}
        end

      _ ->
        {:ok, source}
    end
  end

  defp fetch_source(_), do: {:error, 422, "missing `source`"}

  defp fail(conn, status, msg) do
    conn |> put_status(status) |> json(%{status: "error", message: msg})
  end

  defp short(display) when byte_size(display) > 120, do: binary_part(display, 0, 120) <> "…"
  defp short(display), do: display
end
