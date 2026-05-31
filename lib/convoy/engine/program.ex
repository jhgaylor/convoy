defmodule Convoy.Engine.Program do
  @moduledoc """
  The player's "code".

  This is the v1 stand-in for the WASM execution tier (primer §7). Rather
  than run untrusted WASM, v1 ships a tiny, sandboxed-by-construction rule
  language: there is no `eval`, no host access, and no way for a program to
  mutate the world. A program is a list of `condition -> action` rules; the
  evaluator reads a *read-only* entity + world view and returns a single
  declarative **intent** (primer §3). The sim resolves intents authoritatively.

  The behaviour boundary here (`compile/1` + `eval/3`) is deliberately the
  same shape a Wasmtime/wasmex backend would expose, so the WASM tier from
  primer §11 can slot in later without touching the sim core.

  ## Language

      # comments start with '#'
      when cargo_full to_base
      when at_base    unload
      when on_resource harvest
      otherwise        to_resource

  Conditions: `cargo_full`, `cargo_empty`, `has_cargo`, `on_resource`,
  `at_base`, `can_unload` (at base *and* carrying cargo), `always`
  (alias `otherwise`).

  Actions: `harvest`, `unload`, `to_base`, `to_resource`, `wander`, `idle`.

  Rules are evaluated top-to-bottom; the first matching condition wins.
  """

  alias Convoy.Engine.World

  @conditions ~w(cargo_full cargo_empty has_cargo on_resource at_base can_unload always otherwise)a
  @actions ~w(harvest unload to_base to_resource wander idle)a

  @type rule :: {atom(), atom()}
  @type t :: [rule()]

  @default_source """
  # Harvester behaviour — edit me, then press Run.
  when can_unload  unload
  when cargo_full  to_base
  when on_resource harvest
  otherwise        to_resource
  """

  @doc "The starter program shown in the editor."
  @spec default_source() :: String.t()
  def default_source, do: @default_source

  @doc """
  Compile source text into a rule list.

  Returns `{:ok, rules}` or `{:error, message}` with a human-readable,
  line-numbered error — this is the player's compiler feedback.
  """
  @spec compile(String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      case compile_line(strip_comment(line)) do
        :blank -> {:cont, {:ok, acc}}
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, msg} -> {:halt, {:error, "line #{n}: #{msg}"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "program is empty — add at least one rule"}
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Evaluate a compiled program for one entity against a read-only world,
  returning a single intent for the sim to resolve.

  Intents: `{:move, {dx, dy}}`, `:harvest`, `:unload`, `:idle`.
  """
  @spec eval(t(), World.entity(), World.t()) :: term()
  def eval(rules, entity, %World{} = world) do
    case Enum.find(rules, fn {cond, _act} -> condition_true?(cond, entity, world) end) do
      nil -> :idle
      {_cond, action} -> action_to_intent(action, entity, world)
    end
  end

  # --- compilation ---

  defp strip_comment(line) do
    line |> String.split("#", parts: 2) |> hd() |> String.trim()
  end

  defp compile_line(""), do: :blank

  defp compile_line(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      ["otherwise", action] -> build_rule("always", action)
      ["when", cond, action] -> build_rule(cond, action)
      [cond, action] when cond in ~w(otherwise always) -> build_rule("always", action)
      _ -> {:error, "expected `when <condition> <action>` or `otherwise <action>`, got `#{line}`"}
    end
  end

  defp build_rule(cond, action) do
    cond_atom = safe_atom(cond, @conditions)
    action_atom = safe_atom(action, @actions)

    cond
    |> case do
      _ when is_nil(cond_atom) ->
        {:error, "unknown condition `#{cond}` (try: #{atoms(@conditions)})"}

      _ when is_nil(action_atom) ->
        {:error, "unknown action `#{action}` (try: #{atoms(@actions)})"}

      _ ->
        {:ok, {normalize(cond_atom), action_atom}}
    end
  end

  defp normalize(:otherwise), do: :always
  defp normalize(other), do: other

  defp safe_atom(str, allowed) do
    Enum.find(allowed, fn a -> Atom.to_string(a) == str end)
  end

  defp atoms(list), do: list |> Enum.reject(&(&1 == :otherwise)) |> Enum.join(", ")

  # --- conditions ---

  defp condition_true?(:always, _entity, _world), do: true
  defp condition_true?(:cargo_full, e, _w), do: e.cargo >= e.cargo_max
  defp condition_true?(:cargo_empty, e, _w), do: e.cargo == 0
  defp condition_true?(:has_cargo, e, _w), do: e.cargo > 0
  defp condition_true?(:at_base, e, w), do: {e.x, e.y} == w.base
  defp condition_true?(:can_unload, e, w), do: {e.x, e.y} == w.base and e.cargo > 0
  defp condition_true?(:on_resource, e, w), do: World.resource_at(w, {e.x, e.y}) > 0

  # --- actions -> intents ---

  defp action_to_intent(:harvest, _e, _w), do: :harvest
  defp action_to_intent(:unload, _e, _w), do: :unload
  defp action_to_intent(:idle, _e, _w), do: :idle

  defp action_to_intent(:to_base, e, w), do: {:move, World.step_toward({e.x, e.y}, w.base)}

  defp action_to_intent(:to_resource, e, w) do
    case World.nearest_resource(w, {e.x, e.y}) do
      nil -> {:move, World.step_toward({e.x, e.y}, w.base)}
      target -> {:move, World.step_toward({e.x, e.y}, target)}
    end
  end

  defp action_to_intent(:wander, e, w), do: {:move, World.wander_dir(w.seed, w.tick, e.id)}
end
