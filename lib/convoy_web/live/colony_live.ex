defmodule ConvoyWeb.ColonyLive do
  @moduledoc """
  Spectator surface for Forge & Convoy (the colony game). Watch every player's
  colony — program one brain that mines, forges, builds, and ships convoys across
  the single shared **contested market**, where convoys collide and seize each
  other's shipments (the only PvP). Score is credits. A bundled `demo` colony runs
  out of the box; join by uploading your own bot.
  """
  use ConvoyWeb, :live_view

  alias Convoy.Engine.Colony.{World, Market, Region}
  alias Convoy.{Loader, Compile, Examples, Version}

  @speeds [{"0.5x", 800}, {"1x", 400}, {"2x", 200}, {"4x", 100}]

  # Metrics-modal time windows: {label, span in ticks} (minutes at the 1x 400ms
  # speed → ticks = minutes × 150). :all shows the full retained history.
  @frames [{"5m", 750}, {"15m", 2250}, {"30m", 4500}, {"all", :all}]

  # Languages for the getting-started panel: {id, label, file ext, lang param}.
  @langs [
    {:rust, "Rust", "rs", "rust"},
    {:tinygo, "Go", "go", "tinygo"},
    {:assemblyscript, "AssemblyScript", "ts", "assemblyscript"},
    {:zig, "Zig", "zig", "zig"},
    {:c, "C", "c", "c"},
    {:wat, "WAT", "wat", "wat"}
  ]

  @ext_lang %{".rs" => :rust, ".go" => :tinygo, ".ts" => :assemblyscript, ".zig" => :zig, ".c" => :c, ".wat" => :wat, ".wasm" => :wasm}

  @impl true
  def mount(params, _session, socket) do
    id = region_id(params)
    Region.ensure(id, seed: 1)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Convoy.PubSub, Region.topic(id))
      Region.observe(id, self())
    end

    {:ok,
     socket
     |> assign(:region_id, id)
     |> assign(:base_url, ConvoyWeb.Endpoint.url())
     |> assign(:speeds, @speeds)
     |> assign(:upload_player, "p1")
     |> assign(:my_player, nil)
     |> assign(:upload_error, nil)
     |> assign(:active_tab, :rust)
     |> assign(:show_help, false)
     |> assign(:show_ref, false)
     |> assign(:show_metrics, false)
     |> assign(:frames, @frames)
     |> assign(:metrics_frame, :all)
     |> assign(:hidden_colonies, MapSet.new())
     |> assign(:examples, Examples.all())
     |> assign(:open_example, nil)
     |> assign(:example_error, nil)
     |> assign_snapshot(Region.snapshot(id))
     |> allow_upload(:bot, accept: :any, max_entries: 1, max_file_size: 8_000_000)}
  end

  @impl true
  def handle_info({:colony_update, snap}, socket), do: {:noreply, assign_snapshot(socket, snap)}

  @impl true
  def handle_event("play", _, s), do: ctl(s, &Region.play/1)
  def handle_event("pause", _, s), do: ctl(s, &Region.pause/1)
  def handle_event("step", _, s), do: ctl(s, &Region.step/1)
  def handle_event("reset", _, s), do: ctl(s, &Region.reset(&1, 1))
  def handle_event("set_speed", %{"ms" => ms}, s), do: ctl(s, &Region.set_speed(&1, String.to_integer(ms)))
  def handle_event("set_tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  def handle_event("toggle_help", _, socket), do: {:noreply, update(socket, :show_help, &(not &1))}
  def handle_event("toggle_ref", _, socket), do: {:noreply, update(socket, :show_ref, &(not &1))}
  def handle_event("toggle_metrics", _, socket), do: {:noreply, update(socket, :show_metrics, &(not &1))}
  def handle_event("set_frame", %{"ticks" => "all"}, socket), do: {:noreply, assign(socket, :metrics_frame, :all)}
  def handle_event("set_frame", %{"ticks" => t}, socket), do: {:noreply, assign(socket, :metrics_frame, String.to_integer(t))}

  def handle_event("toggle_colony", %{"id" => id}, socket) do
    {:noreply, update(socket, :hidden_colonies, &if(MapSet.member?(&1, id), do: MapSet.delete(&1, id), else: MapSet.put(&1, id)))}
  end
  def handle_event("validate_upload", params, socket), do: {:noreply, assign(socket, :upload_player, clean(params["player"], socket.assigns.upload_player))}

  def handle_event("toggle_example", %{"id" => id}, socket) do
    {:noreply, update(socket, :open_example, &if(&1 == id, do: nil, else: id))}
  end

  def handle_event("play_example", %{"bot" => id} = params, socket) do
    case Examples.get(id) do
      nil ->
        {:noreply, assign(socket, :example_error, "unknown example: #{id}")}

      bot ->
        player = clean(params["player"], bot.id)
        {:noreply, submit_example(socket, bot, player)}
    end
  end

  def handle_event("upload_bot", params, socket) do
    id = socket.assigns.region_id
    player = clean(params["player"], socket.assigns.upload_player)

    consumed = consume_uploaded_entries(socket, :bot, fn %{path: path}, e -> {:ok, {File.read!(path), e.client_name}} end)

    socket =
      case consumed do
        [{content, name}] -> submit(socket, id, player, name, content)
        [] -> assign(socket, :upload_error, "Choose a file first.")
      end

    {:noreply, socket}
  end

  defp ctl(socket, fun) do
    fun.(socket.assigns.region_id)
    {:noreply, socket}
  end

  defp submit(socket, id, player, filename, content) do
    with {:ok, lang} <- lang_from_ext(filename),
         {:ok, _backend, exec, display} <- Loader.prepare(lang, content),
         :ok <- Region.submit_player(id, player, exec, display) do
      assign(socket, upload_error: nil, upload_player: player, my_player: player)
    else
      {:error, msg} -> assign(socket, :upload_error, msg)
    end
  end

  defp submit_example(socket, bot, player) do
    with {:ok, _backend, exec, display} <- Loader.prepare(bot.lang, bot.source),
         :ok <- Region.submit_player(socket.assigns.region_id, player, exec, display) do
      assign(socket, example_error: nil, my_player: player)
    else
      {:error, msg} -> assign(socket, :example_error, "#{bot.name}: #{msg}")
    end
  end

  defp lang_from_ext(filename) do
    case Map.get(@ext_lang, filename |> Path.extname() |> String.downcase()) do
      nil -> {:error, "unsupported file type — use .rs .go .ts .zig .c .wat .wasm"}
      lang -> {:ok, lang}
    end
  end

  defp clean(v, fallback) when is_binary(v) do
    case String.replace(v, ~r/[^a-zA-Z0-9_-]/, "") do
      "" -> fallback
      s -> s
    end
  end

  defp clean(_, fallback), do: fallback

  defp assign_snapshot(socket, snap) do
    socket
    |> assign(:status, snap.status)
    |> assign(:tick_ms, snap.tick_ms)
    |> assign(:tick, snap.tick)
    |> assign(:width, snap.width)
    |> assign(:height, snap.height)
    |> assign(:colonies, snap.colonies)
    |> assign(:market, snap.market)
    |> assign(:players, snap.players)
    |> assign(:history, Map.get(snap, :history, %{}))
    |> assign(:last_fuel, snap.last_fuel)
  end

  defp region_id(%{"region" => name}) when is_binary(name) and name != "" do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "") do
      "" -> "main"
      slug -> slug
    end
  end

  defp region_id(_), do: "main"

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="border-b border-slate-800 px-6 py-4 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-bold tracking-tight">
            <span class="text-amber-400">Forge</span> &amp; <span class="text-sky-400">Convoy</span>
            <span class="ml-2 text-xs font-normal text-slate-500">region {@region_id}</span>
            <.link navigate={~p"/admin"} class="ml-2 text-xs font-normal text-sky-400 hover:underline">admin</.link>
            <.link
              :if={url = Version.commit_url()}
              href={url}
              target="_blank"
              rel="noopener"
              class="ml-2 text-xs font-normal font-mono text-slate-600 hover:text-slate-400"
              title="running build — open this commit on GitHub"
            >
              v{Version.app_version()}<span :if={s = Version.short_sha()}> · {s}</span>
            </.link>
            <span
              :if={is_nil(Version.commit_url())}
              class="ml-2 text-xs font-normal font-mono text-slate-600"
              title="running build"
            >
              v{Version.app_version()}
            </span>
          </h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Program one brain per colony. Mine, forge, build, and run convoys across the contested market.
          </p>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <.stat label="tick" value={@tick} />
          <.stat label="🏪 credits" value={total(@players, :credits)} accent="text-yellow-300" />
          <.stat label="⚒ refined" value={total(@players, :refined)} accent="text-emerald-400" />
          <.stat label="players" value={length(@players)} accent="text-sky-400" />
          <.stat label="fuel/tick" value={@last_fuel} accent="text-fuchsia-400" />
          <span class={["px-2 py-0.5 rounded text-xs font-mono uppercase", @status == :running && "bg-emerald-500/20 text-emerald-300", @status != :running && "bg-slate-700 text-slate-300"]}>{@status}</span>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_340px] gap-6 p-6">
        <section class="space-y-5">
          <.controls status={@status} speeds={@speeds} tick_ms={@tick_ms} />
          <.market_view market={@market} players={@players} />
          <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <%= for {player, colony} <- Enum.sort_by(@colonies, fn {p, _} -> {-score(@players, p), p} end) do %>
              <.colony_view player={player} colony={colony} color={color(player)} mine={player == @my_player} />
            <% end %>
          </div>
        </section>

        <section class="space-y-4">
          <.scoreboard players={@players} my_player={@my_player} />
          <.submit_panel uploads={@uploads} upload_player={@upload_player} upload_error={@upload_error} />
          <.example_bots examples={@examples} open_example={@open_example} example_error={@example_error} my_player={@my_player} />
          <.getting_started show_help={@show_help} active_tab={@active_tab} region_id={@region_id} base_url={@base_url} />
          <.field_guide show_ref={@show_ref} />
          <.legend />
        </section>
      </div>

      <.metrics_modal
        show={@show_metrics}
        history={@history}
        players={@players}
        frame={@metrics_frame}
        frames={@frames}
        hidden={@hidden_colonies}
      />
    </div>
    """
  end

  # --- components ---

  attr :status, :atom, required: true
  attr :speeds, :list, required: true
  attr :tick_ms, :integer, required: true

  defp controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 text-sm">
      <button :if={@status != :running} phx-click="play" class="px-3 py-1 rounded-md bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-semibold">▶ Play</button>
      <button :if={@status == :running} phx-click="pause" class="px-3 py-1 rounded-md bg-slate-700 hover:bg-slate-600">⏸ Pause</button>
      <button phx-click="step" class="px-3 py-1 rounded-md bg-slate-700 hover:bg-slate-600">⏭ Step</button>
      <button phx-click="reset" data-confirm="Reset every colony in this region?" class="px-3 py-1 rounded-md bg-slate-800 hover:bg-slate-700">↻ Reset</button>
      <div class="flex items-center gap-1">
        <span class="text-xs text-slate-400 mr-1">speed</span>
        <%= for {label, ms} <- @speeds do %>
          <button phx-click="set_speed" phx-value-ms={ms} class={["px-2 py-0.5 rounded text-xs font-mono", @tick_ms == ms && "bg-sky-500 text-slate-950", @tick_ms != ms && "bg-slate-800 hover:bg-slate-700 text-slate-300"]}>{label}</button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :market, Market, required: true
  attr :players, :list, required: true

  defp market_view(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-yellow-700/40 rounded-lg p-3">
      <div class="flex items-center gap-2 mb-2">
        <span class="w-2.5 h-2.5 rounded-full bg-yellow-500"></span>
        <span class="text-xs font-mono text-yellow-300">the market</span>
        <span class="text-[10px] text-slate-500">· shared · contested · {length(@market.convoys)} convoy(s) en route</span>
      </div>
      <.grid width={@market.width} height={@market.height} cells={
        for y <- 0..(@market.height - 1), x <- 0..(@market.width - 1), do: market_cell(@market, {x, y})
      } max="900px" />
      <div :if={@market.events != []} class="mt-2 max-h-24 overflow-y-auto font-mono text-[11px] text-slate-400 space-y-0.5">
        <%= for ev <- @market.events do %><div>{ev}</div><% end %>
      </div>
    </div>
    """
  end

  attr :player, :string, required: true
  attr :colony, World, required: true
  attr :color, :map, required: true
  attr :mine, :boolean, default: false

  defp colony_view(assigns) do
    r = World.refine_report(assigns.colony)
    fill_pct = if r.cap > 0, do: min(round(assigns.colony.goods / r.cap * 100), 100), else: 0

    src_label =
      case r.refineries do
        0 -> "base forge"
        1 -> "1 refinery"
        n -> "#{n} refineries"
      end

    assigns = assign(assigns, refine: r, fill_pct: fill_pct, src_label: src_label)

    ~H"""
    <div class={["bg-slate-900 border rounded-lg p-3", if(@mine, do: "border-fuchsia-600/50", else: "border-slate-800")]}>
      <div class="flex items-center gap-2 mb-2">
        <span class={["w-2.5 h-2.5 rounded-full", @color.dot]}></span>
        <span class={["text-xs font-mono", @color.text]}>{@player}</span>
        <span :if={@mine} class="text-[10px] text-fuchsia-400">(you)</span>
        <span class="ml-auto font-mono text-[11px] text-slate-400">
          ⛏{@colony.ore} ◆{@colony.goods}/{@refine.cap} ⚒{@colony.refined_total} 🏪{@colony.credits}
        </span>
      </div>

      <div class="mb-2 space-y-1">
        <div class="flex items-center gap-2 text-[10px]">
          <span class="text-slate-500 w-16 shrink-0 whitespace-nowrap">📦 storage</span>
          <div class="flex-1 h-1.5 bg-slate-800 rounded overflow-hidden">
            <div class={["h-full", if(@refine.stall == :storage_full, do: "bg-rose-500", else: "bg-sky-500")]} style={"width: #{@fill_pct}%"}></div>
          </div>
          <span class="font-mono text-slate-500 w-16 text-right shrink-0">◆{@colony.goods}/{@refine.cap}</span>
        </div>
        <div class="flex items-center gap-2 text-[10px] font-mono">
          <span class="text-slate-500 w-16 shrink-0 whitespace-nowrap">⚙ refine</span>
          <span class="text-emerald-400">⛏→◆ {@refine.throughput}/tick</span>
          <span class="text-slate-600">· {@src_label}</span>
          <span class="ml-auto">
            <span :if={@refine.stall == :storage_full} class="text-amber-400">⚠ storage full</span>
            <span :if={@refine.stall == :no_ore} class="text-slate-600">idle · no ore</span>
            <span :if={is_nil(@refine.stall)} class="text-emerald-500/70">forging</span>
          </span>
        </div>
      </div>

      <.grid width={@colony.config.width} height={@colony.config.height} cells={
        for y <- 0..(@colony.config.height - 1), x <- 0..(@colony.config.width - 1), do: colony_cell(@colony, {x, y}, @color)
      } max="460px" />
      <% queued = Enum.filter(@colony.buildings, &(not &1.built)) %>
      <div :if={queued != []} class="mt-2 space-y-1">
        <%= for b <- queued do %>
          <% {_c, time} = World.build_spec(@colony, b.kind) || {0, 1} %>
          <div class="flex items-center gap-2 text-[11px]">
            <span class="font-mono text-slate-400 w-16">{World.kind_name(b.kind)}</span>
            <div class="flex-1 h-1.5 bg-slate-800 rounded overflow-hidden"><div class="h-full bg-amber-400" style={"width: #{round((time - b.remaining) / max(time, 1) * 100)}%"}></div></div>
            <span class="font-mono text-slate-500">{b.remaining}t</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :cells, :list, required: true
  attr :max, :string, default: "600px"

  defp grid(assigns) do
    ~H"""
    <div class="inline-grid gap-px bg-slate-800 p-px rounded-lg border border-slate-700" style={"grid-template-columns: repeat(#{@width}, minmax(0, 1fr)); max-width: #{@max};"}>
      <%= for c <- @cells do %>
        <div class={["aspect-square flex items-center justify-center text-[10px] relative", c.bg]} title={c.title}>{c.glyph}</div>
      <% end %>
    </div>
    """
  end

  attr :players, :list, required: true
  attr :my_player, :string, default: nil

  defp scoreboard(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-xs uppercase tracking-wide text-slate-400">Scoreboard · credits</div>
        <button phx-click="toggle_metrics" class="text-[11px] text-sky-400 hover:text-sky-300" title="metrics over time">📈 trends</button>
      </div>
      <%= if @players == [] do %>
        <div class="text-xs text-slate-500">No colonies yet — upload a bot to join.</div>
      <% end %>
      <div class="space-y-1">
        <%= for p <- @players do %>
          <% c = color(p.id) %>
          <div class="flex items-center gap-2 text-sm">
            <span class={["w-2.5 h-2.5 rounded-full", c.dot]}></span>
            <span class={["font-mono text-xs", c.text]}>{p.id}</span>
            <span :if={p.id == @my_player} class="text-[10px] text-fuchsia-400">(you)</span>
            <span :if={p.error} class="text-[10px] text-rose-400" title={p.error}>⛔</span>
            <span class="ml-auto flex items-center gap-2 font-mono text-xs">
              <span class="text-slate-400" title="harvesters · convoys en route">🤖{p.pop} 🚚{p.convoys}</span>
              <span class="text-sky-300" title="goods on hand">◆{p.goods}</span>
              <span class="text-emerald-300" title="lifetime refined">⚒{p.refined}</span>
              <span class="font-bold text-yellow-300 w-12 text-right" title="lifetime market credits (score)">🏪{p.credits}</span>
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :uploads, :any, required: true
  attr :upload_player, :string, required: true
  attr :upload_error, :string, default: nil

  defp submit_panel(assigns) do
    ~H"""
    <form phx-change="validate_upload" phx-submit="upload_bot" class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="flex items-center justify-between">
        <div class="text-xs uppercase tracking-wide text-slate-400">Join — submit a bot</div>
        <label class="text-xs text-slate-400 flex items-center gap-1">player
          <input type="text" name="player" value={@upload_player} class="w-24 bg-slate-950 border border-slate-700 rounded px-2 py-0.5 text-xs font-mono text-slate-100" />
        </label>
      </div>
      <p class="text-[11px] text-slate-500 mt-1">A colony bot exports <code>inbuf/outbuf/tick</code>. Upload <code>.rs .go .ts .zig .c .wat .wasm</code> — see <code>examples/colony.rs</code>.</p>
      <div class="flex flex-col gap-2 mt-2">
        <.live_file_input upload={@uploads.bot} class="text-xs text-slate-300 max-w-full" />
        <button type="submit" class="px-3 py-1 rounded-md bg-fuchsia-500 hover:bg-fuchsia-400 text-slate-950 font-semibold text-sm self-start">⬆ Submit</button>
      </div>
      <p :if={@upload_error} class="mt-2 text-[11px] font-mono text-rose-300 whitespace-pre-wrap">⛔ {@upload_error}</p>
    </form>
    """
  end

  attr :examples, :list, required: true
  attr :open_example, :string, default: nil
  attr :example_error, :string, default: nil
  attr :my_player, :string, default: nil

  defp example_bots(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="text-xs uppercase tracking-wide text-slate-400 mb-1">Example bots — read &amp; play</div>
      <p class="text-[11px] text-slate-500 mb-2">
        Complete, working colony brains. Read the source to learn the ABI, then drop one straight into the world as a player. Each runs the same loop with a different strategy.
      </p>
      <div class="space-y-2">
        <%= for bot <- @examples do %>
          <% open = @open_example == bot.id %>
          <div class={["border rounded-md p-2", if(@my_player == bot.id, do: "border-fuchsia-600/50", else: "border-slate-800")]}>
            <div class="flex items-center gap-2">
              <span class={["w-2.5 h-2.5 rounded-full shrink-0", color(bot.id).dot]}></span>
              <span class={["font-mono text-xs", color(bot.id).text]}>{bot.name}</span>
              <span
                :if={not bot.seeded?}
                class="text-[9px] font-mono uppercase tracking-wide text-amber-400/80 bg-amber-500/10 rounded px-1 py-px"
                title="not running by default — submit it to field this bot"
              >new</span>
              <span class="text-[10px] text-slate-500 truncate">· {bot.tagline}</span>
              <span class="ml-auto text-[10px] font-mono text-slate-600 uppercase">{bot.lang}</span>
            </div>
            <p class="text-[11px] text-slate-500 leading-snug mt-1">{bot.blurb}</p>
            <div class="flex items-center gap-2 mt-2">
              <button
                type="button"
                phx-click="toggle_example"
                phx-value-id={bot.id}
                class="px-2 py-0.5 rounded bg-slate-800 hover:bg-slate-700 text-slate-300 text-[11px] font-mono"
              >
                {if open, do: "▲ hide code", else: "▼ view code"}
              </button>
              <form phx-submit="play_example" class="flex items-center gap-1 ml-auto">
                <input type="hidden" name="bot" value={bot.id} />
                <input
                  type="text"
                  name="player"
                  value={bot.id}
                  class="w-20 bg-slate-950 border border-slate-700 rounded px-1.5 py-0.5 text-[11px] font-mono text-slate-100"
                  title="player id to join as (it'll overwrite an existing colony with that id)"
                />
                <button type="submit" class="px-2 py-0.5 rounded bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-semibold text-[11px]">▶ Play</button>
              </form>
            </div>
            <pre :if={open} class="bg-slate-950 rounded p-2 mt-2 text-[10px] leading-snug text-emerald-200 overflow-auto max-h-80">{bot.source}</pre>
          </div>
        <% end %>
      </div>
      <p :if={@example_error} class="mt-2 text-[11px] font-mono text-rose-300 whitespace-pre-wrap">⛔ {@example_error}</p>
    </div>
    """
  end

  attr :show_help, :boolean, required: true
  attr :active_tab, :atom, required: true
  attr :region_id, :string, required: true
  attr :base_url, :string, required: true

  defp getting_started(assigns) do
    {_, _, ext, lang} = Enum.find(@langs, fn {id, _, _, _} -> id == assigns.active_tab end)
    assigns = assign(assigns, ext: ext, lang: lang, code: Compile.template(assigns.active_tab), langs: @langs)

    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-xs text-slate-400">
      <button type="button" phx-click="toggle_help" class="w-full flex items-center justify-between text-slate-300 font-semibold">
        <span>Getting started — write a bot</span>
        <span class="text-slate-500">{if @show_help, do: "▲", else: "▼"}</span>
      </button>
      <div :if={@show_help} class="mt-2 space-y-2">
        <p>
          Your bot is a tiny WebAssembly module that exports <code class="text-fuchsia-300">inbuf</code>/<code class="text-fuchsia-300">outbuf</code>/<code class="text-fuchsia-300">tick</code>.
          Each tick the sim writes your colony's view into <code>inbuf</code>, calls <code>tick</code>, and reads a list of commands from <code>outbuf</code>.
        </p>

        <div class="flex flex-wrap gap-1">
          <%= for {id, label, _e, _l} <- @langs do %>
            <button type="button" phx-click="set_tab" phx-value-tab={id} class={[
              "px-2 py-0.5 rounded text-xs font-mono",
              @active_tab == id && "bg-emerald-500 text-slate-950",
              @active_tab != id && "bg-slate-800 hover:bg-slate-700 text-slate-300"
            ]}>{label}</button>
          <% end %>
        </div>

        <div class="text-[10px] uppercase tracking-wide text-slate-500 mt-1">starter · bot.{@ext}</div>
        <pre class="bg-slate-950 rounded p-2 text-[10.5px] leading-snug text-emerald-200 overflow-auto max-h-72">{@code}</pre>

        <div class="text-[10px] uppercase tracking-wide text-slate-500">send it</div>
        <pre class="bg-slate-950 rounded p-2 text-[10.5px] text-sky-200 overflow-x-auto whitespace-pre-wrap">curl --data-binary @bot.{@ext} -H 'Content-Type: application/octet-stream' {@base_url}/api/region/{@region_id}/upload?player=YOU&amp;lang={@lang}</pre>
        <div class="text-[10px] text-slate-500">or upload it with the panel above, or: <code>mix convoy.run bot.{@ext} --region {@region_id} --player YOU</code></div>

        <div class="pt-1 border-t border-slate-800">
          <div class="text-slate-300 mb-1">commands your <code>tick</code> can emit (16-byte records)</div>
          <code class="text-fuchsia-300 text-[10.5px] leading-relaxed block">
            1 harvest(unit) · 2 move(unit, dx, dy) · 3 transfer(unit, building) · 4 build(kind, x«8|y) · 5 spawn(kind) · 7 launch_convoy · 8 defend(convoy) · 9 hunt(convoy, dx, dy)
          </code>
          <p class="text-slate-500 mt-1">Full wire format: <code>lib/convoy/engine/colony_abi.ex</code>. Full reference bot: <code>examples/colony.rs</code> (builds refineries, spawns, ships).</p>
        </div>
      </div>
    </div>
    """
  end

  attr :show_ref, :boolean, required: true

  defp field_guide(assigns) do
    assigns = assign(assigns, cfg: World.default_config())

    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-xs text-slate-400">
      <button type="button" phx-click="toggle_ref" class="w-full flex items-center justify-between text-slate-300 font-semibold">
        <span>Field guide — buildings, units &amp; actions</span>
        <span class="text-slate-500">{if @show_ref, do: "▲", else: "▼"}</span>
      </button>
      <div :if={@show_ref} class="mt-2 space-y-3">
        <p class="text-[11px] text-slate-500">
          The loop: harvesters <span class="text-amber-400">mine ore</span> → a refinery (or the spawner's built-in forge)
          <span class="text-emerald-300">forges it into goods</span> → spend goods to build, spawn, and
          <span class="text-yellow-300">load convoys</span> that cross the contested market for <span class="text-yellow-300">credits</span> (the score).
        </p>

        <div>
          <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">Buildings</div>
          <div class="space-y-1.5">
            <.guide_row glyph="🏠" name="Spawner">
              Your base at (0,0), pre-built. Harvesters spawn here and dump cargo into it. Has a tiny built-in forge
              (+{@cfg.base_refine_rate} good/tick) so you can bootstrap with no refinery. Sets pop cap
              ({@cfg.pop_cap_base} base, +{@cfg.pop_cap_step} per level).
            </.guide_row>
            <.guide_row glyph="⚙" name="Refinery">
              Forges ore → goods at {@cfg.refine_rate}/tick each (more with level). Costs {@cfg.build_cost_refinery} goods,
              {@cfg.build_time_refinery} ticks to build.
            </.guide_row>
            <.guide_row glyph="📦" name="Storage">
              Raises your goods cap by {@cfg.storage_step} (base {@cfg.storage_base}). Costs {@cfg.build_cost_storage} goods,
              {@cfg.build_time_storage} ticks. Goods over the cap aren't forged.
            </.guide_row>
          </div>
        </div>

        <div>
          <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">Units &amp; convoys</div>
          <div class="space-y-1.5">
            <.guide_row glyph="🤖" name="Harvester">
              Mines ore on its cell (holds {@cfg.cargo_max}), hauls it to an adjacent building. Spawn for
              {@cfg.spawn_cost_harvester} goods, {@cfg.spawn_time_harvester} ticks. You start with {@cfg.start_units}.
            </.guide_row>
            <.guide_row glyph="🚚" name="Convoy">
              Loaded with {@cfg.shipment_size} goods, worth {@cfg.shipment_value} credits if it reaches the market.
              Rivals' convoys can seize its cargo en route — the only PvP.
            </.guide_row>
          </div>
        </div>

        <div>
          <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">Actions your <code>tick</code> can emit</div>
          <div class="space-y-1">
            <.action_row op="1" sig="harvest(unit)">mine the ore under <code>unit</code> into its cargo</.action_row>
            <.action_row op="2" sig="move(unit, dx, dy)">step <code>unit</code> (or a convoy) one cell by the sign of dx/dy</.action_row>
            <.action_row op="3" sig="transfer(unit, building)">dump <code>unit</code>'s cargo into an adjacent built building</.action_row>
            <.action_row op="4" sig="build(kind, x«8|y)">queue a building at packed coords (spends goods)</.action_row>
            <.action_row op="5" sig="spawn(kind)">queue a unit at the spawner (spends goods, pop-capped)</.action_row>
            <.action_row op="7" sig="launch_convoy">load a convoy and send it into the market</.action_row>
            <.action_row op="8" sig="defend(convoy)">hold position; an escort — seizes a <em>hunter</em> sharing its cell, but lets passive convoys pass</.action_row>
            <.action_row op="9" sig="hunt(convoy, dx, dy)">raider stance; steer one cell by sign(dx/dy) (or 0,0 to auto-home). Seizes a passive convoy you land on — but loses your cargo to a defender there</.action_row>
          </div>
          <p class="text-[10px] text-slate-500 mt-1.5">
            <code>kind</code>: buildings 0 spawner · 1 refinery · 2 storage. Units 0 harvester. Op 0 is idle; full wire format in
            <code>lib/convoy/engine/colony_abi.ex</code>.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :glyph, :string, required: true
  attr :name, :string, required: true
  slot :inner_block, required: true

  defp guide_row(assigns) do
    ~H"""
    <div class="flex gap-2">
      <span class="w-4 text-center text-slate-300 shrink-0">{@glyph}</span>
      <div class="text-[11px] leading-snug"><span class="text-slate-300 font-medium">{@name}</span> — {render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :op, :string, required: true
  attr :sig, :string, required: true
  slot :inner_block, required: true

  defp action_row(assigns) do
    ~H"""
    <div class="flex gap-2 text-[11px] leading-snug">
      <span class="font-mono text-slate-600 w-3 text-right shrink-0">{@op}</span>
      <div><code class="text-fuchsia-300">{@sig}</code> <span class="text-slate-500">— {render_slot(@inner_block)}</span></div>
    </div>
    """
  end

  defp legend(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-[11px] text-slate-500 leading-relaxed">
      <span class="text-slate-300">🏠</span> spawner · <span class="text-slate-300">⚙</span> refinery · <span class="text-slate-300">📦</span> storage · <span class="text-slate-300">🤖</span> harvester · <span class="text-amber-400">▓</span> ore · <span class="text-yellow-300">🚚</span> convoy · <span class="text-yellow-300">🏪</span> market. Ship convoys across the market for credits; rivals can ambush them.
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

  # --- metrics over time (server-rendered SVG line charts) ---

  @chart_w 300
  @chart_h 80

  attr :show, :boolean, required: true
  attr :history, :map, required: true
  attr :players, :list, required: true
  attr :frame, :any, required: true
  attr :frames, :list, required: true
  attr :hidden, :any, required: true

  defp metrics_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="toggle_metrics"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-slate-950/80 backdrop-blur-sm" phx-click="toggle_metrics"></div>
      <div class="relative bg-slate-900 border border-slate-700 rounded-xl shadow-2xl w-full max-w-3xl max-h-[90vh] overflow-y-auto p-5">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-bold">📈 Metrics over time</h2>
          <button phx-click="toggle_metrics" class="text-slate-400 hover:text-slate-200 text-xl leading-none" title="close (Esc)">✕</button>
        </div>

        <%= if @players == [] or not Enum.any?(@players, &Map.has_key?(@history, &1.id)) do %>
          <div class="text-sm text-slate-500">No history yet — let the sim run a few ticks, then reopen.</div>
        <% else %>
          <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
            <div class="flex flex-wrap gap-3 text-xs">
              <%= for p <- @players do %>
                <% c = color(p.id) %>
                <% off = MapSet.member?(@hidden, p.id) %>
                <button
                  phx-click="toggle_colony"
                  phx-value-id={p.id}
                  class={["flex items-center gap-1.5 hover:opacity-100", off && "opacity-40"]}
                  title={"#{if off, do: "show", else: "hide"} #{p.id}"}
                >
                  <span class={["w-2.5 h-2.5 rounded-full", c.dot]}></span>
                  <span class={["font-mono", c.text, off && "line-through"]}>{p.id}</span>
                </button>
              <% end %>
            </div>
            <div class="flex items-center gap-1 text-xs">
              <span class="text-slate-500 mr-1">window</span>
              <%= for {label, val} <- @frames do %>
                <button
                  phx-click="set_frame"
                  phx-value-ticks={frame_param(val)}
                  class={[
                    "px-2 py-0.5 rounded font-mono",
                    @frame == val && "bg-sky-500 text-slate-950 font-semibold",
                    @frame != val && "bg-slate-800 text-slate-300 hover:bg-slate-700"
                  ]}
                >{label}</button>
              <% end %>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.metric_chart title="🏪 Credits (score)" key={:credits} history={@history} players={@players} frame={@frame} hidden={@hidden} />
            <.metric_chart title="⚒ Refined" key={:refined} history={@history} players={@players} frame={@frame} hidden={@hidden} />
            <.metric_chart title="🤖 Population" key={:pop} history={@history} players={@players} frame={@frame} hidden={@hidden} />
            <.metric_chart title="🚚 Convoys" key={:convoys} history={@history} players={@players} frame={@frame} hidden={@hidden} />
          </div>

          <p class="text-[11px] text-slate-600 mt-4">Click a colony to hide it; pick a window above (minutes at 1x). Left → right is oldest → now.</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :key, :atom, required: true
  attr :history, :map, required: true
  attr :players, :list, required: true
  attr :frame, :any, required: true
  attr :hidden, :any, required: true

  defp metric_chart(assigns) do
    visible = Enum.reject(assigns.players, &MapSet.member?(assigns.hidden, &1.id))

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:maxv, chart_max(assigns.history, visible, assigns.key, assigns.frame))

    ~H"""
    <div class="bg-slate-950 border border-slate-800 rounded-lg p-3">
      <div class="flex items-center justify-between mb-1">
        <div class="text-xs uppercase tracking-wide text-slate-400">{@title}</div>
        <div class="text-[10px] font-mono text-slate-600">peak {@maxv}</div>
      </div>
      <svg viewBox="0 0 300 80" preserveAspectRatio="none" class="w-full h-24">
        <line x1="0" y1="80" x2="300" y2="80" stroke="#1e293b" stroke-width="1" />
        <%= for p <- @visible do %>
          <polyline
            points={polyline(series_points(@history, p.id, @frame), @key, @maxv)}
            fill="none"
            stroke={color(p.id).stroke}
            stroke-width="1.5"
            stroke-linejoin="round"
            vector-effect="non-scaling-stroke"
          />
        <% end %>
      </svg>
    </div>
    """
  end

  # history is stored newest-first; clip to the window, then reverse to plot
  # oldest → newest, left → right.
  defp series_points(history, pid, frame), do: history |> Map.get(pid, []) |> window(frame) |> Enum.reverse()

  # Keep only the points within `ticks` of the latest sample (list is newest-first,
  # so t is descending and take_while stops at the window edge).
  defp window(points, :all), do: points
  defp window([], _ticks), do: []
  defp window([latest | _] = points, ticks), do: Enum.take_while(points, &(latest.t - &1.t <= ticks))

  defp chart_max(history, visible, key, frame) do
    visible
    |> Enum.flat_map(fn p -> history |> Map.get(p.id, []) |> window(frame) end)
    |> Enum.map(&Map.get(&1, key, 0))
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp frame_param(:all), do: "all"
  defp frame_param(ticks), do: Integer.to_string(ticks)

  defp polyline([], _key, _maxv), do: ""

  defp polyline([pt], key, maxv) do
    y = yval(pt, key, maxv)
    "0,#{y} #{@chart_w},#{y}"
  end

  defp polyline(points, key, maxv) do
    n = length(points)

    points
    |> Enum.with_index()
    |> Enum.map(fn {pt, i} -> "#{fmt(i * @chart_w / (n - 1))},#{yval(pt, key, maxv)}" end)
    |> Enum.join(" ")
  end

  defp yval(pt, key, maxv), do: fmt(@chart_h - Map.get(pt, key, 0) / maxv * @chart_h)
  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  # --- cell rendering ---

  defp colony_cell(colony, {x, y} = pos, color) do
    units = Enum.filter(colony.units, &(&1.x == x and &1.y == y))
    building = World.building_at(colony, pos)
    ore = World.deposit_at(colony, pos)

    cond do
      units != [] ->
        n = length(units)
        %{glyph: "🤖", bg: color.cell, title: "harvester @ #{x},#{y}#{if n > 1, do: " (x#{n})", else: ""}"}

      building != nil ->
        dim = if building.built, do: "", else: " opacity-40"
        %{glyph: bglyph(building.kind), bg: "bg-slate-700#{dim}", title: "#{World.kind_name(building.kind)} @ #{x},#{y}#{if building.built, do: "", else: " (#{building.remaining}t)"}"}

      ore > 0 -> %{glyph: "", bg: ore_bg(ore), title: "ore #{ore} @ #{x},#{y}"}
      true -> %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  defp market_cell(market, {x, y} = pos) do
    here = Enum.filter(market.convoys, &(&1.x == x and &1.y == y))

    cond do
      here != [] ->
        lead = Enum.min_by(here, & &1.id)
        owners = here |> Enum.map(& &1.owner) |> Enum.uniq()
        %{glyph: "🚚", bg: color(lead.owner).cell, title: "#{Enum.join(owners, ",")} @ #{x},#{y}"}

      pos == market.market -> %{glyph: "🏪", bg: "bg-yellow-800", title: "market @ #{x},#{y}"}
      pos == market.entry -> %{glyph: "🚪", bg: "bg-slate-700", title: "convoy entry @ #{x},#{y}"}
      true -> %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  defp bglyph(0), do: "🏠"
  defp bglyph(1), do: "⚙"
  defp bglyph(2), do: "📦"
  defp bglyph(3), do: "⚒"
  defp bglyph(_), do: "▫"

  defp ore_bg(a) when a >= 30, do: "bg-amber-500"
  defp ore_bg(a) when a >= 15, do: "bg-amber-600"
  defp ore_bg(a) when a >= 5, do: "bg-amber-700"
  defp ore_bg(_), do: "bg-amber-800"

  # --- view helpers ---

  defp total(players, key), do: players |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum()
  defp score(players, id), do: (Enum.find(players, &(&1.id == id)) || %{credits: 0}).credits

  @palette [
    %{dot: "bg-emerald-400", text: "text-emerald-300", cell: "bg-emerald-600", stroke: "#34d399"},
    %{dot: "bg-sky-400", text: "text-sky-300", cell: "bg-sky-600", stroke: "#38bdf8"},
    %{dot: "bg-fuchsia-400", text: "text-fuchsia-300", cell: "bg-fuchsia-600", stroke: "#e879f9"},
    %{dot: "bg-amber-400", text: "text-amber-300", cell: "bg-amber-600", stroke: "#fbbf24"},
    %{dot: "bg-rose-400", text: "text-rose-300", cell: "bg-rose-600", stroke: "#fb7185"},
    %{dot: "bg-cyan-400", text: "text-cyan-300", cell: "bg-cyan-600", stroke: "#22d3ee"}
  ]

  defp color(player_id), do: Enum.at(@palette, rem(:erlang.phash2(player_id), length(@palette)))
end
