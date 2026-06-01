defmodule Convoy.Examples do
  @moduledoc """
  The bundled example colony bots, surfaced in the spectator UI so players can
  read a complete working brain and one-click submit it into the world.

  Each entry pairs human-facing metadata (name, strategy blurb) with the bot's
  full source. Sources are embedded at compile time via `@external_resource`, so
  they ride along in the release even when the `examples/` directory isn't
  present at runtime (e.g. inside the container image). These are the same bots
  the region auto-seeds as `demo`/`shipper`/`builder` (see `Region.seed_residents/1`).
  """

  @examples_dir Path.expand(Path.join(__DIR__, "../../examples"))

  # `seeded?` bots auto-run as residents on `main` (see Region.seed_residents/1);
  # the rest ship in the collection but only enter a world when a player fields
  # them. id matches the resident name where seeded. Files live under examples/.
  @meta [
    %{
      id: "demo",
      name: "Demo",
      file: "colony.rs",
      lang: :rust,
      ext: "rs",
      seeded?: true,
      tagline: "Balanced opener",
      blurb:
        "Builds up to two refineries before it starts shipping, then runs convoys while it keeps growing the harvester fleet. The reference bot — a solid all-rounder, and the best one to read first."
    },
    %{
      id: "shipper",
      name: "Shipper",
      file: "colony_shipper.rs",
      lang: :rust,
      ext: "rs",
      seeded?: true,
      tagline: "Early aggression",
      blurb:
        "One refinery, then ships aggressively — floods the market with cheap early convoys to out-volume rivals before they're set up. Strong early, thin on throughput."
    },
    %{
      id: "builder",
      name: "Builder",
      file: "colony_builder.rs",
      lang: :rust,
      ext: "rs",
      seeded?: true,
      tagline: "Late-game economy",
      blurb:
        "Stacks up to three refineries before shipping, then sends big late convoys. Slow to start and exposed early, but dominant on throughput once it's rolling."
    },
    %{
      id: "raider",
      name: "Raider",
      file: "raider.rs",
      lang: :rust,
      ext: "rs",
      seeded?: false,
      tagline: "Convoy hunter (PvP)",
      blurb:
        "Plays for the ambush, not the sale. Runs a lean economy and steers its own convoys to hunt and defend — seizing rivals' shipments on the contested market. Banks little itself; wins by taking everyone else's. Not running by default — field it to start a brawl."
    }
  ]

  @bots (for m <- @meta do
           path = Path.join(@examples_dir, m.file)
           @external_resource path
           Map.put(m, :source, File.read!(path))
         end)

  @doc "All bundled example bots, in display order."
  @spec all() :: [map()]
  def all, do: @bots

  @doc "Fetch one example bot by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(id), do: Enum.find(@bots, &(&1.id == id))
end
