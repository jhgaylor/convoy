defmodule ConvoyWeb.ColonyLive do
  @moduledoc """
  Spectator surface for Forge & Convoy **v2 (the colony model)**. Watch a colony
  you program with one brain grow over time: harvesters mine, the forge turns ore
  into goods, and the brain spends goods to build (refineries, storage) and spawn
  more units. The page runs a bundled default bot out of the box; upload your own
  to take over.
  """
  use ConvoyWeb, :live_view

  alias Convoy.Engine.Colony.{World, Region}
  alias Convoy.Loader

  @speeds [{"0.5x", 800}, {"1x", 400}, {"2x", 200}, {"4x", 100}]

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
    id = region_id(params)
    Region.ensure(id, seed: 1)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Convoy.PubSub, Region.topic(id))
      Region.observe(id, self())
    end

    {:ok,
     socket
     |> assign(:region_id, id)
     |> assign(:speeds, @speeds)
     |> assign(:upload_error, nil)
     |> assign_snapshot(Region.snapshot(id))
     |> allow_upload(:bot, accept: :any, max_entries: 1, max_file_size: 8_000_000)}
  end

  @impl true
  def handle_info({:colony_update, snap}, socket), do: {:noreply, assign_snapshot(socket, snap)}

  @impl true
  def handle_event("play", _, socket), do: ctl(socket, &Region.play/1)
  def handle_event("pause", _, socket), do: ctl(socket, &Region.pause/1)
  def handle_event("step", _, socket), do: ctl(socket, &Region.step/1)
  def handle_event("reset", _, socket), do: ctl(socket, &Region.reset(&1, 1))
  def handle_event("set_speed", %{"ms" => ms}, socket), do: ctl(socket, &Region.set_speed(&1, String.to_integer(ms)))
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload_bot", _params, socket) do
    id = socket.assigns.region_id

    consumed =
      consume_uploaded_entries(socket, :bot, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_name}}
      end)

    socket =
      case consumed do
        [{content, name}] -> submit(socket, id, name, content)
        [] -> assign(socket, :upload_error, "Choose a file first.")
      end

    {:noreply, socket}
  end

  defp ctl(socket, fun) do
    fun.(socket.assigns.region_id)
    {:noreply, socket}
  end

  defp submit(socket, id, filename, content) do
    with {:ok, lang} <- lang_from_ext(filename),
         {:ok, _backend, exec, display} <- Loader.prepare(lang, content),
         :ok <- Region.submit_bot(id, exec, display) do
      assign(socket, :upload_error, nil)
    else
      {:error, msg} -> assign(socket, :upload_error, msg)
    end
  end

  defp lang_from_ext(filename) do
    case Map.get(@ext_lang, filename |> Path.extname() |> String.downcase()) do
      nil -> {:error, "unsupported file type — use .rs .go .ts .zig .c .wat .wasm"}
      lang -> {:ok, lang}
    end
  end

  defp assign_snapshot(socket, snap) do
    socket
    |> assign(:world, snap.world)
    |> assign(:status, snap.status)
    |> assign(:tick_ms, snap.tick_ms)
    |> assign(:has_bot, snap.has_bot)
    |> assign(:bot_display, snap.bot_display)
    |> assign(:last_fuel, snap.last_fuel)
    |> assign(:last_error, Map.get(snap, :last_error))
    |> assign(:pop, snap.pop)
    |> assign(:pop_cap, snap.pop_cap)
    |> assign(:storage_cap, snap.storage_cap)
    |> assign(:ore_remaining, snap.ore_remaining)
  end

  defp region_id(%{"region" => name}) when is_binary(name) and name != "" do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "") do
      "" -> "main"
      slug -> slug
    end
  end

  defp region_id(_), do: "main"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="border-b border-slate-800 px-6 py-4 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-bold tracking-tight">
            <span class="text-amber-400">Forge</span>
            &amp; <span class="text-sky-400">Convoy</span>
            <span class="ml-2 text-xs font-normal text-emerald-400/80 uppercase tracking-widest">colony</span>
            <span class="ml-2 text-xs font-normal text-slate-500">region {@region_id}</span>
          </h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Program one brain. Watch a colony mine, forge, build, and grow.
          </p>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <.stat label="tick" value={@world.tick} />
          <.stat label="⛏ ore" value={@world.ore} accent="text-amber-300" />
          <.stat label="◆ goods" value={"#{@world.goods}/#{@storage_cap}"} accent="text-sky-300" />
          <.stat label="⚒ refined" value={@world.refined_total} accent="text-emerald-400" />
          <.stat label="🚚 pop" value={"#{@pop}/#{@pop_cap}"} accent="text-fuchsia-300" />
          <.stat label="fuel/tick" value={@last_fuel} accent="text-fuchsia-400" />
          <span class={[
            "px-2 py-0.5 rounded text-xs font-mono uppercase",
            @status == :running && "bg-emerald-500/20 text-emerald-300",
            @status != :running && "bg-slate-700 text-slate-300"
          ]}>{@status}</span>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_320px] gap-6 p-6">
        <section class="space-y-4">
          <.controls status={@status} speeds={@speeds} tick_ms={@tick_ms} />
          <.colony_grid world={@world} />
          <.event_log world={@world} />
        </section>

        <section class="space-y-4">
          <.colony_panel world={@world} pop={@pop} pop_cap={@pop_cap} storage_cap={@storage_cap} />
          <.bot_panel
            has_bot={@has_bot}
            bot_display={@bot_display}
            uploads={@uploads}
            upload_error={@upload_error}
            last_error={@last_error}
          />
          <.legend />
        </section>
      </div>
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
      <button phx-click="reset" data-confirm="Reset this colony?" class="px-3 py-1 rounded-md bg-slate-800 hover:bg-slate-700">↻ Reset</button>
      <div class="flex items-center gap-1">
        <span class="text-xs text-slate-400 mr-1">speed</span>
        <%= for {label, ms} <- @speeds do %>
          <button phx-click="set_speed" phx-value-ms={ms} class={[
            "px-2 py-0.5 rounded text-xs font-mono",
            @tick_ms == ms && "bg-sky-500 text-slate-950",
            @tick_ms != ms && "bg-slate-800 hover:bg-slate-700 text-slate-300"
          ]}>{label}</button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :world, World, required: true

  defp colony_grid(assigns) do
    assigns =
      assign(assigns, :cells,
        for(
          y <- 0..(assigns.world.config.height - 1),
          x <- 0..(assigns.world.config.width - 1),
          do: cell_info(assigns.world, {x, y})
        )
      )

    ~H"""
    <div
      class="inline-grid gap-px bg-slate-800 p-px rounded-lg border border-slate-700"
      style={"grid-template-columns: repeat(#{@world.config.width}, minmax(0, 1fr)); max-width: 720px;"}
    >
      <%= for c <- @cells do %>
        <div class={["aspect-square flex items-center justify-center text-xs relative", c.bg]} title={c.title}>
          {c.glyph}
        </div>
      <% end %>
    </div>
    """
  end

  attr :world, World, required: true
  attr :pop, :integer, required: true
  attr :pop_cap, :integer, required: true
  attr :storage_cap, :integer, required: true

  defp colony_panel(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3 space-y-3">
      <div class="text-xs uppercase tracking-wide text-slate-400">Colony</div>

      <div class="grid grid-cols-2 gap-2 text-sm">
        <.kv k="⛏ ore (raw)" v={@world.ore} />
        <.kv k="◆ goods" v={"#{@world.goods} / #{@storage_cap}"} />
        <.kv k="⚒ refined" v={@world.refined_total} />
        <.kv k="🚚 population" v={"#{@pop} / #{@pop_cap}"} />
        <.kv k="ore in ground" v={World.ore_remaining(@world)} />
        <.kv k="buildings" v={length(@world.buildings)} />
      </div>

      <div>
        <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">Build queue</div>
        <% queued = Enum.filter(@world.buildings, &(not &1.built)) %>
        <%= if queued == [] do %>
          <div class="text-xs text-slate-600">— idle —</div>
        <% else %>
          <%= for b <- queued do %>
            <% {_cost, time} = World.build_spec(@world, b.kind) || {0, 1} %>
            <div class="flex items-center gap-2 text-xs mb-1">
              <span class="font-mono text-slate-300 w-20">{World.kind_name(b.kind)}</span>
              <div class="flex-1 h-1.5 bg-slate-800 rounded overflow-hidden">
                <div class="h-full bg-amber-400" style={"width: #{round((time - b.remaining) / max(time, 1) * 100)}%"}></div>
              </div>
              <span class="font-mono text-slate-500 w-12 text-right">{b.remaining}t</span>
            </div>
          <% end %>
        <% end %>
      </div>

      <div :if={@world.spawn_queue != []}>
        <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">Spawning</div>
        <%= for s <- @world.spawn_queue do %>
          <div class="text-xs font-mono text-slate-400">{World.unit_kind_name(s.kind)} · {s.remaining}t</div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :has_bot, :boolean, required: true
  attr :bot_display, :string, default: nil
  attr :uploads, :any, required: true
  attr :upload_error, :string, default: nil
  attr :last_error, :string, default: nil

  defp bot_panel(assigns) do
    ~H"""
    <form phx-change="validate_upload" phx-submit="upload_bot" class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="text-xs uppercase tracking-wide text-slate-400 mb-1">The brain</div>
      <p class="text-[11px] text-slate-500 mb-2">
        <%= if @has_bot do %>
          Running: <span class="text-emerald-300 font-mono">{@bot_display}</span>. Upload a file to take over.
        <% else %>
          No brain loaded — upload a colony bot to drive this colony.
        <% end %>
      </p>
      <div class="flex flex-col gap-2">
        <.live_file_input upload={@uploads.bot} class="text-xs text-slate-300 max-w-full" />
        <button type="submit" class="px-3 py-1 rounded-md bg-fuchsia-500 hover:bg-fuchsia-400 text-slate-950 font-semibold text-sm self-start">⬆ Submit</button>
      </div>
      <p class="text-[10px] text-slate-500 mt-1">
        Colony ABI: exports <code>inbuf/outbuf/tick</code>. See <code>examples/colony.rs</code>.
      </p>
      <p :if={@upload_error} class="mt-2 text-[11px] font-mono text-rose-300 whitespace-pre-wrap">⛔ {@upload_error}</p>
      <p :if={@last_error} class="mt-2 text-[11px] font-mono text-rose-300 whitespace-pre-wrap">bot error: {@last_error}</p>
    </form>
    """
  end

  defp legend(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3 text-[11px] text-slate-500 leading-relaxed">
      <span class="text-slate-300">🏠</span> spawner ·
      <span class="text-slate-300">⚙</span> refinery ·
      <span class="text-slate-300">📦</span> storage ·
      <span class="text-slate-300">🤖</span> harvester ·
      <span class="text-amber-400">▓</span> ore deposit ·
      a dimmed building is under construction.
    </div>
    """
  end

  attr :world, World, required: true

  defp event_log(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class="text-xs uppercase tracking-wide text-slate-400 mb-2">Event log</div>
      <div class="space-y-1 max-h-40 overflow-y-auto font-mono text-xs text-slate-400">
        <%= for ev <- @world.events do %>
          <div>{ev}</div>
        <% end %>
      </div>
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

  attr :k, :string, required: true
  attr :v, :any, required: true

  defp kv(assigns) do
    ~H"""
    <div class="flex items-center justify-between bg-slate-950/50 rounded px-2 py-1">
      <span class="text-[11px] text-slate-400">{@k}</span>
      <span class="font-mono text-slate-200">{@v}</span>
    </div>
    """
  end

  # --- cell rendering: units on top, then buildings, then deposits ---

  defp cell_info(world, {x, y} = pos) do
    units = Enum.filter(world.units, &(&1.x == x and &1.y == y))
    building = World.building_at(world, pos)
    ore = World.deposit_at(world, pos)

    cond do
      units != [] ->
        u = hd(units)
        extra = if length(units) > 1, do: " (+#{length(units) - 1})", else: ""
        %{glyph: "🤖", bg: "bg-emerald-600/70", title: "harvester #{u.id} @ #{x},#{y}, cargo #{u.cargo}/#{u.cargo_max}#{extra}"}

      building != nil ->
        dim = if building.built, do: "", else: " opacity-40"
        %{glyph: building_glyph(building.kind), bg: "bg-slate-700#{dim}", title: "#{World.kind_name(building.kind)} @ #{x},#{y}#{if building.built, do: "", else: " (building, #{building.remaining}t)"}"}

      ore > 0 ->
        %{glyph: "", bg: ore_bg(ore), title: "ore: #{ore} @ #{x},#{y}"}

      true ->
        %{glyph: "", bg: "bg-slate-900", title: ""}
    end
  end

  defp building_glyph(0), do: "🏠"
  defp building_glyph(1), do: "⚙"
  defp building_glyph(2), do: "📦"
  defp building_glyph(3), do: "⚒"
  defp building_glyph(_), do: "▫"

  defp ore_bg(a) when a >= 30, do: "bg-amber-500"
  defp ore_bg(a) when a >= 15, do: "bg-amber-600"
  defp ore_bg(a) when a >= 5, do: "bg-amber-700"
  defp ore_bg(_), do: "bg-amber-800"
end
