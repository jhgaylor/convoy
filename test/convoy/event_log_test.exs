defmodule Convoy.EventLogTest do
  use ExUnit.Case, async: true

  alias Convoy.{EventLog, Engine}

  defp region_id, do: "log-#{System.unique_integer([:positive])}"

  test "appends control events and reads them back in order" do
    id = region_id()
    on_exit(fn -> EventLog.delete(id) end)

    EventLog.append(id, 0, :submit, %{player: "alice", backend: :wasm})
    EventLog.append(id, 12, :submit, %{player: "bob", backend: :wasm})
    EventLog.append(id, 30, :kick, %{player: "alice"})

    events = EventLog.read(id)
    assert length(events) == 3
    assert Enum.map(events, & &1.type) == [:submit, :submit, :kick]
    assert Enum.map(events, & &1.tick) == [0, 12, 30]
    assert hd(events).detail.player == "alice"
  end

  test "tail returns the most recent events" do
    id = region_id()
    on_exit(fn -> EventLog.delete(id) end)

    for t <- 1..5, do: EventLog.append(id, t, :submit, %{player: "p#{t}"})

    assert EventLog.read(id) |> length() == 5
    tail = EventLog.tail(id, 2)
    assert Enum.map(tail, & &1.tick) == [4, 5]
  end

  test "a torn trailing frame is tolerated, not fatal" do
    id = region_id()
    on_exit(fn -> EventLog.delete(id) end)

    EventLog.append(id, 1, :submit, %{player: "a"})
    # Simulate a crash mid-append: a length prefix promising more than is there.
    path = Path.join(EventLog.dir(), "#{id}.log")
    File.write!(path, <<0, 0, 0, 99, "incomplete">>, [:append])

    # The complete record still reads back; the partial one is dropped.
    assert [%{tick: 1, type: :submit}] = EventLog.read(id)
  end

  test "a region records submit/kick to its durable log via the Engine" do
    id = region_id()
    Engine.ensure_region(id)
    on_exit(fn -> Engine.delete_region(id) end)

    :ok = Engine.submit_player(id, "alice", :wasm, Convoy.Bots.wat_harvester(), "alice")
    :ok = Engine.submit_player(id, "bob", :wasm, Convoy.Bots.wat_harvester(), "bob")
    :ok = Engine.kick_player(id, "alice")

    history = Engine.history(id)
    assert Enum.map(history, & &1.type) == [:submit, :submit, :kick]
    assert List.last(history).detail.player == "alice"
  end
end
