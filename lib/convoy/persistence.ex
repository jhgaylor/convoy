defmodule Convoy.Persistence do
  @moduledoc """
  Durable region snapshots (primer §8).

  A region's full state is plain data, so persistence is just: serialize the
  snapshot, write it durably, and read it back on boot. That's enough for the
  freeze/thaw guarantee — a region resumes at the exact tick it stopped, so a
  code deploy continues where the simulation was.

  This v1 implementation writes one file per region under a configurable
  directory. Writes are atomic (write-temp-then-rename) so a crash mid-write
  can't corrupt a snapshot. The primer's eventual store is an object store + KV
  (§8); this module is the seam — swap the body of `save`/`load` for S3/Postgres
  without touching the region.

  Configure with:

      config :convoy, Convoy.Persistence, dir: "data/regions"
  """

  require Logger

  @default_dir "data/regions"
  @ext ".snapshot"

  @doc "Directory snapshots live in (configurable per env)."
  @spec dir() :: String.t()
  def dir do
    :convoy
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:dir, @default_dir)
  end

  @doc "Persist a snapshot map for a region. Returns :ok or {:error, reason}."
  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(region_id, %{} = snapshot) do
    File.mkdir_p!(dir())
    path = path(region_id)
    tmp = path <> ".tmp"

    # Compressed: a snapshot now carries each player's wasm linear memory, which
    # for some toolchains is ~1 MB of mostly-zero stack — it compresses to almost
    # nothing. `binary_to_term` reads compressed terms transparently.
    with :ok <- File.write(tmp, :erlang.term_to_binary(snapshot, [:compressed])),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  rescue
    e ->
      Logger.warning("region snapshot save failed for #{region_id}: #{inspect(e)}")
      {:error, e}
  end

  @doc "Load a region's snapshot map. Returns {:ok, map} or :error."
  @spec load(String.t()) :: {:ok, map()} | :error
  def load(region_id) do
    case File.read(path(region_id)) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin, [:safe])}
      {:error, _} -> :error
    end
  rescue
    e ->
      Logger.warning("region snapshot load failed for #{region_id}: #{inspect(e)}")
      :error
  end

  @doc "Remove a region's snapshot (used by reset)."
  @spec delete(String.t()) :: :ok
  def delete(region_id) do
    _ = File.rm(path(region_id))
    :ok
  end

  @doc """
  Region ids that have a snapshot on disk, read from the snapshots themselves
  (so the true id survives any filename slugging).
  """
  @spec region_ids() :: [String.t()]
  def region_ids do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, @ext))
        |> Enum.map(&Path.join(dir(), &1))
        |> Enum.flat_map(&id_in_file/1)

      {:error, _} ->
        []
    end
  end

  defp id_in_file(file) do
    case File.read(file) do
      {:ok, bin} ->
        case safe_term(bin) do
          %{region_id: id} when is_binary(id) -> [id]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> nil
  end

  defp path(region_id), do: Path.join(dir(), slug(region_id) <> @ext)

  # Region ids are already sanitized upstream; this is belt-and-suspenders so a
  # weird id can't escape the snapshot directory.
  defp slug(id) do
    id |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
  end
end
