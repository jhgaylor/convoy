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

  test "two passive convoys sharing a cell do NOT fight (raiding is opt-in)" do
    # two convoys launched the same tick share the entry and both just advance.
    # Under the stance triangle, passive-vs-passive is no seizure — they coexist
    # and continue. (This is the old auto-collision behavior, deliberately removed.)
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 0, y: 0, cargo: 30, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 0, y: 0, cargo: 30, last_action: :advance}
        ]
    }

    {m, _} = Market.step(m, %{})
    assert length(m.convoys) == 2
    assert Enum.all?(m.convoys, &(&1.cargo == 30))
  end

  test "a hunter seizes a passive convoy it lands on (hunt ⊳ passive)" do
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 4, y: 0, cargo: 30, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 3, y: 0, cargo: 10, last_action: :advance}
        ]
    }

    # alice holds at (4,0) via move(0,0) (stays passive); bob hunt-steers 3→4 onto
    # her cell. hunt ⊳ passive → bob seizes alice's shipment.
    {m, _} = Market.step(m, %{1_000_002 => {:hunt, {1, 0}}, 1_000_001 => {:move, {0, 0}}})
    assert length(m.convoys) == 1
    [w] = m.convoys
    assert w.owner == "bob"
    assert w.cargo == 40
  end

  test "a defender (escort) seizes a hunter that lands on it (defend ⊳ hunt)" do
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 5, y: 0, cargo: 30, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 4, y: 0, cargo: 30, last_action: :advance}
        ]
    }

    # alice escorts (defends) at (5,0); bob hunts onto it → the escort flips the
    # raider and takes its haul, regardless of id order.
    {m, _} = Market.step(m, %{1_000_001 => :defend, 1_000_002 => {:hunt, {1, 0}}})
    assert length(m.convoys) == 1
    [w] = m.convoys
    assert w.owner == "alice"
    assert w.cargo == 60
  end

  test "a lone defender lets a passive convoy pass untouched (no camp farming)" do
    # the old exploit: park a defender on the choke and seize the stream. Now a
    # defender does NOT beat a passive mover, so the shipment passes and survives.
    m = %{
      Market.new(8, 1)
      | convoys: [
          %{id: 1_000_001, owner: "alice", x: 5, y: 0, cargo: 0, last_action: :advance},
          %{id: 1_000_002, owner: "bob", x: 4, y: 0, cargo: 30, last_action: :advance}
        ]
    }

    {m, _} = Market.step(m, %{1_000_001 => :defend})
    # alice held (5,0); bob advanced 4→5 onto it but is passive → both survive, no seizure
    assert length(m.convoys) == 2
    bob = Enum.find(m.convoys, &(&1.owner == "bob"))
    assert bob.cargo == 30
  end

  test "steered hunt moves one cell by the sign of the given direction" do
    m = %{
      Market.new(8, 4)
      | convoys: [%{id: 1_000_001, owner: "alice", x: 2, y: 1, cargo: 0, last_action: :advance}]
    }

    {m, _} = Market.step(m, %{1_000_001 => {:hunt, {-5, 9}}})
    [c] = m.convoys
    assert {c.x, c.y} == {1, 2}
    assert c.last_action == :hunt
  end
end
