defmodule Convoy.Engine.Colony.MarketTest do
  use ExUnit.Case, async: true

  alias Convoy.Engine.Colony.Market

  test "a launched convoy advances toward the market each tick" do
    m = Market.new(16, 12) |> Market.launch("alice", 30)
    [c] = m.convoys
    assert {c.x, c.y} == {0, 0}
    assert Market.convoy_id?(c.id)

    {m, credits} = Market.step(m, %{})
    assert credits == %{}
    [c1] = m.convoys
    # greedy step closes x first
    assert {c1.x, c1.y} == {1, 0}
  end

  test "a convoy reaching the market sells and credits its owner" do
    m = %{Market.new(3, 1) | convoys: [%{id: 1_000_000, owner: "alice", x: 1, y: 0, cargo: 30, last_action: :advance}]}
    # market is at (2,0); one step moves there and sells
    {m, credits} = Market.step(m, %{})
    assert credits == %{"alice" => 30}
    assert m.convoys == []
  end

  test "two convoys sharing a cell: one seizes the other's shipment (PvP)" do
    # two convoys launched the same tick share the entry; advancing keeps them
    # together, so they collide and the lowest id seizes the other's cargo.
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 0, y: 0, cargo: 30, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 0, y: 0, cargo: 30, last_action: :advance}
        ]
    }

    {m, _} = Market.step(m, %{})
    assert length(m.convoys) == 1
    [w] = m.convoys
    assert w.owner == "alice"
    assert w.cargo == 60
  end

  test "a defender beats a convoy that moves onto its cell" do
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 5, y: 0, cargo: 30, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 4, y: 0, cargo: 30, last_action: :advance}
        ]
    }

    # alice (higher position) defends (5,0); bob advances onto it → defender wins despite id
    {m, _} = Market.step(m, %{1_000_001 => :defend})
    [w] = m.convoys
    assert w.owner == "alice"
    assert w.cargo == 60
  end
end
