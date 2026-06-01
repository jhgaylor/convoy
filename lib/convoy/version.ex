defmodule Convoy.Version do
  @moduledoc """
  Build identity for the running release, surfaced in the spectator UI so a
  deploy is visible at a glance — the deploy pipeline tags images `sha-<commit>`
  and pins that into the manifest, so the commit SHA *is* the deployed version.

  In the release image there is no `.git` (only `lib/` is copied into the build),
  so CI injects the commit as the `CONVOY_VERSION` env (the full `github.sha`).
  Locally we fall back to the git SHA captured at compile time, then to `nil`.
  """

  @app_version Mix.Project.config()[:version]

  # Captured at compile time from the local checkout. Empty in the Docker build
  # (no `.git` in the build context), where the runtime env takes over instead.
  @compiled_sha (try do
                   case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
                     {out, 0} -> out |> String.trim() |> String.slice(0, 40)
                     _ -> nil
                   end
                 rescue
                   _ -> nil
                 end)

  @doc "App version from `mix.exs`, e.g. `\"0.1.0\"`."
  @spec app_version() :: String.t()
  def app_version, do: @app_version

  @doc "Full commit SHA of the running build, or `nil` if unknown."
  @spec full_sha() :: String.t() | nil
  def full_sha, do: System.get_env("CONVOY_VERSION") || @compiled_sha

  @doc "Short (7-char) commit SHA of the running build, or `nil` if unknown."
  @spec short_sha() :: String.t() | nil
  def short_sha do
    case full_sha() do
      nil -> nil
      sha -> String.slice(sha, 0, 7)
    end
  end

  @doc "GitHub commit URL for the running build, or `nil` if the SHA is unknown."
  @spec commit_url() :: String.t() | nil
  def commit_url do
    case full_sha() do
      nil -> nil
      sha -> "https://github.com/jhgaylor/convoy/commit/#{sha}"
    end
  end
end
