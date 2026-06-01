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
  independent player in one shared world. Languages: `wat`,
  `assemblyscript`, `rust`, `tinygo`, `wasm`. Compilation happens server-side
  (`Convoy.Loader` → `Convoy.Compile`); the region is created if needed, the
  player's program loaded, and the sim started.

  Or just curl a file directly — the body IS the source:

      POST /api/region/:id/upload?player=NAME&lang=rust   (raw body = source)

      curl --data-binary @bot.rs -H 'Content-Type: application/octet-stream' \\
        'https://convoy.inevitable.fyi/api/region/arena/upload?player=bob&lang=rust'

  `lang` may be omitted if `?file=bot.rs` is given (language inferred from the
  extension). For a precompiled module use `lang=wasm` (the binary IS the body).
  """
  use ConvoyWeb, :controller

  alias Convoy.{Engine, Loader}
  alias Convoy.Engine.World

  @languages %{
    "wat" => :wat,
    "assemblyscript" => :assemblyscript,
    "rust" => :rust,
    "tinygo" => :tinygo,
    "wasm" => :wasm
  }

  # JSON body: {player, language, source[, encoding: "base64"]}
  def load(conn, %{"id" => id} = params) do
    # CLI-driven regions are durable so a deploy resumes them.
    Engine.ensure_region(id, persist: true)

    with {:ok, lang} <- fetch_language(params),
         {:ok, source} <- fetch_source(params) do
      submit(conn, id, player_id(params), lang, source)
    else
      {:error, status, msg} -> fail(conn, status, msg)
    end
  end

  # Raw body upload: the request body IS the source (or .wasm bytes). Language
  # comes from ?lang= (or is inferred from ?file=bot.rs).
  def upload(conn, %{"id" => id} = params) do
    Engine.ensure_region(id, persist: true)

    case resolve_language(params) do
      {:error, msg} ->
        fail(conn, 422, msg)

      {:ok, lang} ->
        case read_body(conn, length: 8_000_000) do
          {:ok, body, conn} -> submit(conn, id, player_id(params), lang, body)
          {:more, _partial, conn} -> fail(conn, 413, "body too large (max 8 MB)")
          {:error, _} -> fail(conn, 400, "could not read request body")
        end
    end
  end

  # Shared: compile/prepare, load the player, start the sim, respond.
  defp submit(conn, id, player, lang, source) do
    with {:ok, backend, exec, display} <- Loader.prepare(lang, source),
         :ok <- Engine.submit_player(id, player, backend, exec, display) do
      Engine.play(id)
      json(conn, %{status: "ok", region: id, player: player, backend: backend, source: short(display)})
    else
      {:error, msg} -> fail(conn, 422, msg)
    end
  end

  # Language from ?lang= / ?language=, else inferred from a ?file= extension.
  defp resolve_language(%{"lang" => l}) when is_binary(l) and l != "", do: by_name(l)
  defp resolve_language(%{"language" => l}) when is_binary(l) and l != "", do: by_name(l)
  defp resolve_language(%{"file" => f}) when is_binary(f), do: by_ext(f)

  defp resolve_language(_),
    do: {:error, "specify ?lang=rust|tinygo|assemblyscript|wat|wasm (or ?file=bot.rs)"}

  defp by_name(name) do
    case Map.get(@languages, name) do
      nil -> {:error, "unknown language: #{name}"}
      lang -> {:ok, lang}
    end
  end

  defp by_ext(file) do
    case file |> Path.extname() |> String.downcase() do
      ".rs" -> {:ok, :rust}
      ".go" -> {:ok, :tinygo}
      ".ts" -> {:ok, :assemblyscript}
      ".wat" -> {:ok, :wat}
      ".wasm" -> {:ok, :wasm}
      ext -> {:error, "can't infer language from '#{ext}' — pass ?lang="}
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
