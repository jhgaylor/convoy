defmodule ConvoyWeb.AdminLive do
  @moduledoc """
  World overview / admin page: every running simulation at a glance, with
  system-wide and per-simulation utilization, and controls to stop or delete a
  region. Polls once a second.

  Utilization sources: BEAM scheduler utilization (`:scheduler`), VM memory and
  process count (`:erlang`), and per-region process stats (the region GenServer
  plus its WASM instance processes) via `Convoy.Engine.region_stats/1`.
  Reductions are cumulative, so we diff them across polls into a per-second rate.
  """
  use ConvoyWeb, :live_view

  alias Convoy.Engine

  @interval_ms 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@interval_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:prev_reductions, %{})
     |> assign(:prev_sched, sched_sample())
     |> assign(:expanded, MapSet.new())
     |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("stop", %{"id" => id}, socket) do
    Engine.stop_region(id)
    {:noreply, refresh(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Engine.delete_region(id)
    {:noreply, refresh(socket)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    # Start the region; it restores its snapshot and resumes its prior status.
    Engine.ensure_region(id, persist: true)
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("kick", %{"region" => region, "player" => player}, socket) do
    Engine.kick_player(region, player)
    {:noreply, refresh(socket)}
  end

  # Retune a region's game-balance knobs live. The Region validates + coerces the
  # raw form strings, merges them into the world's config, and the change takes
  # effect on the very next tick (real-time). A no-op for a stopped region.
  def handle_event("set_config", %{"region" => region, "config" => config}, socket) do
    Engine.set_config(region, config)
    {:noreply, refresh(socket)}
  end

  # The tweakable game values, grouped for the editor. Order here drives render order.
  @config_fields [
    {"World & resources",
     [
       {:resource_nodes, "Ore nodes / room"},
       {:resource_amount, "Ore per node"},
       {:replenish_threshold, "Replenish at ≤ nodes"}
     ]},
    {"Harvesters",
     [
       {:harvesters, "Harvesters / player"},
       {:cargo_max, "Base cargo capacity"},
       {:cargo_step, "Cargo per upgrade"}
     ]},
    {"Forge & tech ladder",
     [
       {:base_refine_rate, "Refine / tick"},
       {:base_fuel_budget, "Base fuel budget"},
       {:fuel_step, "Fuel per upgrade"},
       {:max_fuel_level, "Max fuel level"},
       {:build_cost_refine, "Refine upgrade cost"},
       {:build_cost_cargo, "Cargo upgrade cost"},
       {:build_cost_fuel, "Fuel upgrade cost"}
     ]},
    {"Convoys & market",
     [
       {:shipment_size, "Shipment size (goods)"},
       {:shipment_value, "Shipment value (credits)"}
     ]}
  ]

  # --- data gathering ---

  defp refresh(socket) do
    running_ids = Engine.list_regions()

    running =
      running_ids
      |> Enum.map(&Engine.region_stats/1)
      |> Enum.reject(&is_nil/1)

    # Persisted regions with no live process are stopped — still listable so
    # they can be resumed or deleted.
    stopped =
      (Engine.persisted_regions() -- running_ids)
      |> Enum.map(&Engine.stopped_region_stats/1)
      |> Enum.reject(&is_nil/1)

    stats = Enum.sort_by(running ++ stopped, & &1.region_id)

    prev = socket.assigns.prev_reductions

    # Per-region reductions/sec from the cumulative counter.
    rows =
      Enum.map(stats, fn s ->
        last = Map.get(prev, s.region_id, s.reductions)
        rate = max(s.reductions - last, 0) * 1000 / @interval_ms
        Map.put(s, :reductions_per_s, round(rate))
      end)

    new_prev = Map.new(stats, &{&1.region_id, &1.reductions})

    {sched_util, cur_sample} = scheduler_util(socket.assigns.prev_sched)

    socket
    |> assign(:rows, rows)
    |> assign(:prev_reductions, new_prev)
    |> assign(:prev_sched, cur_sample)
    |> assign(:system, system_stats(rows, sched_util))
  end

  defp system_stats(rows, sched_util) do
    %{
      regions: length(rows),
      players: rows |> Enum.map(& &1.players) |> Enum.sum(),
      entities: rows |> Enum.map(& &1.entities) |> Enum.sum(),
      running: Enum.count(rows, &(&1.status == :running)),
      fuel_per_tick: rows |> Enum.map(& &1.last_fuel) |> Enum.sum(),
      scheduler: sched_util,
      vm_memory: :erlang.memory(:total),
      sim_memory: rows |> Enum.map(& &1.memory) |> Enum.sum(),
      processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  # --- scheduler utilization (needs two samples) ---

  defp sched_sample do
    :scheduler.sample()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp scheduler_util(nil), do: {nil, sched_sample()}

  defp scheduler_util(prev) do
    cur = sched_sample()

    util =
      try do
        :scheduler.utilization(prev, cur)
        |> Enum.find_value(fn
          {:total, u, _} -> u
          _ -> nil
        end)
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    {util, cur}
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="border-b border-slate-800 px-6 py-4 flex items-center justify-between">
        <h1 class="text-xl font-bold tracking-tight">
          <span class="text-amber-400">Forge</span> &amp; <span class="text-sky-400">Convoy</span>
          <span class="ml-2 text-xs font-normal text-slate-500">world overview</span>
        </h1>
        <.link navigate={~p"/"} class="text-xs text-sky-400 hover:underline">← back to sim</.link>
      </header>

      <div class="p-6 space-y-6">
        <%!-- system utilization --%>
        <section class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-3">
          <.metric label="simulations" value={@system.regions} sub={"#{@system.running} running"} />
          <.metric label="players" value={@system.players} />
          <.metric label="harvesters" value={@system.entities} />
          <.metric label="fuel/tick" value={@system.fuel_per_tick} accent="text-fuchsia-400" />
          <.metric
            label="CPU (sched)"
            value={if @system.scheduler, do: "#{round(@system.scheduler * 100)}%", else: "—"}
            accent="text-emerald-400"
          />
          <.metric
            label="VM memory"
            value={mb(@system.vm_memory)}
            sub={"sims #{mb(@system.sim_memory)}"}
          />
          <.metric label="processes" value={@system.processes} sub={"runq #{@system.run_queue}"} />
        </section>

        <%!-- per-simulation table --%>
        <section class="bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
          <table class="w-full text-sm">
            <thead class="text-[10px] uppercase tracking-wide text-slate-500 bg-slate-900/80">
              <tr class="border-b border-slate-800">
                <th class="text-left px-3 py-2">region</th>
                <th class="text-left px-3 py-2">status</th>
                <th class="text-right px-3 py-2">tick</th>
                <th class="text-right px-3 py-2">players</th>
                <th class="text-right px-3 py-2">harvesters</th>
                <th class="text-right px-3 py-2">ore left</th>
                <th class="text-right px-3 py-2">fuel/tick</th>
                <th class="text-right px-3 py-2">memory</th>
                <th class="text-right px-3 py-2">redux/s</th>
                <th class="text-right px-3 py-2">actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for r <- @rows do %>
                <tr class="border-b border-slate-800/60 hover:bg-slate-800/30">
                  <td class="px-3 py-2 font-mono">
                    <button
                      phx-click="toggle"
                      phx-value-id={r.region_id}
                      class="text-slate-500 hover:text-slate-300 mr-1 w-3 inline-block"
                      title="show players"
                    >
                      {if MapSet.member?(@expanded, r.region_id), do: "▾", else: "▸"}
                    </button>
                    <.link navigate={~p"/?region=#{r.region_id}"} class="text-sky-300 hover:underline">
                      {r.region_id}
                    </.link>
                    <span :if={r.persist} class="ml-1 text-[10px] text-slate-600" title="persisted">
                      ●
                    </span>
                  </td>
                  <td class="px-3 py-2">
                    <span class={[
                      "px-1.5 py-0.5 rounded text-[10px] font-mono uppercase",
                      r.status == :running && "bg-emerald-500/20 text-emerald-300",
                      r.status == :paused && "bg-slate-700 text-slate-300",
                      r.status == :stopped && "bg-slate-800 text-slate-500"
                    ]}>
                      {r.status}
                    </span>
                  </td>
                  <td class="px-3 py-2 text-right font-mono">{r.tick}</td>
                  <td class="px-3 py-2 text-right font-mono">{r.players}</td>
                  <td class="px-3 py-2 text-right font-mono">{r.entities}</td>
                  <td class="px-3 py-2 text-right font-mono text-amber-300">{r.ore_remaining}</td>
                  <td class="px-3 py-2 text-right font-mono text-fuchsia-300">
                    {stopped_dash(r, r.last_fuel)}
                  </td>
                  <td class="px-3 py-2 text-right font-mono text-slate-400">
                    {stopped_dash(r, mb(r.memory))}
                  </td>
                  <td class="px-3 py-2 text-right font-mono text-slate-400">
                    {stopped_dash(r, fmt_int(r.reductions_per_s))}
                  </td>
                  <td class="px-3 py-2 text-right whitespace-nowrap">
                    <button
                      :if={r.status == :stopped}
                      phx-click="resume"
                      phx-value-id={r.region_id}
                      class="px-2 py-0.5 rounded text-[11px] bg-emerald-500/80 hover:bg-emerald-500 text-slate-950"
                    >
                      Resume
                    </button>
                    <button
                      :if={r.status != :stopped}
                      phx-click="stop"
                      phx-value-id={r.region_id}
                      class="px-2 py-0.5 rounded text-[11px] bg-slate-700 hover:bg-slate-600"
                    >
                      Stop
                    </button>
                    <button
                      phx-click="delete"
                      phx-value-id={r.region_id}
                      data-confirm={"Delete region '#{r.region_id}' and its snapshot?"}
                      class="px-2 py-0.5 rounded text-[11px] bg-rose-500/80 hover:bg-rose-500 text-slate-950"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
                <tr
                  :if={MapSet.member?(@expanded, r.region_id)}
                  class="border-b border-slate-800/60 bg-slate-950/40"
                >
                  <td colspan="10" class="px-6 py-3 space-y-4">
                    <%!-- players + scoreboard --%>
                    <div>
                      <div class="text-[10px] uppercase tracking-wide text-slate-500 mb-1">
                        players
                      </div>
                      <%= if r.scores == %{} do %>
                        <span class="text-[11px] text-slate-600">No players in this region.</span>
                      <% else %>
                        <div class="flex flex-wrap gap-2">
                          <%= for {player, score} <- Enum.sort_by(r.scores, fn {_p, s} -> -s end) do %>
                            <span class="inline-flex items-center gap-2 bg-slate-800 rounded px-2 py-1 text-xs">
                              <span class="font-mono text-slate-200">{player}</span>
                              <span class="font-mono text-slate-400">{score}</span>
                              <button
                                :if={r.status != :stopped}
                                phx-click="kick"
                                phx-value-region={r.region_id}
                                phx-value-player={player}
                                data-confirm={"Kick '#{player}' from #{r.region_id}?"}
                                class="text-rose-400 hover:text-rose-300"
                                title="kick player"
                              >
                                ✕
                              </button>
                            </span>
                          <% end %>
                        </div>
                      <% end %>
                    </div>

                    <%!-- live game-value tuning --%>
                    <.config_editor row={r} />
                  </td>
                </tr>
              <% end %>
              <tr :if={@rows == []}>
                <td colspan="10" class="px-3 py-6 text-center text-slate-500 text-xs">
                  No simulations running. Start one with <code>mix convoy.run</code>
                  or open <code>/</code>.
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <p class="text-[10px] text-slate-600">
          Refreshes every 1s · ▸ expand a region to tune its game values &amp; kick players · Stop frees compute (a persisted region resumes when reopened) · Delete also removes its snapshot.
        </p>
      </div>
    </div>
    """
  end

  # Live editor for a region's tweakable game values. Submits the whole config
  # at once; the Region merges + validates and the new values take effect next
  # tick. Disabled for a stopped region (no process to receive the change).
  attr :row, :map, required: true

  defp config_editor(assigns) do
    assigns = assign(assigns, :groups, @config_fields)

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-1">
        <div class="text-[10px] uppercase tracking-wide text-slate-500">game values</div>
        <span :if={@row.status == :stopped} class="text-[10px] text-slate-600">
          resume to edit
        </span>
      </div>
      <form phx-submit="set_config" class="space-y-3">
        <input type="hidden" name="region" value={@row.region_id} />
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-x-5 gap-y-3">
          <div :for={{group, fields} <- @groups}>
            <div class="text-[10px] font-semibold text-slate-400 mb-1">{group}</div>
            <div class="space-y-1">
              <label
                :for={{key, label} <- fields}
                class="flex items-center justify-between gap-2 text-[11px]"
              >
                <span class="text-slate-400">{label}</span>
                <input
                  type="number"
                  min="0"
                  step="1"
                  name={"config[#{key}]"}
                  value={Map.get(@row.config, key)}
                  disabled={@row.status == :stopped}
                  class="w-20 bg-slate-950 border border-slate-700 rounded px-1.5 py-0.5 font-mono text-right text-slate-200 focus:border-sky-500 focus:outline-none disabled:opacity-40"
                />
              </label>
            </div>
          </div>
        </div>
        <button
          type="submit"
          disabled={@row.status == :stopped}
          class="px-3 py-1 rounded text-[11px] bg-sky-500/80 hover:bg-sky-500 text-slate-950 font-medium disabled:opacity-40 disabled:cursor-not-allowed"
        >
          Apply (live)
        </button>
        <span class="ml-2 text-[10px] text-slate-600">
          Takes effect next tick. Harvester count / cargo / room layout apply to new players &amp; replenished nodes.
        </span>
      </form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, default: nil
  attr :accent, :string, default: "text-slate-100"

  defp metric(assigns) do
    ~H"""
    <div class="bg-slate-900 border border-slate-800 rounded-lg p-3">
      <div class={["font-mono font-bold text-lg leading-none", @accent]}>{@value}</div>
      <div class="text-[10px] uppercase tracking-wide text-slate-500 mt-1">{@label}</div>
      <div :if={@sub} class="text-[10px] text-slate-600">{@sub}</div>
    </div>
    """
  end

  # Live-only columns show a dash for stopped (no process) regions.
  defp stopped_dash(%{status: :stopped}, _value), do: "—"
  defp stopped_dash(_row, value), do: value

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp fmt_int(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_int(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp fmt_int(n), do: "#{n}"
end
