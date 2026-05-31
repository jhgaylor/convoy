defmodule ConvoyWeb.RegionController do
  @moduledoc """
  HTTP entry point for pushing player code into a region from outside the
  browser — the `convoy.run` CLI uses this so you can develop a bot in your
  editor and watch it run in a `?region=NAME` browser tab.

  `POST /api/region/:id/program` with JSON:

      {"language": "rust", "source": "...source text..."}
      {"language": "wasm", "source": "<base64>", "encoding": "base64"}

  Languages: `rules`, `wat`, `assemblyscript`, `rust`, `tinygo`, `wasm`.
  Compilation happens server-side (`Convoy.Loader` → `Convoy.Compile`); the
  region is created if needed, the program loaded, and the sim started.
  """
  use ConvoyWeb, :controller

  alias Convoy.{Engine, Loader}

  @languages %{
    "rules" => :rules,
    "wat" => :wat,
    "assemblyscript" => :assemblyscript,
    "rust" => :rust,
    "tinygo" => :tinygo,
    "wasm" => :wasm
  }

  def load(conn, %{"id" => id} = params) do
    Engine.ensure_region(id)

    with {:ok, lang} <- fetch_language(params),
         {:ok, source} <- fetch_source(params),
         {:ok, backend, exec, display} <- Loader.prepare(lang, source),
         :ok <- Engine.load_program(id, backend, exec, display) do
      Engine.play(id)
      json(conn, %{status: "ok", region: id, backend: backend, source: short(display)})
    else
      {:error, status, msg} -> fail(conn, status, msg)
      {:error, msg} -> fail(conn, 422, msg)
    end
  end

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
