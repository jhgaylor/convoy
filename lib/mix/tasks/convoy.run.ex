defmodule Mix.Tasks.Convoy.Run do
  @shortdoc "Push a local colony bot into a running Forge & Convoy server"

  @moduledoc """
  Develop a colony bot in your editor, run one command, watch it in the sim.

      mix convoy.run path/to/bot.rs

  The language is inferred from the extension:

      .rs  -> Rust            .ts  -> AssemblyScript
      .go  -> TinyGo          .zig -> Zig            .c -> C
      .wat -> WebAssembly text          .wasm -> precompiled module

  Pushes the bot to a running `mix phx.server` over HTTP, into a named region, as
  a named player, and it starts running. Open `http://localhost:4000/?region=dev`
  and the UI just *watches*. Combine with `--watch` to re-push on every save.

      mix phx.server                       # in one terminal
      mix convoy.run bot.rs --watch        # in another

  **Multiplayer.** Submit different `--player` ids into the same `--region` and
  they run as independent colonies in one shared world (contesting the market):

      mix convoy.run alice.rs --region arena --player alice
      mix convoy.run bob.ts  --region arena --player bob

  ## Options

      --region NAME   region to load into (default "dev")
      --player NAME   player id to submit as (default "p1")
      --server URL    server base url (default http://localhost:4000)
      --lang LANG     override language detection
      --watch         re-push whenever the file changes
  """
  use Mix.Task

  @switches [region: :string, player: :string, server: :string, lang: :string, watch: :boolean]
  @aliases [r: :region, p: :player, s: :server, w: :watch]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    file = List.first(args) || abort("usage: mix convoy.run FILE [options]\n\n#{@moduledoc}")
    File.exists?(file) || abort("no such file: #{file}")

    lang = language(opts[:lang], file)
    once(file, lang, opts)
    if opts[:watch], do: watch(file, fn -> once(file, lang, opts) end)
  end

  defp once(file, lang, opts), do: run_server(File.read!(file), lang, opts)

  # --- server mode: push to a running phx.server ---

  defp run_server(source, lang, opts) do
    region = opts[:region] || "dev"
    player = opts[:player] || "p1"
    server = String.trim_trailing(opts[:server] || "http://localhost:4000", "/")
    url = "#{server}/api/region/#{region}/program"

    base = %{player: player}

    body =
      case lang do
        :wasm -> Map.merge(base, %{language: "wasm", source: Base.encode64(source), encoding: "base64"})
        _ -> Map.merge(base, %{language: to_string(lang), source: source})
      end

    info("→ #{lang} as player '#{player}' → #{url}")

    case http_post(url, Jason.encode!(body)) do
      {:error, reason} ->
        abort("could not reach #{server} (is `mix phx.server` running?): #{inspect(reason)}", opts[:watch])

      {200, payload} ->
        ok("player '#{player}' loaded (#{payload["backend"] || "?"}) in region '#{region}'")
        info("   watch it: #{server}/?region=#{region}")

      {status, payload} ->
        abort("server returned #{status}: #{payload["message"] || inspect(payload)}", opts[:watch])
    end
  end

  # --- file watching ---

  defp watch(file, run_fun) do
    abs = Path.expand(file)
    {:ok, pid} = FileSystem.start_link(dirs: [Path.dirname(abs)])
    FileSystem.subscribe(pid)
    info("\n👀 watching #{Path.basename(abs)} — save to reload (ctrl-c to stop)")
    watch_loop(Path.basename(abs), run_fun)
  end

  defp watch_loop(name, run_fun) do
    receive do
      {:file_event, _pid, {path, _events}} ->
        if Path.basename(path) == name do
          drain_events()
          IO.puts("")
          info("↻ #{name} changed")
          run_fun.()
        end

        watch_loop(name, run_fun)

      {:file_event, _pid, :stop} ->
        :ok
    end
  end

  defp drain_events do
    receive do
      {:file_event, _pid, _} -> drain_events()
    after
      120 -> :ok
    end
  end

  # --- helpers ---

  defp language(nil, file) do
    case file |> Path.extname() |> String.downcase() do
      ".wat" -> :wat
      ".rs" -> :rust
      ".ts" -> :assemblyscript
      ".go" -> :tinygo
      ".zig" -> :zig
      ".c" -> :c
      ".wasm" -> :wasm
      other -> abort("can't infer language from '#{other}' — pass --lang")
    end
  end

  defp language(override, _file), do: String.to_existing_atom(override)

  defp http_post(url, json) do
    :inets.start()
    :ssl.start()
    request = {String.to_charlist(url), [], ~c"application/json", json}

    case :httpc.request(:post, request, [{:timeout, 30_000}], []) do
      {:ok, {{_v, status, _reason}, _headers, body}} -> {status, decode(IO.iodata_to_binary([body]))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> %{"message" => body}
    end
  end

  defp info(msg), do: IO.puts(IO.ANSI.faint() <> msg <> IO.ANSI.reset())
  defp ok(msg), do: IO.puts(IO.ANSI.green() <> "✓ " <> msg <> IO.ANSI.reset())

  defp abort(msg, watching \\ false)
  defp abort(msg, true), do: IO.puts(IO.ANSI.red() <> "✗ " <> msg <> IO.ANSI.reset())

  defp abort(msg, false) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end
