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

  # --- data gathering ---

  defp refresh(socket) do
    stats =
      Engine.list_regions()
      |> Enum.map(&Engine.region_stats/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.region_id)

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
          <.metric label="VM memory" value={mb(@system.vm_memory)} sub={"sims #{mb(@system.sim_memory)}"} />
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
                    <.link navigate={~p"/?region=#{r.region_id}"} class="text-sky-300 hover:underline">
                      {r.region_id}
                    </.link>
                    <span :if={r.persist} class="ml-1 text-[10px] text-slate-600" title="persisted">●</span>
                  </td>
                  <td class="px-3 py-2">
                    <span class={[
                      "px-1.5 py-0.5 rounded text-[10px] font-mono uppercase",
                      r.status == :running && "bg-emerald-500/20 text-emerald-300",
                      r.status == :paused && "bg-slate-700 text-slate-300"
                    ]}>
                      {r.status}
                    </span>
                  </td>
                  <td class="px-3 py-2 text-right font-mono">{r.tick}</td>
                  <td class="px-3 py-2 text-right font-mono">{r.players}</td>
                  <td class="px-3 py-2 text-right font-mono">{r.entities}</td>
                  <td class="px-3 py-2 text-right font-mono text-amber-300">{r.ore_remaining}</td>
                  <td class="px-3 py-2 text-right font-mono text-fuchsia-300">{r.last_fuel}</td>
                  <td class="px-3 py-2 text-right font-mono text-slate-400">{mb(r.memory)}</td>
                  <td class="px-3 py-2 text-right font-mono text-slate-400">{fmt_int(r.reductions_per_s)}</td>
                  <td class="px-3 py-2 text-right whitespace-nowrap">
                    <button
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
              <% end %>
              <tr :if={@rows == []}>
                <td colspan="10" class="px-3 py-6 text-center text-slate-500 text-xs">
                  No simulations running. Start one with <code>mix convoy.run</code> or open <code>/</code>.
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <p class="text-[10px] text-slate-600">
          Refreshes every 1s · Stop frees compute (a persisted region resumes when reopened) · Delete also removes its snapshot.
        </p>
      </div>
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

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp fmt_int(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_int(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp fmt_int(n), do: "#{n}"
end
