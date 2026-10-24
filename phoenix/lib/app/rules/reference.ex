defmodule App.Rules.Reference do
  @moduledoc """
  The reference dataset (docs/design/data-consistency.md): the synthetic
  data of `App.Demo.seed/1` with a fixed seed and size, in which a small
  share of records (1–3 %) is deliberately invalid, each labelled with the
  rule and code it must raise. The labels are kept in the repository
  (`priv/reference/rules.json`, written by `mix app.rules.reference`).

  `verify/0` evaluates every rule set — whatever its switches and the FSDC
  setting: it checks the engine and the rules, not the configuration —
  over the synthetic people in the database and compares the violations
  with the labels. It is read-only: no incidents, nothing in the access
  log. Run it after a deployment (`App.Release.verify_rules/0`) on data
  seeded with the reference's seed and size.
  """

  require Ash.Query

  alias App.People.Person
  alias App.Rules.{Check, Facts, RuleSet, Sweep}

  @path "priv/reference/rules.json"

  @type label :: %{String.t() => String.t()}
  @type result :: %{
          checked: non_neg_integer(),
          expected: non_neg_integer(),
          missing: [label()],
          unexpected: [label()]
        }

  @doc "The stored reference (`seed`, `people`, `items`, `invalid`, `expected`)."
  @spec load() :: map()
  def load, do: :app |> Application.app_dir(@path) |> File.read!() |> Jason.decode!()

  @doc "The file the reference is written to, in the source tree."
  @spec source_path() :: String.t()
  def source_path, do: @path

  @doc "The reference for a seed run: its options, counts and sorted labels."
  @spec build(keyword(), map()) :: map()
  def build(opts, counts) do
    %{
      "seed" => Keyword.fetch!(opts, :seed),
      "people" => Keyword.fetch!(opts, :people),
      "items" => counts.items,
      "invalid" => counts.invalid,
      "expected" => counts.planted |> Enum.map(&stringify/1) |> Enum.sort()
    }
  end

  @doc """
  Compares what the rules report on the synthetic data with the stored
  labels. `{:error, :not_seeded}` when the synthetic data isn't the
  reference's size (seed it first: `App.Release.seed_demo/1`).
  """
  @spec verify(map()) :: {:ok, result()} | {:error, :not_seeded}
  def verify(reference \\ load()) do
    people =
      Person
      |> Ash.Query.filter(synthetic == true)
      |> Ash.Query.select([:id, :email])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, to_string(&1.email)})

    if map_size(people) == reference["people"] do
      {:ok, compare(observe(people), reference["expected"])}
    else
      {:error, :not_seeded}
    end
  end

  defp observe(people) do
    rules = Ash.read!(RuleSet, authorize?: false)

    rules
    |> Sweep.subjects(Map.keys(people))
    |> Enum.map(fn {point, subject, entity, data, at} ->
      context = Facts.context(point, subject, entity.person_id, data, at, Sweep.refs(entity))

      violations =
        rules
        |> Enum.filter(&(point in &1.points and subject in &1.subjects))
        |> Check.evaluate(context)
        |> Enum.map(fn violation ->
          %{
            "person" => people[entity.person_id],
            "subject" => subject,
            "rule" => violation.rule.key,
            "code" => violation.code
          }
        end)

      violations
    end)
  end

  defp compare(observed, expected) do
    found = List.flatten(observed)

    %{
      checked: length(observed),
      expected: length(expected),
      missing: Enum.sort(expected -- found),
      unexpected: Enum.sort(found -- expected)
    }
  end

  defp stringify(label), do: Map.new(label, fn {key, value} -> {to_string(key), value} end)
end
