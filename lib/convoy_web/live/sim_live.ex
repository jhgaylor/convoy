defmodule ConvoyWeb.SimLive do
  @moduledoc """
  The spectator surface for Forge & Convoy.

  This page *watches* a shared region — it owns no world state, just subscribes
  to the region process over PubSub (primer §9). You don't write code here; you
  submit a bot from outside (curl a file, `mix convoy.run`, the API, or the file
  upload below) and watch every player's harvesters compete on the grid.
  """
  use ConvoyWeb, :live_view

  alias Convoy.{Engine, Loader, Compile}
  alias Convoy.Engine.{World, Wasm}

  @speeds [{"0.5x", 800}, {"1x", 400}, {"2x", 200}, {"4x", 100}]

  # Source-file extensions we accept (browser upload + language inference).
  @ext_lang %{
    ".rs" => :rust,
    ".go" => :tinygo,
    ".ts" => :assemblyscript,
    ".zig" => :zig,
    ".c" => :c,
    ".wat" => :wat,
    ".wasm" => :wasm
  }

  @impl true
  def mount(params, _session, socket) do
    # Every region is a durable, shared world. `/` watches "main";
    # `?region=NAME` watches another. The browser never auto-joins.
    id = region_id(params)
    Engine.ensure_region(id, seed: 1, persist: true)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Convoy.PubSub, Engine.topic(id))
      # Tell the region it has a live spectator so it ticks at full rate (§5);
      # when this LiveView process dies the region falls back to the warm rate.
      Engine.observe(id, self())
    end

    {:ok,
     socket
     |> assign(:region_id, id)
     |> assign(:base_url, ConvoyWeb.Endpoint.url())
     |> assign(:seed, 1)
     |> assign(:speeds, @speeds)
     |> assign(:tabs, language_tabs())
     |> assign(:active_tab, :rust)
     |> assign(:upload_player, "p1")
     |> assign(:upload_error, nil)
     |> assign(:my_player, nil)
     |> assign_snapshot(Engine.snapshot(id))
     # accept: :any — several of our extensions (.rs/.go/.wat) aren't registered
     # MIME types, which allow_upload's filter rejects. We validate the
     # extension ourselves in lang_from_ext/1.
     |> allow_upload(:bot, accept: :any, max_entries: 1, max_file_size: 8_000_000)}
  end

  # --- spectator: submit + sim controls ---

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("validate_upload", params, socket) do
    {:noreply,
     assign(socket, :upload_player, clean_player(params["player"], socket.assigns.upload_player))}
  end

  def handle_event("upload_bot", params, socket) do
    id = socket.assigns.region_id
    player = clean_player(params["player"], socket.assigns.upload_player)

    consumed =
      consume_uploaded_entries(socket, :bot, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_name}}
      end)

    socket =
      case consumed do
        [{content, name}] -> submit_upload(socket, id, player, name, content)
        [] -> assign(socket, :upload_error, "Choose a file first.")
      end

    {:noreply, socket}
  end

  def handle_event("play", _params, socket) do
    Engine.play(socket.assigns.region_id)
    {:noreply, socket}
  end

  def handle_event("pause", _params, socket) do
    Engine.pause(socket.assigns.region_id)
    {:noreply, socket}
  end

  def handle_event("step", _params, socket) do
    Engine.step(socket.assigns.region_id)
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

  @impl true
  def handle_info({:region_update, snap}, socket) do
    {:noreply, assign_snapshot(socket, snap)}
  end

  # --- submit helpers ---

  defp submit_upload(socket, id, player, filename, content) do
    with {:ok, lang} <- lang_from_ext(filename),
         {:ok, backend, exec, display} <- Loader.prepare(lang, content),
         :ok <- Engine.submit_player(id, player, backend, exec, display) do
      Engine.play(id)
      assign(socket, upload_error: nil, upload_player: player, my_player: player)
    else
      {:error, msg} -> assign(socket, :upload_error, msg)
    end
  end

  defp lang_from_ext(filename) do
    case Map.get(@ext_lang, filename |> Path.extname() |> String.downcase()) do
      nil -> {:error, "unsupported file type — use .rs .go .ts .wat or .wasm"}
      lang -> {:ok, lang}
    end
  end

  defp clean_player(value, fallback) do
    case value do
      v when is_binary(v) ->
        case String.replace(v, ~r/[^a-zA-Z0-9_-]/, "") do
          "" -> fallback
          clean -> clean
        end

      _ ->
        fallback
    end
  end

  defp assign_snapshot(socket, snap) do
    socket
    |> assign(:world, snap.world)
    |> assign(:status, snap.status)
    |> assign(:activation, Map.get(snap, :activation, snap.status))
    |> assign(:tick_ms, snap.tick_ms)
    |> assign(:fuel_budget, snap.fuel_budget)
    |> assign(:last_fuel, snap.last_fuel)
    |> assign(:scores, snap.scores)
    |> assign(:bases, snap.bases)
    |> assign(:players, snap.players)
  end

  # Each tab: the starter code + how to submit it. `toolchain?` flags languages
  # the server compiles (vs WAT/Rules which need none).
  defp language_tabs do
    [
      %{
        id: :rust,
        label: "Rust",
        ext: "rs",
        lang: "rust",
        toolchain?: true,
        code: Compile.template(:rust)
      },
      %{
        id: :tinygo,
        label: "Go",
        ext: "go",
        lang: "tinygo",
        toolchain?: true,
        code: Compile.template(:tinygo)
      },
      %{
        id: :assemblyscript,
        label: "AssemblyScript",
        ext: "ts",
        lang: "assemblyscript",
        toolchain?: true,
        code: Compile.template(:assemblyscript)
      },
      %{
        id: :zig,
        label: "Zig",
        ext: "zig",
        lang: "zig",
        toolchain?: true,
        code: Compile.template(:zig)
      },
      %{id: :c, label: "C", ext: "c", lang: "c", toolchain?: true, code: Compile.template(:c)},
      %{
        id: :wat,
        label: "WAT",
        ext: "wat",
        lang: "wat",
        toolchain?: false,
        code: Wasm.default_source()
      }
    ]
  end

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
            <span class="text-amber-400">Forge</span>
            &amp; <span class="text-sky-400">Convoy</span>
            <span class="ml-2 text-xs font-normal text-slate-500">region {@region_id}</span>
            <.link navigate={~p"/admin"} class="ml-2 text-xs font-normal text-sky-400 hover:underline">
              overview
            </.link>
          </h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Write a bot in your language, send it to the server, and watch every player's harvesters compete.
          </p>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <.stat label="tick" value={@world.tick} />
          <.stat label="credits" value={World.total_credits(@world)} accent="text-yellow-300" />
          <.stat label="refined" value={World.total_refined(@world)} accent="text-emerald-400" />
          <.stat label="ore left" value={World.ore_remaining(@world)} accent="text-amber-400" />
          <.stat label="players" value={map_size(@scores)} accent="text-sky-400" />
          <.stat label="fuel/tick" value={@last_fuel} accent="text-fuchsia-400" />
          <span
            class={[
              "px-2 py-0.5 rounded text-xs font-mono uppercase",
              @activation == :hot && "bg-emerald-500/20 text-emerald-300",
              @activation == :warm && "bg-amber-500/20 text-amber-300",
              @activation not in [:hot, :warm] && "bg-slate-700 text-slate-300"
            ]}
            title="hot = full rate · warm = slow (no spectators)"
          >
            {@activation}
          </span>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-[460px_1fr] gap-6 p-6">
        <%!-- left: how to submit a bot --%>
        <section class="space-y-4">
          <.submit_panel
            tabs={@tabs}
            active_tab={@active_tab}
            region_id={@region_id}
            base_url={@base_url}
          />
          <.upload_panel
            uploads={@uploads}
            upload_player={@upload_player}
            upload_error={@upload_error}
          />
          <.abi_panel fuel_budget={@fuel_budget} />
        </section>

        <%!-- right: the world --%>
        <section class="space-y-4">
          <.controls status={@status} speeds={@speeds} tick_ms={@tick_ms} seed={@seed} />
          <.scoreboard bases={@bases} players={@players} my_player={@my_player} />
          <.rooms world={@world} />
          <.entities world={@world} />
          <.event_log world={@world} />
        </section>
      </div>
    </div>
    """
  end

  # --- function components ---

  attr :tabs, :list, required: true
  attr :active_tab, :atom, required: true
  attr :region_id, :string, required: true
  attr :base_url, :string, required: true

  defp submit_panel(assigns) do
    assigns = assign(assigns, :tab, Enum.find(assigns.tabs, &(&1.id == assigns.active_tab)))

    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-4">
      <h2 class="text-sm font-semibold text-slate-200">Submit a bot</h2>
      <p class="text-xs text-slate-500 mt-1">
        Your bot is a tiny WebAssembly module that exports <code class="text-fuchsia-300">decide</code>.
        Pick a language, write it, and send it — the server compiles Rust/Go/AssemblyScript for you.
      </p>

      <div class="flex flex-wrap gap-1 mt-3">
        <%= for t <- @tabs do %>
          <button
            phx-click="set_tab"
            phx-value-tab={t.id}
            class={[
              "px-2 py-0.5 rounded text-xs font-mono",
              @active_tab == t.id && "bg-emerald-500 text-slate-950",
              @active_tab != t.id && "bg-slate-800 hover:bg-slate-700 text-slate-300"
            ]}
          >
            {t.label}
          </button>
        <% end %>
      </div>

      <div class="mt-1 text-[10px] text-slate-500">
        {if @tab.toolchain?, do: "compiled server-side", else: "no toolchain needed"}
      </div>

      <div class="text-[10px] uppercase tracking-wide text-slate-500 mt-3 mb-1">
        example · bot.{@tab.ext}
      </div>
      <pre class="bg-slate-950 rounded p-3 text-[11px] leading-relaxed text-emerald-200 overflow-x-auto max-h-64">{@tab.code}</pre>

      <div class="text-[10px] uppercase tracking-wide text-slate-500 mt-3 mb-1">send it</div>
      <pre class="bg-slate-950 rounded p-3 text-[11px] leading-relaxed text-sky-200 overflow-x-auto">curl --data-binary @bot.{@tab.ext} -H 'Content-Type: application/octet-stream' {@base_url}/api/region/{@region_id}/upload?player=YOU&amp;lang={@tab.lang}</pre>
      <div class="text-[10px] text-slate-500 mt-1">or, from a clone of the repo:</div>
      <pre class="bg-slate-950 rounded p-2 mt-1 text-[11px] text-slate-300 overflow-x-auto whitespace-pre-wrap">mix convoy.run bot.{@tab.ext} --region {@region_id} --player YOU</pre>
    </div>
    """
  end

  attr :uploads, :any, required: true
  attr :upload_player, :string, required: true
  attr :upload_error, :string, default: nil

  defp upload_panel(assigns) do
    ~H"""
    <form
      phx-change="validate_upload"
      phx-submit="upload_bot"
      class="bg-slate-900 border border-slate-800 rounded-lg p-4"
    >
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold text-slate-200">…or upload a file</h2>
        <label class="text-xs text-slate-400 flex items-center gap-1">
          player
          <input
            type="text"
            name="player"
            value={@upload_player}
            class="w-24 bg-slate-950 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono text-slate-100"
          />
        </label>
      </div>
      <p class="text-xs text-slate-500 mt-1">
        Pick a source file (<code>.rs .go .ts .wat</code>) or a precompiled <code>.wasm</code>.
      </p>
      <div class="mt-2 flex items-center gap-2">
        <.live_file_input upload={@uploads.bot} class="text-xs text-slate-300" />
        <button
          type="submit"
          class="px-3 py-1 rounded-md bg-fuchsia-500 hover:bg-fuchsia-400 text-slate-950 font-semibold text-sm"
        >
          ⬆ Upload
        </button>
      </div>
      <%= for entry <- @uploads.bot.entries do %>
        <p class="mt-1 text-[11px] text-emerald-300 font-mono">
          {entry.client_name} · {entry.progress}%
        </p>
        <%= for err <- upload_errors(@uploads.bot, entry) do %>
          <p class="text-[11px] text-rose-400">{error_to_string(err)}</p>
        <% end %>
      <% end %>
      <p :if={@upload_error} class="mt-2 text-[11px] font-mono text-rose-300 whitespace-pre-wrap">
        ⛔ {@upload_error}
      </p>
    </form>
    """
  end

  attr :fuel_budget, :integer, required: true

  defp abi_panel(assigns) do
    ~H"""
    <details class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-xs text-slate-400">
      <summary class="cursor-pointer text-slate-300 font-semibold">The decide ABI</summary>
      <div class="mt-2 space-y-2">
        <p>
          Each tick, per harvester, the sim calls your <code class="text-fuchsia-300">decide</code>
          with a
          read-only view and you return an intent code. It runs under a <code class="text-fuchsia-300">{@fuel_budget}</code>-instruction fuel budget; zero host imports.
        </p>
        <pre class="bg-slate-950 rounded p-2 text-fuchsia-200">decide(cargo, cargo_max, at_base, on_resource,
       res_dx, res_dy, base_dx, base_dy, tick,
       base_ore, base_goods, can_refine, can_cargo, can_fuel) -> code</pre>
        <div>
          <div class="text-slate-300">return code → intent</div>
          <code class="text-fuchsia-300">
            1 harvest · 2 unload · 3 to_base · 4 to_resource · 5 wander · 6 to_far_resource · 10-13 move ±x/±y · 20/21/22 build refine/cargo/fuel · else idle
          </code>
        </div>
        <p class="text-slate-400">
          <span class="text-amber-300">The Forge:</span>
          unload drops ore in your base; it refines into
          goods each tick; spend goods at base to climb the tech ladder
          (<code>can_*</code> tells you what you can afford).
        </p>
        <p class="text-slate-500">Full guide: <code>docs/writing-bots.md</code>.</p>
      </div>
    </details>
    """
  end

  attr :status, :atom, required: true
  attr :speeds, :list, required: true
  attr :tick_ms, :integer, required: true
  attr :seed, :integer, required: true

  defp controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 text-sm">
      <%= if @status == :running do %>
        <button phx-click="pause" class="px-3 py-1 rounded-md bg-slate-700 hover:bg-slate-600 text-sm">
          ⏸ Pause
        </button>
      <% else %>
        <button
          phx-click="play"
          class="px-3 py-1 rounded-md bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-semibold text-sm"
        >
          ▶ Play
        </button>
      <% end %>
      <button phx-click="step" class="px-3 py-1 rounded-md bg-slate-700 hover:bg-slate-600 text-sm">
        ⏭ Step
      </button>
      <button
        phx-click="reset"
        data-confirm="Reset this shared world (keeps players, restarts the map)?"
        class="px-3 py-1 rounded-md bg-slate-800 hover:bg-slate-700 text-sm"
      >
        ↻ Reset
      </button>
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
          class="w-14 bg-slate-900 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono"
        />
      </form>
    </div>
    """
  end

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

  attr :bases, :map, required: true
  attr :players, :map, required: true
  attr :my_player, :string, default: nil

  defp scoreboard(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-xs uppercase tracking-wide text-slate-400">Players · Forge &amp; Convoy</div>
        <div class="text-[10px] text-slate-500 font-mono">goods · R/C/F tech · refined · credits</div>
      </div>
      <%= if @bases == %{} do %>
        <div class="text-xs text-slate-500">No players yet — submit a bot to join.</div>
      <% end %>
      <div class="space-y-1">
        <%= for {player, base} <- Enum.sort_by(@bases, fn {_p, b} -> {-b.credits, -b.refined_total} end) do %>
          <% color = player_color(player) %>
          <div class="flex items-center gap-2 text-sm">
            <span class={["w-2.5 h-2.5 rounded-full", color.dot]}></span>
            <span class={["font-mono", color.text]}>{player}</span>
            <span :if={player == @my_player} class="text-[10px] text-slate-500">(you)</span>
            <span
              :if={err = get_in(@players, [player, :compile_error])}
              class="text-[10px] text-rose-400"
              title={err}
            >
              ⛔
            </span>
            <span class="ml-auto flex items-center gap-2 font-mono text-xs">
              <span class="text-sky-300" title="refined goods to spend">◆ {base.goods}</span>
              <span class="text-slate-500" title="tech: refine / cargo / fuel">
                R{base.tech.refine}·C{base.tech.cargo}·F{base.tech.fuel}
              </span>
              <span class="text-emerald-300" title="lifetime refined">⚒ {base.refined_total}</span>
              <span class="font-bold text-yellow-300 w-14 text-right" title="market credits (score)">
                🏪 {base.credits}
              </span>
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :world, World, required: true

  # One grid per player's private harvesting room, then the single shared market
  # room. Players can't enter each other's rooms — only the market is contested.
  defp rooms(assigns) do
    assigns = assign(assigns, :room_ids, Enum.sort(World.room_ids(assigns.world)))

    ~H"""
    <div class="space-y-4">
      <%= if @room_ids == [] do %>
        <div class="text-xs text-slate-500">No rooms yet — submit a bot to open one.</div>
      <% end %>
      <%= for room <- @room_ids do %>
        <% color = player_color(room) %>
        <div>
          <div class="flex items-center gap-2 mb-1">
            <span class={["w-2.5 h-2.5 rounded-full", color.dot]}></span>
            <span class={["text-xs font-mono", color.text]}>{room}'s room</span>
            <span class="text-[10px] text-slate-500">
              · private · {World.ore_remaining(@world, room)} ore
            </span>
          </div>
          <.room_grid
            world={@world}
            cells={
              for y <- 0..(@world.height - 1),
                  x <- 0..(@world.width - 1),
                  do: room_cell_info(@world, room, {x, y})
            }
          />
        </div>
      <% end %>
      <div>
        <div class="flex items-center gap-2 mb-1">
          <span class="w-2.5 h-2.5 rounded-full bg-yellow-500"></span>
          <span class="text-xs font-mono text-yellow-300">market</span>
          <span class="text-[10px] text-slate-500">· shared · contested</span>
        </div>
        <.room_grid
          world={@world}
          cells={
            for y <- 0..(@world.height - 1),
                x <- 0..(@world.width - 1),
                do: market_cell_info(@world, {x, y})
          }
        />
      </div>
    </div>
    """
  end

  attr :world, World, required: true
  attr :cells, :list, required: true

  defp room_grid(assigns) do
    ~H"""
    <div
      class="inline-grid gap-px bg-slate-800 p-px rounded-lg border border-slate-700"
      style={"grid-template-columns: repeat(#{@world.width}, minmax(0, 1fr)); max-width: 640px;"}
    >
      <%= for cell <- @cells do %>
        <div
          class={[
            "aspect-square flex items-center justify-center text-xs font-bold relative",
            cell.bg
          ]}
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
        <% convoy? = e.kind == :convoy %>
        <div class={[
          "bg-slate-900 border rounded-lg p-2 text-xs",
          if(convoy?, do: "border-yellow-600/50", else: "border-slate-800")
        ]}>
          <div class="flex items-center justify-between">
            <span class={["font-mono", player_color(e.owner).text]}>
              {if convoy?, do: "🚚 #{e.owner}/C#{e.id}", else: "🤖 #{e.owner}/H#{e.id}"}
            </span>
            <span class="text-slate-500">({e.x},{e.y})</span>
          </div>
          <div class="mt-1 flex items-center gap-1">
            <div class="flex-1 h-1.5 bg-slate-800 rounded overflow-hidden">
              <div
                class={["h-full", if(convoy?, do: "bg-yellow-400", else: "bg-amber-400")]}
                style={"width: #{round(e.cargo / e.cargo_max * 100)}%"}
              >
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

  # --- view helpers ---

  defp error_to_string(:too_large), do: "file too large (max 8 MB)"
  defp error_to_string(:not_accepted), do: "unsupported file type (.rs .go .ts .wat .wasm)"
  defp error_to_string(:too_many_files), do: "one file at a time"
  defp error_to_string(other), do: to_string(other)

  # A cell in one player's private harvesting room: only that room's harvesters,
  # the base, and that room's ore.
  defp room_cell_info(world, room, pos) do
    {x, y} = pos
    here = entities_in(world, room, pos)
    ore = World.resource_at(world, room, pos)

    cond do
      here != [] ->
        %{glyph: "🤖", bg: player_color(room).cell, title: "#{room}/H#{hd(here).id} @ #{x},#{y}"}

      pos == world.base ->
        %{glyph: "🏠", bg: "bg-slate-700", title: "Base @ #{x},#{y}"}

      ore > 0 ->
        %{glyph: "", bg: ore_bg(ore), title: "Ore: #{ore} @ #{x},#{y}"}

      true ->
        %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  # A cell in the shared market room: convoys (from any player), the sell-point,
  # and the entry. This is the only place players' entities can meet.
  defp market_cell_info(world, pos) do
    {x, y} = pos
    here = entities_in(world, :market, pos)

    cond do
      here != [] ->
        lead = Enum.min_by(here, & &1.id)
        owners = here |> Enum.map(& &1.owner) |> Enum.uniq() |> Enum.join(",")
        %{glyph: "🚚", bg: player_color(lead.owner).cell, title: "#{owners} @ #{x},#{y}"}

      pos == World.market(world) ->
        %{glyph: "🏪", bg: "bg-yellow-800", title: "Market @ #{x},#{y}"}

      pos == world.market_entry ->
        %{glyph: "🚪", bg: "bg-slate-700", title: "Convoy entry @ #{x},#{y}"}

      true ->
        %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  defp entities_in(world, room, {x, y}) do
    world.entities
    |> Enum.filter(&(&1.room == room and &1.x == x and &1.y == y))
    |> Enum.sort_by(& &1.id)
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
