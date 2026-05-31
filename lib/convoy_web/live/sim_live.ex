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

  alias Convoy.Engine
  alias Convoy.Engine.{World, Program, Wasm}
  alias Convoy.Compile

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

  # Which execution backend + bytes a language produces. Compilation (the
  # risky part) happens here, in front of the sim — never inside it.
  defp prepare(:rules, source), do: {:ok, :rules, source, source}
  defp prepare(:wat, source), do: {:ok, :wasm, source, source}

  defp prepare(lang, source) when lang in [:assemblyscript, :rust, :tinygo] do
    case Compile.to_wasm(lang, source) do
      {:ok, bytes} -> {:ok, :wasm, bytes, source}
      {:error, msg} -> {:error, msg}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    id = "region-" <> Integer.to_string(System.unique_integer([:positive]))
    seed = 1
    Engine.ensure_region(id, seed: seed)

    if connected?(socket), do: Phoenix.PubSub.subscribe(Convoy.PubSub, Engine.topic(id))

    snap = Engine.snapshot(id)

    {:ok,
     socket
     |> assign(:region_id, id)
     |> assign(:seed, seed)
     |> assign(:speeds, @speeds)
     |> assign(:languages, @languages)
     |> assign(:language, :rules)
     |> assign(:local_error, nil)
     |> assign_snapshot(snap)
     |> assign(:source_draft, snap.source)
     |> allow_upload(:wasm, accept: ~w(.wasm), max_entries: 1, max_file_size: 8_000_000)}
  end

  # --- commands from the UI ---

  @impl true
  def handle_event("source_changed", %{"source" => source}, socket) do
    {:noreply, assign(socket, :source_draft, source)}
  end

  def handle_event("run", %{"source" => source}, socket) do
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

    # The rule DSL loads instantly; compiled/uploaded languages wait for Run.
    if lang == :rules, do: Engine.load_program(socket.assigns.region_id, :rules, source, source)

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload_wasm", _params, socket) do
    id = socket.assigns.region_id

    consumed =
      consume_uploaded_entries(socket, :wasm, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_name}}
      end)

    socket =
      case consumed do
        [{bytes, name}] ->
          display = "#{name} · #{byte_size(bytes)} bytes (uploaded)"

          case Engine.load_program(id, :wasm, bytes, display) do
            :ok -> Engine.play(id)
            {:error, _msg} -> :noop
          end

          assign(socket, local_error: nil)

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

  # Compile (if needed), load into the region, and start running. Compile
  # failures surface as @local_error; instantiation/DSL failures come back from
  # the region as @compile_error.
  defp compile_load_play(socket, source) do
    id = socket.assigns.region_id
    socket = assign(socket, source_draft: source)

    case prepare(socket.assigns.language, source) do
      {:ok, backend, exec, display} ->
        case Engine.load_program(id, backend, exec, display) do
          :ok -> Engine.play(id)
          {:error, _msg} -> :noop
        end

        assign(socket, :local_error, nil)

      {:error, msg} ->
        assign(socket, :local_error, msg)
    end
  end

  defp assign_snapshot(socket, snap) do
    socket
    |> assign(:world, snap.world)
    |> assign(:backend, snap.backend)
    |> assign(:status, snap.status)
    |> assign(:source, snap.source)
    |> assign(:tick_ms, snap.tick_ms)
    |> assign(:fuel_budget, snap.fuel_budget)
    |> assign(:last_fuel, snap.last_fuel)
    |> assign(:compile_error, snap.compile_error)
  end

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
          </h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Your code is your only interface. Write a harvester program; watch the deterministic sim run it.
          </p>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <.stat label="tick" value={@world.tick} />
          <.stat label="delivered" value={@world.delivered} accent="text-emerald-400" />
          <.stat label="ore left" value={World.ore_remaining(@world)} accent="text-amber-400" />
          <%= if @backend == :wasm do %>
            <.stat label="fuel/tick" value={@last_fuel} accent="text-fuchsia-400" />
          <% end %>
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
              <label class="text-xs uppercase tracking-wide text-slate-400">Upload a .wasm module</label>
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
              <label class="text-xs uppercase tracking-wide text-slate-400">
                Harvester program · {lang_label(@languages, @language)}
              </label>
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

              <.program_status local_error={@local_error} compile_error={@compile_error} />

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
            <span class="font-mono text-sky-300">🤖 H{e.id}</span>
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
          <code class="text-fuchsia-300">1 harvest · 2 unload · 3 to_base · 4 to_resource · 5 wander · 10-13 move ±x/±y · else idle</code>
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
        ids = here |> Enum.map(& &1.id) |> Enum.join(",")

        %{
          glyph: "🤖",
          bg: if(pos == world.base, do: "bg-sky-700", else: "bg-slate-600"),
          title: "Harvester #{ids} @ #{x},#{y}"
        }

      pos == world.base ->
        %{glyph: "🏠", bg: "bg-sky-800", title: "Base @ #{x},#{y}"}

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
end
