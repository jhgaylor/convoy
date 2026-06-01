defmodule Convoy.ActivationTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine

  # Scale-to-zero activation (primer §5): a running region with no spectators is
  # warm (slow tick); a connected spectator snaps it to hot (full rate).
  test "a running region is warm until a spectator connects, then hot" do
    id = "warm-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)
    on_exit(fn -> Engine.delete_region(id) end)

    :ok = Engine.submit_player(id, "p1", :wasm, Convoy.Bots.wat_harvester(), "p1")
    Engine.play(id)

    # No spectators yet → warm. snapshot/1 is a call, so it's handled after the
    # preceding play cast, giving a consistent read.
    assert Engine.snapshot(id).activation == :warm

    # This process registers as a spectator; the following call is ordered after
    # the observe cast, so the region has already gone hot.
    Engine.observe(id, self())
    assert Engine.snapshot(id).activation == :hot
  end

  test "a paused region reports its status, not hot/warm" do
    id = "paused-#{System.unique_integer([:positive])}"
    Engine.ensure_region(id)
    on_exit(fn -> Engine.delete_region(id) end)

    assert Engine.snapshot(id).activation == :paused
  end
end
