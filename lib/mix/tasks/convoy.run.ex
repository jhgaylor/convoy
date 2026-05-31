defmodule Mix.Tasks.Convoy.Run do
  @shortdoc "Run a local bot file in the Forge & Convoy simulation"

  @moduledoc """
  Develop a harvester bot in your editor, run one command, watch it in the sim.

      mix convoy.run path/to/bot.rs

  The language is inferred from the extension:

      .rules .dsl   -> rule DSL        .ts  -> AssemblyScript
      .wat          -> WebAssembly text .go -> TinyGo
      .rs           -> Rust             .wasm -> precompiled module

  ## Two modes

  **Server (default).** Pushes the bot to a running `mix phx.server` over HTTP,
  into a named region, and starts it. Open `http://localhost:4000/?region=dev`
  in a browser and the UI just *watches* — no clicking required. Combine with
  `--watch` to re-push on every save: edit, save, see it update.

      mix phx.server                       # in one terminal
      mix convoy.run bot.rs --watch        # in another

  **Headless (`--headless`).** Runs the sim in-process and renders it as ASCII
  in this terminal. No server, no browser — the fastest iteration loop.

      mix convoy.run bot.rs --headless --ticks 300

  ## Options

      --region NAME   region to load into (default "dev")
      --server URL    server base url (default http://localhost:4000)
      --headless      run locally and render to the terminal
      --ticks N       headless: ticks to simulate (default 200)
      --every N       headless: print a frame every N ticks (default ticks/8)
      --seed N        headless: world seed (default 1)
      --lang LANG     override language detection
      --watch         re-run whenever the file changes
  """
  use Mix.Task

  alias Convoy.Loader
  alias Convoy.Engine.{World, Program, Wasm, Sim, Render}

  @fuel_budget 50_000

  @switches [
    region: :string,
    server: :string,
    headless: :boolean,
    ticks: :integer,
    every: :integer,
    seed: :integer,
    lang: :string,
    watch: :boolean
  ]
  @aliases [r: :region, s: :server, h: :headless, t: :ticks, w: :watch]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    file = List.first(args) || abort("usage: mix convoy.run FILE [options]\n\n#{@moduledoc}")
    File.exists?(file) || abort("no such file: #{file}")

    lang = language(opts[:lang], file)

    # Headless needs the engine (WasmSupervisor etc.) running in this VM.
    if opts[:headless], do: Mix.Task.run("app.start")

    once(file, lang, opts)

    if opts[:watch], do: watch(file, fn -> once(file, lang, opts) end)
  end

  # --- one execution ---

  defp once(file, lang, opts) do
    source = File.read!(file)
    if opts[:headless], do: run_headless(source, lang, opts), else: run_server(source, lang, opts)
  end

  # --- server mode: push to a running phx.server ---

  defp run_server(source, lang, opts) do
    region = opts[:region] || "dev"
    server = String.trim_trailing(opts[:server] || "http://localhost:4000", "/")
    url = "#{server}/api/region/#{region}/program"

    body =
      case lang do
        :wasm -> %{language: "wasm", source: Base.encode64(source), encoding: "base64"}
        _ -> %{language: to_string(lang), source: source}
      end

    info("→ #{lang} → #{url}")

    case http_post(url, Jason.encode!(body)) do
      {:error, reason} ->
        abort("could not reach #{server} (is `mix phx.server` running?): #{inspect(reason)}", opts[:watch])

      {200, payload} ->
        backend = payload["backend"] || "?"
        ok("loaded (#{backend}) and running in region '#{region}'")
        info("   watch it: #{server}/?region=#{region}")

      {status, payload} ->
        abort("server returned #{status}: #{payload["message"] || inspect(payload)}", opts[:watch])
    end
  end

  # --- headless mode: simulate locally, render to terminal ---

  defp run_headless(source, lang, opts) do
    case build_decider(lang, source) do
      {:ok, decider, cleanup} ->
        ticks = opts[:ticks] || 200
        every = opts[:every] || max(div(ticks, 8), 1)
        seed = opts[:seed] || 1

        info("running #{lang} for #{ticks} ticks (seed #{seed})\n")

        final =
          Enum.reduce(1..ticks, World.generate(seed: seed), fn t, world ->
            world = Sim.tick(world, decider)
            if rem(t, every) == 0, do: print_frame(world)
            world
          end)

        IO.puts("\n── final ──")
        print_frame(final)
        cleanup.()

      {:error, msg} ->
        abort(msg, opts[:watch])
    end
  end

  # Returns {:ok, decide_fun, cleanup_fun} | {:error, msg}.
  defp build_decider(:rules, source) do
    case Program.compile(source) do
      {:ok, rules} -> {:ok, &Program.eval(rules, &1, &2), fn -> :ok end}
      {:error, msg} -> {:error, msg}
    end
  end

  defp build_decider(lang, source) do
    with {:ok, :wasm, exec, _display} <- Loader.prepare(lang, source),
         {:ok, instance} <- Wasm.instantiate(exec) do
      decider = fn entity, world ->
        {:ok, intent, _used} = Wasm.decide(instance, entity, world, @fuel_budget)
        intent
      end

      {:ok, decider, fn -> Wasm.stop(instance) end}
    end
  end

  defp print_frame(world), do: IO.puts(Render.frame(world) <> "\n")

  # --- file watching ---

  defp watch(file, run_fun) do
    abs = Path.expand(file)
    {:ok, pid} = FileSystem.start_link(dirs: [Path.dirname(abs)])
    FileSystem.subscribe(pid)
    info("\n👀 watching #{Path.basename(abs)} — save to reload (ctrl-c to stop)")
    # Match on basename, not full path: macOS reports /private/tmp/... for
    # /tmp/..., and editors save atomically via temp-file rename.
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

  # Editors fire several events per save; collapse a burst into one reload.
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
      ".rules" -> :rules
      ".dsl" -> :rules
      ".wat" -> :wat
      ".rs" -> :rust
      ".ts" -> :assemblyscript
      ".go" -> :tinygo
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
      {:ok, {{_v, status, _reason}, _headers, body}} ->
        {status, decode(IO.iodata_to_binary([body]))}

      {:error, reason} ->
        {:error, reason}
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

  # When watching, a failed run shouldn't kill the watcher — just report it.
  defp abort(msg, watching \\ false)
  defp abort(msg, true), do: IO.puts(IO.ANSI.red() <> "✗ " <> msg <> IO.ANSI.reset())

  defp abort(msg, false) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end
