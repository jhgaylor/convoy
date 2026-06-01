defmodule ConvoyWeb.SparklineTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ConvoyWeb.Sparkline

  defp history(samples) do
    # samples :: [{tick, %{pid => %{key => val}}}]
    Enum.map(samples, fn {tick, players} -> %{tick: tick, players: players} end)
  end

  describe "series/3" do
    test "pulls a chronological series for one player + key" do
      h =
        history([
          {0, %{"p1" => %{credits: 0}}},
          {1, %{"p1" => %{credits: 10}}},
          {2, %{"p1" => %{credits: 25}}}
        ])

      assert Sparkline.series(h, "p1", :credits) == [0, 10, 25]
    end

    test "carries the last value forward for a late-joining player (gap = 0)" do
      h =
        history([
          {0, %{"p1" => %{credits: 5}}},
          {1, %{"p1" => %{credits: 7}, "p2" => %{credits: 3}}},
          {2, %{"p1" => %{credits: 9}}}
        ])

      # p2 absent at tick 0 → 0; present at 1 → 3; absent at 2 → carries 3.
      assert Sparkline.series(h, "p2", :credits) == [0, 3, 3]
    end
  end

  describe "derivative/2" do
    test "constant series has zero rate" do
      assert Sparkline.derivative([5, 5, 5, 5], 1) == [0.0, 0.0, 0.0, 0.0]
    end

    test "linear growth has constant rate equal to the slope" do
      # +3 each step; window 1 → every delta is 3.
      assert Sparkline.derivative([0, 3, 6, 9], 1) == [0.0, 3.0, 3.0, 3.0]
    end

    test "window averages the per-tick change over the window" do
      # value jumps 0,0,0,12 → with window 3, last point = (12-0)/3 = 4.0
      d = Sparkline.derivative([0, 0, 0, 12], 3)
      assert List.last(d) == 4.0
    end

    test "second derivative of quadratic-ish growth is positive (accelerating)" do
      # accelerating series: deltas grow 1,2,3,4 → first deriv climbs → second > 0
      series = [0, 1, 3, 6, 10, 15]
      d1 = Sparkline.derivative(series, 1)
      d2 = Sparkline.derivative(d1, 1)
      assert Enum.all?(tl(d2), &(&1 > 0))
    end

    test "empty series stays empty" do
      assert Sparkline.derivative([], 5) == []
    end
  end

  describe "formatting" do
    test "latest/1" do
      assert Sparkline.latest([1, 2, 3]) == 3
      assert Sparkline.latest([]) == 0
    end

    test "fmt_value/1 rounds to an integer string" do
      assert Sparkline.fmt_value(42) == "42"
      assert Sparkline.fmt_value(3.6) == "4"
    end

    test "fmt_rate/1 carries an explicit sign" do
      assert Sparkline.fmt_rate(4.24) == "+4.2"
      assert Sparkline.fmt_rate(-1.0) == "-1.0"
      assert Sparkline.fmt_rate(0.0) == "0.0"
    end
  end

  describe "sparkline/1 component" do
    test "renders an svg polyline for a real series" do
      assigns = %{series: [0, 5, 2, 8], stroke: "#fff", width: 80, height: 18, baseline: false}
      html = render_component(&Sparkline.sparkline/1, assigns)
      assert html =~ "<svg"
      assert html =~ "<polyline"
      assert html =~ ~s(stroke="#fff")
    end

    test "draws a zero baseline when the series straddles zero" do
      assigns = %{series: [-3, 0, 4, -1], stroke: "#fff", width: 80, height: 18, baseline: true}
      html = render_component(&Sparkline.sparkline/1, assigns)
      assert html =~ "stroke-dasharray"
    end

    test "no baseline line when the series never crosses zero" do
      assigns = %{series: [1, 2, 3], stroke: "#fff", width: 80, height: 18, baseline: true}
      html = render_component(&Sparkline.sparkline/1, assigns)
      refute html =~ "stroke-dasharray"
    end
  end
end
