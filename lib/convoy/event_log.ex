defmodule Convoy.EventLog do
  @moduledoc """
  Durable, append-only event log per region (primer §8).

  The snapshot half of persistence (`Convoy.Persistence`) captures *state*; this
  is the other half — the **event stream** between snapshots. We record the
  control events that drive a region's timeline (program submissions, resets,
  kicks), each stamped with the tick it happened at.

  Why these events specifically: the tick loop is deterministic (seed + program
  → bit-identical, primer §6), so the *only* things you need to reconstruct or
  replay a region's history are its seed plus the external inputs applied to it
  over time. Those inputs are exactly these control events. Snapshot + this log
  is therefore both the recovery story (§8) and the free-replay story (§6): load
  the seed, replay the events at their ticks, re-run the loop.

  The log is append-only framed terms (a 4-byte big-endian length prefix then an
  `:erlang.term_to_binary/1` blob), so a crash mid-append truncates the last
  record rather than corrupting the file. It's separate from the capped
  in-memory `World.events` (which drives the live UI); this one is uncapped and
  survives across snapshots.
  """

  require Logger

  @ext ".log"

  @type event :: %{tick: non_neg_integer(), type: atom(), detail: map()}

  @doc "Directory the logs live in (shared with snapshots)."
  @spec dir() :: String.t()
  def dir, do: Convoy.Persistence.dir()

  @doc """
  Append one control event for a region. `type` is e.g. `:submit`, `:kick`,
  `:reset`; `detail` is a small map (player id, seed, backend…). Best-effort —
  a logging failure never disrupts the sim.
  """
  @spec append(String.t(), non_neg_integer(), atom(), map()) :: :ok
  def append(region_id, tick, type, detail \\ %{}) do
    File.mkdir_p!(dir())
    event = %{tick: tick, type: type, detail: detail}
    bin = :erlang.term_to_binary(event)
    frame = <<byte_size(bin)::unsigned-big-32, bin::binary>>

    case File.open(path(region_id), [:append, :binary], &IO.binwrite(&1, frame)) do
      {:ok, :ok} -> :ok
      other -> log_failure(region_id, other)
    end
  rescue
    e -> log_failure(region_id, e)
  end

  @doc "Read a region's full event log in append order. `[]` if none."
  @spec read(String.t()) :: [event()]
  def read(region_id) do
    case File.read(path(region_id)) do
      {:ok, bin} -> decode_frames(bin, [])
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  @doc "Read the most recent `n` events for a region."
  @spec tail(String.t(), pos_integer()) :: [event()]
  def tail(region_id, n) do
    region_id |> read() |> Enum.take(-n)
  end

  @doc "Remove a region's event log (used by reset / delete)."
  @spec delete(String.t()) :: :ok
  def delete(region_id) do
    _ = File.rm(path(region_id))
    :ok
  end

  # --- framing ---

  defp decode_frames(<<len::unsigned-big-32, rest::binary>>, acc) when byte_size(rest) >= len do
    <<blob::binary-size(len), tail::binary>> = rest
    decode_frames(tail, [safe_term(blob) | acc])
  end

  # Trailing partial frame (a torn final append) or clean end: stop.
  defp decode_frames(_partial, acc), do: acc |> Enum.reject(&is_nil/1) |> Enum.reverse()

  defp safe_term(blob) do
    :erlang.binary_to_term(blob, [:safe])
  rescue
    _ -> nil
  end

  defp path(region_id), do: Path.join(dir(), slug(region_id) <> @ext)

  defp slug(id), do: id |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

  defp log_failure(region_id, reason) do
    Logger.warning("event-log append failed for #{region_id}: #{inspect(reason)}")
    :ok
  end
end
