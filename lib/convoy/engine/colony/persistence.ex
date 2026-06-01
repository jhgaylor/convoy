defmodule Convoy.Engine.Colony.Persistence do
  @moduledoc """
  File-backed snapshots for colony regions, so a region's colonies, market, and
  players (program bytes + bot memory) survive a restart or deploy. A snapshot is
  a compressed Erlang term written atomically (tmp + rename). A `version` guard
  discards snapshots from an older schema so a shape change starts the region
  fresh instead of crashing.
  """
  @version 1

  @doc "Snapshot directory (a mounted volume in prod via CONVOY_DATA_DIR; tmp in tests)."
  def dir, do: Application.get_env(:convoy, __MODULE__, [])[:dir] || "data/colony"

  defp path(id), do: Path.join(dir(), "#{sanitize(id)}.snapshot")
  defp sanitize(id), do: String.replace(to_string(id), ~r/[^a-zA-Z0-9_-]/, "")

  @doc "Persist a region snapshot map (must include :region_id). Best-effort — never raises."
  def save(%{region_id: id} = snap) do
    File.mkdir_p!(dir())
    data = :erlang.term_to_binary(Map.put(snap, :version, @version), [:compressed])
    tmp = path(id) <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path(id))
    :ok
  rescue
    _ -> :error
  end

  @doc "Load a region snapshot, or `:error` if absent / unreadable / wrong version."
  def load(id) do
    with {:ok, bin} <- File.read(path(id)),
         %{version: @version} = snap <- :erlang.binary_to_term(bin) do
      {:ok, snap}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Ids of all persisted colony regions."
  def region_ids do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".snapshot"))
        |> Enum.map(&String.replace_suffix(&1, ".snapshot", ""))

      _ ->
        []
    end
  end

  @doc "Delete a region's snapshot."
  def delete(id), do: File.rm(path(id))
end
