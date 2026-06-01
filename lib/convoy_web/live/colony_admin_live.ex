defmodule ConvoyWeb.ColonyAdminLive do
  @moduledoc """
  Ops overview for colony regions: every live region with its tick / status /
  player count / credits / convoys, plus persisted-but-stopped regions rebuilt
  from their snapshots. Controls: pause/play/step/reset, stop (free compute, keep
  the snapshot), resume, delete, and kick (evict an individual player from a live
  region). Put behind auth before exposing publicly.
  """
  use ConvoyWeb, :live_view

  alias Convoy.Engine.Colony.{Region, Persistence, Market}

  @refresh_ms 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, :rows, rows())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :rows, rows())}
  end

  @impl true
  def handle_event("play", %{"id" => id}, s), do: act(s, fn -> Region.play(id) end)
  def handle_event("pause", %{"id" => id}, s), do: act(s, fn -> Region.pause(id) end)
  def handle_event("step", %{"id" => id}, s), do: act(s, fn -> Region.step(id) end)
  def handle_event("reset", %{"id" => id}, s), do: act(s, fn -> Region.reset(id, 1) end)
  def handle_event("stop", %{"id" => id}, s), do: act(s, fn -> Region.stop(id) end)
  def handle_event("resume", %{"id" => id}, s), do: act(s, fn -> Region.ensure(id) end)
  def handle_event("delete", %{"id" => id}, s), do: act(s, fn -> Region.delete(id) end)

  def handle_event("kick", %{"id" => id, "player" => player}, s),
    do: act(s, fn -> Region.kick(id, player) end)

  defp act(socket, fun) do
    fun.()
    {:noreply, assign(socket, :rows, rows())}
  end

  # Build the table: live regions (from the registry) + persisted-but-stopped ones.
  defp rows do
    live = Region.list()

    live_rows =
      live
      |> Enum.map(&live_row/1)
      |> Enum.reject(&is_nil/1)

    stopped_rows =
      (Persistence.region_ids() -- live)
      |> Enum.map(&stopped_row/1)
      |> Enum.reject(&is_nil/1)

    Enum.sort_by(live_rows ++ stopped_rows, & &1.id)
  end

  defp live_row(id) do
    s = Region.snapshot(id)

    %{
      id: id,
      live: true,
      status: s.status,
      tick: s.tick,
      players: length(s.players),
      player_ids: Enum.map(s.players, & &1.id),
      credits: Enum.sum(Enum.map(s.players, & &1.credits)),
      convoys: length(s.market.convoys)
    }
  catch
    :exit, _ -> nil
  end

  defp stopped_row(id) do
    case Persistence.load(id) do
      {:ok, snap} ->
        %{
          id: id,
          live: false,
          status: :stopped,
          tick: Map.get(snap, :tick, 0),
          players: map_size(Map.get(snap, :colonies, %{})),
          player_ids: [],
          credits: snap |> Map.get(:colonies, %{}) |> Map.values() |> Enum.map(& &1.credits) |> Enum.sum(),
          convoys: length(Map.get(snap, :market, %Market{}).convoys)
        }

      :error ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100 p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-xl font-bold">
          <span class="text-amber-400">Forge</span> &amp; <span class="text-sky-400">Convoy</span>
          <span class="text-sm font-normal text-slate-500 ml-2">colony ops</span>
          <.link navigate={~p"/"} class="text-xs text-sky-400 hover:underline ml-2">← back to the game</.link>
        </h1>
        <div class="text-xs text-slate-500">{length(@rows)} region(s) · refreshes every 1s</div>
      </div>

      <%= if @rows == [] do %>
        <div class="text-sm text-slate-500">No regions yet. Open the game to start the <code>main</code> region.</div>
      <% end %>

      <table class="w-full text-sm border-collapse">
        <thead>
          <tr class="text-left text-[11px] uppercase tracking-wide text-slate-500 border-b border-slate-800">
            <th class="py-2 pr-4">region</th>
            <th class="pr-4">state</th>
            <th class="pr-4">tick</th>
            <th class="pr-4">players</th>
            <th class="pr-4">🏪 credits</th>
            <th class="pr-4">🚚 convoys</th>
            <th>controls</th>
          </tr>
        </thead>
        <tbody>
          <%= for r <- @rows do %>
            <tr class="border-b border-slate-900">
              <td class="py-2 pr-4 font-mono">
                <.link navigate={~p"/?region=#{r.id}"} class="text-sky-300 hover:underline">{r.id}</.link>
              </td>
              <td class="pr-4">
                <span class={[
                  "px-2 py-0.5 rounded text-[11px] font-mono uppercase",
                  r.status == :running && "bg-emerald-500/20 text-emerald-300",
                  r.status == :paused && "bg-amber-500/20 text-amber-300",
                  r.status == :stopped && "bg-slate-700 text-slate-300"
                ]}>{r.status}</span>
              </td>
              <td class="pr-4 font-mono">{r.tick}</td>
              <td class="pr-4 font-mono align-top">
                <div>{r.players}</div>
                <%= if r.live and r.player_ids != [] do %>
                  <div class="flex flex-col gap-0.5 mt-1">
                    <%= for p <- r.player_ids do %>
                      <span class="inline-flex items-center gap-1 text-[11px] text-slate-400">
                        <span class="truncate max-w-[8rem]">{p}</span>
                        <button
                          phx-click="kick"
                          phx-value-id={r.id}
                          phx-value-player={p}
                          data-confirm={"Kick #{p} from #{r.id}? Their colony, convoys, and program are removed."}
                          class="px-1 rounded bg-rose-900/60 hover:bg-rose-800 text-rose-200"
                          title={"Kick #{p}"}
                        >✕</button>
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </td>
              <td class="pr-4 font-mono text-yellow-300">{r.credits}</td>
              <td class="pr-4 font-mono">{r.convoys}</td>
              <td class="py-1">
                <div class="flex flex-wrap gap-1">
                  <%= if r.live do %>
                    <%= if r.status == :running do %>
                      <.btn id={r.id} ev="pause" label="⏸" />
                    <% else %>
                      <.btn id={r.id} ev="play" label="▶" />
                    <% end %>
                    <.btn id={r.id} ev="step" label="⏭" />
                    <.btn id={r.id} ev="reset" label="↻ reset" confirm="Reset every colony in this region?" />
                    <.btn id={r.id} ev="stop" label="⏹ stop" />
                  <% else %>
                    <.btn id={r.id} ev="resume" label="▶ resume" />
                  <% end %>
                  <.btn id={r.id} ev="delete" label="🗑 delete" confirm="Delete this region's snapshot for good?" danger />
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :ev, :string, required: true
  attr :label, :string, required: true
  attr :confirm, :string, default: nil
  attr :danger, :boolean, default: false

  defp btn(assigns) do
    ~H"""
    <button
      phx-click={@ev}
      phx-value-id={@id}
      data-confirm={@confirm}
      class={["px-2 py-0.5 rounded text-xs font-mono", if(@danger, do: "bg-rose-900/60 hover:bg-rose-800 text-rose-200", else: "bg-slate-800 hover:bg-slate-700 text-slate-300")]}
    >
      {@label}
    </button>
    """
  end
end
