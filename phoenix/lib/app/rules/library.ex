defmodule App.Rules.Library do
  @moduledoc """
  The rule sets shipped with the app (`priv/rules/*.json`): each file is a
  rule set (key, label, description, severity, points, subjects) with its
  JDM `graph`. `sync/0` adds the ones missing from the database, and
  upgrades a shipped rule set to a newer shipped `version` only if nobody
  has edited it in the app (no `updated_by_email`); the graph it replaces
  is kept as a `RuleSetVersion`. Rule sets edited in the JDM Editor are
  left alone. Runs after migrations (`App.Release.migrate/0`) and in tests.
  """

  alias App.Rules.RuleSet

  @spec files() :: [map()]
  def files do
    Application.app_dir(:app, "priv/rules")
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  @doc "Adds or upgrades shipped rule sets (see the moduledoc); returns how many changed."
  @spec sync() :: non_neg_integer()
  def sync do
    existing = RuleSet |> Ash.read!(authorize?: false) |> Map.new(&{&1.key, &1})
    files = files()

    added =
      files
      |> Enum.reject(&Map.has_key?(existing, &1["key"]))
      |> Enum.map(&seed/1)
      |> length()

    upgraded =
      files
      |> Enum.filter(&upgradable?(existing[&1["key"]], &1))
      |> Enum.map(&upgrade(existing[&1["key"]], &1))
      |> length()

    added + upgraded
  end

  defp upgradable?(nil, _file), do: false

  defp upgradable?(rule, file),
    do: is_nil(rule.updated_by_email) and (file["version"] || 1) > rule.version

  defp upgrade(rule, file) do
    App.Rules.RuleSetVersion
    |> Ash.Changeset.for_create(
      :create,
      %{key: rule.key, version: rule.version, graph: rule.graph, replaced_by_email: nil},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    rule
    |> Ash.Changeset.for_update(
      :ship,
      %{
        label: file["label"],
        description: file["description"],
        points: file["points"],
        subjects: file["subjects"],
        graph: file["graph"],
        version: file["version"]
      },
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end

  defp seed(file) do
    RuleSet
    |> Ash.Changeset.for_create(
      :seed,
      %{
        key: file["key"],
        label: file["label"],
        description: file["description"],
        severity: String.to_existing_atom(file["severity"]),
        points: file["points"],
        subjects: file["subjects"],
        graph: file["graph"],
        version: file["version"] || 1
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
