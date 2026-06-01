defmodule ConvoyWeb.Sparkline do
  @moduledoc """
  Pure, server-rendered SVG sparklines for the spectator **trends** panel.

  No JS and no deps: the region keeps a short ring buffer of per-player stat
  samples (telemetry, *not* world state — determinism stays sacred), and these
  helpers turn a numeric series into a tiny inline `<svg>` that rides the
  existing LiveView diff.

  We also derive the discrete 1st and 2nd derivatives, so a player's score is
  shown alongside *how fast* it's climbing (rate, d/dt) and whether that climb
  is *accelerating* (d²/dt²). Both are per-tick and smoothed over a window, so
  the spiky single-tick deltas (a convoy sells, credits jump) read as a trend
  rather than a comb.
  """
  use Phoenix.Component

  @doc """
  Pull a chronological numeric series for `pid`'s `key` out of the region's
  history buffer (oldest → newest, as `Region.public/1` ships it).

  A player who joined late is missing from earlier samples; we carry the last
  seen value forward (and treat the pre-arrival gap as 0) so the series stays
  contiguous for the finite-difference math below.
  """
  @spec series([map()], term(), atom()) :: [number()]
  def series(history, pid, key) do
    history
    |> Enum.map(fn s -> get_in(s, [:players, pid, key]) end)
    |> carry_forward()
  end

  defp carry_forward(vals) do
    {out, _} =
      Enum.map_reduce(vals, 0, fn
        nil, prev -> {prev, prev}
        v, _ -> {v, v}
      end)

    out
  end

  @doc """
  Trailing finite-difference derivative: `(v[i] - v[i-window]) / window`,
  i.e. the average per-tick change over the last `window` samples. The
  leading `window` points ramp up against the first sample so the series
  length is preserved (and can be differentiated again for d²/dt²).
  """
  @spec derivative([number()], pos_integer()) :: [float()]
  def derivative([], _window), do: []

  def derivative(series, window) when is_integer(window) and window > 0 do
    vec = List.to_tuple(series)
    n = tuple_size(vec)
    first = elem(vec, 0)

    for i <- 0..(n - 1) do
      if i < window do
        span = max(i, 1)
        (elem(vec, i) - first) / span
      else
        (elem(vec, i) - elem(vec, i - window)) / window
      end
    end
  end

  @doc "The most recent value of a series (0 for an empty series)."
  @spec latest([number()]) :: number()
  def latest([]), do: 0
  def latest(series), do: List.last(series)

  @doc "Format a stockpile/level value for the numeric readout."
  def fmt_value(v) when is_number(v), do: v |> round() |> Integer.to_string()

  @doc "Format a per-tick rate with an explicit sign (e.g. `+4.2`, `-1.0`)."
  def fmt_rate(v) do
    r = Float.round(v * 1.0, 1)
    sign = if r > 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(r, decimals: 1)
  end

  attr :series, :list, required: true
  attr :stroke, :string, default: "#94a3b8"
  attr :width, :integer, default: 80
  attr :height, :integer, default: 18
  attr :baseline, :boolean, default: false, doc: "draw a dashed zero line (for derivatives)"

  @doc "A tiny inline SVG line chart for one numeric series."
  def sparkline(assigns) do
    {points, zero_y} = plot(assigns.series, assigns.width, assigns.height)
    assigns = assign(assigns, points: points, zero_y: zero_y)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      preserveAspectRatio="none"
      class="shrink-0"
    >
      <line
        :if={@baseline and @zero_y}
        x1="0"
        x2={@width}
        y1={@zero_y}
        y2={@zero_y}
        stroke="#475569"
        stroke-width="0.5"
        stroke-dasharray="2 2"
        vector-effect="non-scaling-stroke"
      />
      <polyline
        :if={@points != ""}
        points={@points}
        fill="none"
        stroke={@stroke}
        stroke-width="1.25"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  # Map a series onto SVG coords. Returns {points_string, zero_baseline_y|nil}.
  defp plot([], _w, _h), do: {"", nil}

  defp plot(series, w, h) do
    pad = 1.5
    usable = h - 2 * pad
    n = length(series)
    {min, max} = Enum.min_max(series)
    flat? = max == min

    y = fn v -> if flat?, do: h / 2, else: pad + (max - v) / (max - min) * usable end
    x = fn i -> if n <= 1, do: w / 2, else: i / (n - 1) * w end

    points =
      series
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} -> "#{r1(x.(i))},#{r1(y.(v))}" end)

    zero_y = if min < 0 and max > 0, do: r1(y.(0)), else: nil
    {points, zero_y}
  end

  defp r1(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
end
