defmodule ConvoyWeb.SimLive do
  @moduledoc """
  The playable surface for Forge & Convoy v1.

  You write a behaviour program (left), press Run, and watch your harvester
  agents execute it against the deterministic region simulation (right). The
  LiveView owns no world state — it subscribes to the region process over
  PubSub and sends it commands, exactly the "route a session to the process
  owning the region" model from primer §9.
  """
  use ConvoyWeb, :live_view

  alias Convoy.{Engine, Compile, Loader}
  alias Convoy.Engine.{World, Program, Wasm}

  @speeds [{"0.5x", 800}, {"1x", 400}, {"2x", 200}, {"4x", 100}]

  # Full editor menu. `:rules` and `:wat` need no toolchain; `:assemblyscript`,
  # `:rust`, `:tinygo` compile via Convoy.Compile; `:upload` takes a .wasm file.
  @languages [
    {:rules, "Rules DSL"},
    {:wat, "WAT"},
    {:assemblyscript, "AssemblyScript"},
    {:rust, "Rust"},
    {:tinygo, "TinyGo"},
    {:upload, "Upload .wasm"}
  ]

  defp template_for(:rules), do: Program.default_source()
  defp template_for(:wat), do: Wasm.default_source()
  defp template_for(:upload), do: ""
  defp template_for(lang), do: Compile.template(lang)

  @impl true
  def mount(params, _session, socket) do
    # Every region is a durable, shared world. `/` watches "main"; `?region=NAME`
    # watches another. The browser is a spectator — it never auto-creates a
    # player. You join only by submitting code (Run here, or `mix convoy.run`).
    id = region_id(params)
    seed = 1
    Engine.ensure_region(id, seed: seed, persist: true)

    if connected?(socket), do: Phoenix.PubSub.subscribe(Convoy.PubSub, Engine.topic(id))

    snap = Engine.snapshot(id)

    {:ok,
     socket
     |> assign(:region_id, id)
     |> assign(:seed, seed)
     |> assign(:speeds, @speeds)
     |> assign(:languages, @languages)
     |> assign(:language, :rules)
     # The player name this tab submits as; not joined until first Run.
     |> assign(:player_draft, "p1")
     |> assign(:my_player, nil)
     |> assign(:local_error, nil)
     |> assign(:source_draft, template_for(:rules))
     |> assign_snapshot(snap)
     |> allow_upload(:wasm, accept: ~w(.wasm), max_entries: 1, max_file_size: 8_000_000)}
  end

  # --- commands from the UI ---

  @impl true
  def handle_event("source_changed", %{"source" => source} = params, socket) do
    {:noreply, assign(socket, source_draft: source, player_draft: player_param(params, socket))}
  end

  def handle_event("run", %{"source" => source} = params, socket) do
    socket = assign(socket, :player_draft, player_param(params, socket))
    {:noreply, compile_load_play(socket, source)}
  end

  def handle_event("pause", _params, socket) do
    Engine.pause(socket.assigns.region_id)
    {:noreply, socket}
  end

  def handle_event("step", _params, socket) do
    # Step advances the program already loaded by Run (so we don't recompile
    # Rust/AS on every click). Edit, then press Run to load changes.
    Engine.step(socket.assigns.region_id)
    {:noreply, socket}
  end

  def handle_event("set_language", %{"language" => lang}, socket) do
    lang = String.to_existing_atom(lang)
    source = template_for(lang)

    socket = assign(socket, language: lang, source_draft: source, local_error: nil)

    # Switching language just loads a template into the editor — no submission
    # until Run, so picking a language doesn't make you join.
    {:noreply, socket}
  end

  def handle_event("validate_upload", params, socket) do
    {:noreply, assign(socket, :player_draft, player_param(params, socket))}
  end

  def handle_event("upload_wasm", params, socket) do
    id = socket.assigns.region_id
    player = player_param(params, socket)

    consumed =
      consume_uploaded_entries(socket, :wasm, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_name}}
      end)

    socket =
      case consumed do
        [{bytes, name}] ->
          display = "#{name} · #{byte_size(bytes)} bytes (uploaded)"

          case Engine.submit_player(id, player, :wasm, bytes, display) do
            :ok -> Engine.play(id)
            {:error, _msg} -> :noop
          end

          assign(socket, local_error: nil, player_draft: player, my_player: player)

        [] ->
          assign(socket, local_error: "Choose a .wasm file first.")
      end

    {:noreply, socket}
  end

  def handle_event("reset", _params, socket) do
    Engine.reset(socket.assigns.region_id, socket.assigns.seed)
    {:noreply, socket}
  end

  def handle_event("set_speed", %{"ms" => ms}, socket) do
    Engine.set_speed(socket.assigns.region_id, String.to_integer(ms))
    {:noreply, socket}
  end

  def handle_event("set_seed", %{"seed" => seed}, socket) do
    seed = parse_seed(seed)
    Engine.reset(socket.assigns.region_id, seed)
    {:noreply, assign(socket, :seed, seed)}
  end

  # --- updates from the region process ---

  @impl true
  def handle_info({:region_update, snap}, socket) do
    {:noreply, assign_snapshot(socket, snap)}
  end

  # Compile (if needed) and submit as the chosen player, then run. Compile
  # failures surface as @local_error; instantiation failures come back from the
  # region (shown per-player in the scoreboard and via program_status).
  defp compile_load_play(socket, source) do
    id = socket.assigns.region_id
    player = socket.assigns.player_draft
    socket = assign(socket, source_draft: source)

    case Loader.prepare(socket.assigns.language, source) do
      {:ok, backend, exec, display} ->
        case Engine.submit_player(id, player, backend, exec, display) do
          :ok -> Engine.play(id)
          {:error, _msg} -> :noop
        end

        assign(socket, local_error: nil, my_player: player)

      {:error, msg} ->
        assign(socket, :local_error, msg)
    end
  end

  defp assign_snapshot(socket, snap) do
    socket
    |> assign(:world, snap.world)
    |> assign(:status, snap.status)
    |> assign(:tick_ms, snap.tick_ms)
    |> assign(:fuel_budget, snap.fuel_budget)
    |> assign(:last_fuel, snap.last_fuel)
    |> assign(:scores, snap.scores)
    |> assign(:players, snap.players)
  end

  # The player name to submit as: the form field if present, else the current draft.
  defp player_param(params, socket) do
    case params["player"] do
      p when is_binary(p) ->
        case String.replace(p, ~r/[^a-zA-Z0-9_-]/, "") do
          "" -> socket.assigns.player_draft
          clean -> clean
        end

      _ ->
        socket.assigns.player_draft
    end
  end

  # Every region is a named, shared world. `/` is the default "main" world.
  defp region_id(%{"region" => name}) when is_binary(name) and name != "" do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "") do
      "" -> "main"
      slug -> slug
    end
  end

  defp region_id(_params), do: "main"

  defp parse_seed(seed) do
    case Integer.parse(String.trim(seed)) do
      {n, _} -> n
      :error -> 1
    end
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="border-b border-slate-800 px-6 py-4 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-bold tracking-tight">
            <span class="text-amber-400">Forge</span> &amp; <span class="text-sky-400">Convoy</span>
            <span class="ml-2 text-xs font-normal text-slate-500">v1 · region {@region_id}</span>
            <.link navigate={~p"/admin"} class="ml-2 text-xs font-normal text-sky-400 hover:underline">
              overview
            </.link>
          </h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Your code is your only interface. Write a harvester program; watch the deterministic sim run it.
          </p>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <.stat label="tick" value={@world.tick} />
          <.stat label="delivered" value={World.total_delivered(@world)} accent="text-emerald-400" />
          <.stat label="ore left" value={World.ore_remaining(@world)} accent="text-amber-400" />
          <.stat label="players" value={map_size(@scores)} accent="text-sky-400" />
          <.stat label="fuel/tick" value={@last_fuel} accent="text-fuchsia-400" />
          <span class={[
            "px-2 py-0.5 rounded text-xs font-mono uppercase",
            @status == :running && "bg-emerald-500/20 text-emerald-300",
            @status == :paused && "bg-slate-700 text-slate-300"
          ]}>
            {@status}
          </span>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-[420px_1fr] gap-6 p-6">
        <%!-- left: the code editor + controls --%>
        <section class="space-y-4">
          <div class="text-xs bg-sky-500/10 border border-sky-500/40 text-sky-200 rounded-lg p-2 mb-3">
            📡 Spectating region <span class="font-mono font-semibold">{@region_id}</span>.
            Join by submitting code below, or from your editor:
            <code class="block mt-1 text-sky-300">mix convoy.run YOUR_BOT --region {@region_id} --player NAME --watch</code>
          </div>

          <form phx-change="set_language" class="flex items-center gap-2 mb-1">
            <span class="text-xs uppercase tracking-wide text-slate-400">language</span>
            <select
              name="language"
              class="bg-slate-900 border border-slate-700 rounded px-2 py-1 text-sm font-mono text-slate-100 focus:outline-none focus:border-emerald-500"
            >
              <%= for {id, label} <- @languages do %>
                <option value={id} selected={@language == id}>{label}</option>
              <% end %>
            </select>
            <%= if @language in [:rules, :wat] do %>
              <span class="text-[10px] text-emerald-500/70 font-mono">no toolchain needed</span>
            <% end %>
          </form>

          <%= if @language == :upload do %>
            <%!-- bring a precompiled .wasm from any language --%>
            <form phx-change="validate_upload" phx-submit="upload_wasm">
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs uppercase tracking-wide text-slate-400">Upload a .wasm module</label>
                <label class="text-xs text-slate-400 flex items-center gap-1">
                  play as
                  <input
                    type="text"
                    name="player"
                    value={@player_draft}
                    class="w-20 bg-slate-900 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono text-slate-100"
                  />
                </label>
              </div>
              <div class="mt-1 border border-dashed border-slate-700 rounded-lg p-4 bg-slate-900 text-center text-sm">
                <.live_file_input upload={@uploads.wasm} class="text-xs text-slate-300" />
                <p class="mt-2 text-[11px] text-slate-500">
                  Compile locally (Rust, TinyGo, AssemblyScript, C…) and drop the
                  <code class="text-fuchsia-300">.wasm</code>
                  here. It must export <code class="text-fuchsia-300">decide</code> (see the ABI panel).
                </p>
                <%= for entry <- @uploads.wasm.entries do %>
                  <p class="mt-1 text-[11px] text-emerald-300 font-mono">{entry.client_name} · {entry.progress}%</p>
                  <%= for err <- upload_errors(@uploads.wasm, entry) do %>
                    <p class="text-[11px] text-rose-400">{error_to_string(err)}</p>
                  <% end %>
                <% end %>
              </div>
              <button
                type="submit"
                class="mt-3 px-4 py-1.5 rounded-md bg-fuchsia-500 hover:bg-fuchsia-400 text-slate-950 font-semibold text-sm"
              >
                ⬆ Upload &amp; Run
              </button>
            </form>
          <% else %>
            <form phx-change="source_changed" phx-submit="run">
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs uppercase tracking-wide text-slate-400">
                  Harvester program · {lang_label(@languages, @language)}
                </label>
                <label class="text-xs text-slate-400 flex items-center gap-1">
                  play as
                  <input
                    type="text"
                    name="player"
                    value={@player_draft}
                    class="w-20 bg-slate-900 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono text-slate-100"
                  />
                </label>
              </div>
              <textarea
                name="source"
                spellcheck="false"
                rows="12"
                class="mt-1 w-full font-mono text-sm bg-slate-900 border border-slate-700 rounded-lg p-3 text-emerald-200 focus:outline-none focus:border-emerald-500 resize-y"
              >{@source_draft}</textarea>

              <%= if @language in [:rust, :tinygo, :assemblyscript] and not Compile.available?(@language) do %>
                <div class="mt-2 text-xs bg-amber-500/10 border border-amber-500/40 text-amber-300 rounded p-2">
                  ⚠ {Compile.label(@language)} toolchain not installed on the server.
                  {Compile.install_hint(@language)}
                  Or pick <span class="font-semibold">Upload .wasm</span> and compile locally.
                </div>
              <% end %>

              <.program_status local_error={@local_error} compile_error={player_error(@players, @my_player)} />

              <div class="mt-3 flex flex-wrap gap-2">
                <button
                  type="submit"
                  class="px-4 py-1.5 rounded-md bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-semibold text-sm"
                >
                  ▶ {if @language in [:rules, :wat], do: "Run", else: "Compile & Run"}
                </button>
                <button
                  type="button"
                  phx-click="pause"
                  class="px-3 py-1.5 rounded-md bg-slate-700 hover:bg-slate-600 text-sm"
                >
                  ⏸ Pause
                </button>
                <button
                  type="button"
                  phx-click="step"
                  class="px-3 py-1.5 rounded-md bg-slate-700 hover:bg-slate-600 text-sm"
                >
                  ⏭ Step
                </button>
                <button
                  type="button"
                  phx-click="reset"
                  class="px-3 py-1.5 rounded-md bg-slate-800 hover:bg-slate-700 text-sm"
                >
                  ↻ Reset
                </button>
              </div>
            </form>
          <% end %>

          <%= if @language == :upload do %>
            <.program_status local_error={@local_error} compile_error={@compile_error} />
          <% end %>

          <div class="flex items-center gap-4 text-sm">
            <div class="flex items-center gap-1">
              <span class="text-xs text-slate-400 mr-1">speed</span>
              <%= for {label, ms} <- @speeds do %>
                <button
                  phx-click="set_speed"
                  phx-value-ms={ms}
                  class={[
                    "px-2 py-0.5 rounded text-xs font-mono",
                    @tick_ms == ms && "bg-sky-500 text-slate-950",
                    @tick_ms != ms && "bg-slate-800 hover:bg-slate-700 text-slate-300"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>
            <form phx-submit="set_seed" class="flex items-center gap-1">
              <span class="text-xs text-slate-400">seed</span>
              <input
                type="text"
                name="seed"
                value={@seed}
                class="w-16 bg-slate-900 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono"
              />
            </form>
          </div>

          <.cheatsheet language={@language} fuel_budget={@fuel_budget} />
        </section>

        <%!-- right: the world --%>
        <section class="space-y-4">
          <.scoreboard scores={@scores} players={@players} my_player={@my_player} />
          <.grid world={@world} />
          <.entities world={@world} />
          <.event_log world={@world} />
        </section>
      </div>
    </div>
    """
  end

  # --- function components ---

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: "text-slate-100"

  defp stat(assigns) do
    ~H"""
    <div class="text-center">
      <div class={["font-mono font-bold leading-none", @accent]}>{@value}</div>
      <div class="text-[10px] uppercase tracking-wide text-slate-500">{@label}</div>
    </div>
    """
  end

  attr :scores, :map, required: true
  attr :players, :map, required: true
  attr :my_player, :string, default: nil

  defp scoreboard(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-xs uppercase tracking-wide text-slate-400">Players</div>
        <div class="text-[10px] text-slate-500">submit more with <code class="text-slate-400">mix convoy.run --player</code></div>
      </div>
      <%= if @scores == %{} do %>
        <div class="text-xs text-slate-500">No players yet — submit code to join.</div>
      <% end %>
      <div class="space-y-1">
        <%= for {player, score} <- Enum.sort_by(@scores, fn {_p, s} -> -s end) do %>
          <% color = player_color(player) %>
          <div class="flex items-center gap-2 text-sm">
            <span class={["w-2.5 h-2.5 rounded-full", color.dot]}></span>
            <span class={["font-mono", color.text]}>{player}</span>
            <%= if player == @my_player do %>
              <span class="text-[10px] text-slate-500">(you)</span>
            <% end %>
            <%= if err = get_in(@players, [player, :compile_error]) do %>
              <span class="text-[10px] text-rose-400" title={err}>⛔</span>
            <% end %>
            <span class="ml-auto font-mono font-bold text-slate-100">{score}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :world, World, required: true

  defp grid(assigns) do
    ~H"""
    <div
      class="inline-grid gap-px bg-slate-800 p-px rounded-lg border border-slate-700"
      style={"grid-template-columns: repeat(#{@world.width}, minmax(0, 1fr)); max-width: 640px;"}
    >
      <%= for y <- 0..(@world.height - 1), x <- 0..(@world.width - 1) do %>
        <% cell = cell_info(@world, {x, y}) %>
        <div
          class={["aspect-square flex items-center justify-center text-xs font-bold relative", cell.bg]}
          title={cell.title}
        >
          {cell.glyph}
        </div>
      <% end %>
    </div>
    """
  end

  attr :world, World, required: true

  defp entities(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-2">
      <%= for e <- Enum.sort_by(@world.entities, & &1.id) do %>
        <div class="bg-slate-900 border border-slate-800 rounded-lg p-2 text-xs">
          <div class="flex items-center justify-between">
            <span class={["font-mono", player_color(e.owner).text]}>🤖 {e.owner}/H{e.id}</span>
            <span class="text-slate-500">({e.x},{e.y})</span>
          </div>
          <div class="mt-1 flex items-center gap-1">
            <div class="flex-1 h-1.5 bg-slate-800 rounded overflow-hidden">
              <div class="h-full bg-amber-400" style={"width: #{round(e.cargo / e.cargo_max * 100)}%"}>
              </div>
            </div>
            <span class="font-mono text-amber-300">{e.cargo}/{e.cargo_max}</span>
          </div>
          <div class="mt-1 text-[10px] text-slate-500 font-mono">{e.last_action}</div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :world, World, required: true

  defp event_log(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="text-xs uppercase tracking-wide text-slate-400 mb-2">Event log</div>
      <div class="space-y-1 max-h-48 overflow-y-auto font-mono text-xs text-slate-400">
        <%= for ev <- @world.events do %>
          <div>{ev}</div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :local_error, :string, default: nil
  attr :compile_error, :string, default: nil

  defp program_status(assigns) do
    ~H"""
    <%= cond do %>
      <% @local_error -> %>
        <div class="mt-2 text-xs font-mono bg-rose-500/10 border border-rose-500/40 text-rose-300 rounded p-2 whitespace-pre-wrap">⛔ {@local_error}</div>
      <% @compile_error -> %>
        <div class="mt-2 text-xs font-mono bg-rose-500/10 border border-rose-500/40 text-rose-300 rounded p-2 whitespace-pre-wrap">⛔ {@compile_error}</div>
      <% true -> %>
        <div class="mt-2 text-xs font-mono text-emerald-500/70">✓ program loaded</div>
    <% end %>
    """
  end

  attr :language, :atom, required: true
  attr :fuel_budget, :integer, required: true

  defp cheatsheet(%{language: :rules} = assigns), do: rules_cheatsheet(assigns)
  defp cheatsheet(assigns), do: wasm_cheatsheet(assigns)

  defp wasm_cheatsheet(assigns) do
    ~H"""
    <details class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-xs text-slate-400">
      <summary class="cursor-pointer text-slate-300 font-semibold">WASM execution tier</summary>
      <div class="mt-2 space-y-2">
        <p>
          Your module runs under <span class="text-fuchsia-300">Wasmtime</span>
          with a per-entity fuel budget of
          <code class="text-fuchsia-300">{@fuel_budget}</code>
          instructions/tick. Burn it all (e.g. an infinite loop) and the call traps —
          contained, the harvester just idles that tick. Bring Rust, TinyGo,
          AssemblyScript, or hand-written WAT.
        </p>
        <p>
          Export <code class="text-fuchsia-300">decide(...)</code> with this ABI (all i32):
        </p>
        <pre class="bg-slate-950 rounded p-2 text-fuchsia-200">decide(cargo, cargo_max, at_base, on_resource,
       res_dx, res_dy, base_dx, base_dy, tick) -> code</pre>
        <div>
          <div class="text-slate-300">return code → intent</div>
          <code class="text-fuchsia-300">1 harvest · 2 unload · 3 to_base · 4 to_resource · 5 wander · 6 to_far_resource (from base) · 10-13 move ±x/±y · else idle</code>
        </div>
      </div>
    </details>
    """
  end

  defp rules_cheatsheet(assigns) do
    ~H"""
    <details class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-xs text-slate-400">
      <summary class="cursor-pointer text-slate-300 font-semibold">Rule DSL</summary>
      <div class="mt-2 space-y-2">
        <p>One rule per line, evaluated top-to-bottom; first match wins. Each rule returns an <em>intent</em> — the sim resolves it authoritatively (you can't cheat position or ore).</p>
        <div>
          <div class="text-slate-300">conditions</div>
          <code class="text-emerald-300">cargo_full · cargo_empty · has_cargo · on_resource · at_base · can_unload · always</code>
        </div>
        <div>
          <div class="text-slate-300">actions</div>
          <code class="text-emerald-300">harvest · unload · to_base · to_resource · wander · idle</code>
        </div>
        <pre class="bg-slate-950 rounded p-2 text-emerald-200">when can_unload  unload
    when cargo_full  to_base
    when on_resource harvest
    otherwise        to_resource</pre>
      </div>
    </details>
    """
  end

  # --- view helpers ---

  defp lang_label(languages, id) do
    case List.keyfind(languages, id, 0) do
      {_id, label} -> label
      nil -> to_string(id)
    end
  end

  defp player_error(_players, nil), do: nil
  defp player_error(players, player), do: get_in(players, [player, :compile_error])

  defp error_to_string(:too_large), do: "file too large (max 8 MB)"
  defp error_to_string(:not_accepted), do: "not a .wasm file"
  defp error_to_string(:too_many_files), do: "one file at a time"
  defp error_to_string(other), do: to_string(other)

  defp cell_info(world, pos) do
    {x, y} = pos
    here = Enum.filter(world.entities, &(&1.x == x and &1.y == y))
    ore = World.resource_at(world, pos)

    cond do
      here != [] ->
        # Colour the cell by the (lowest-id) occupant's owner so you can see
        # whose harvesters are where in the shared world.
        owner = here |> Enum.min_by(& &1.id) |> Map.get(:owner)
        owners = here |> Enum.map(& &1.owner) |> Enum.uniq() |> Enum.join(",")

        %{
          glyph: "🤖",
          bg: player_color(owner).cell,
          title: "#{owners} @ #{x},#{y}"
        }

      pos == world.base ->
        %{glyph: "🏠", bg: "bg-slate-700", title: "Base @ #{x},#{y}"}

      ore > 0 ->
        %{glyph: "", bg: ore_bg(ore), title: "Ore: #{ore} @ #{x},#{y}"}

      true ->
        %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  defp ore_bg(amount) do
    cond do
      amount >= 30 -> "bg-amber-500"
      amount >= 15 -> "bg-amber-600"
      amount >= 5 -> "bg-amber-700"
      true -> "bg-amber-800"
    end
  end

  # Stable per-player colour from a fixed palette (Tailwind needs literal class
  # names, so we map a hash onto whole strings rather than interpolate).
  @palette [
    %{dot: "bg-emerald-400", text: "text-emerald-300", cell: "bg-emerald-600"},
    %{dot: "bg-sky-400", text: "text-sky-300", cell: "bg-sky-600"},
    %{dot: "bg-fuchsia-400", text: "text-fuchsia-300", cell: "bg-fuchsia-600"},
    %{dot: "bg-amber-400", text: "text-amber-300", cell: "bg-amber-600"},
    %{dot: "bg-rose-400", text: "text-rose-300", cell: "bg-rose-600"},
    %{dot: "bg-cyan-400", text: "text-cyan-300", cell: "bg-cyan-600"}
  ]

  defp player_color(player_id) do
    Enum.at(@palette, rem(:erlang.phash2(player_id), length(@palette)))
  end
end
