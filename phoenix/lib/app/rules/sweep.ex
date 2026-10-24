defmodule App.Rules.Sweep do
  @moduledoc """
  Checks existing data against the rules (docs/design/data-consistency.md):
  a rule switched on later still finds old violations. Person records are
  checked as if saved (`record.save`), signed documents as if signed
  (`document.sign`, at their signing time), assignments as if saved
  (`assignment.save`). A violation already open for
  the same rule and subject isn't recorded twice; new ones become
  incidents with outcome `:found`. Runs only while FSDC is on.
  """

  require Ash.Query

  alias App.Documents.Document
  alias App.People.PersonRecord
  alias App.Rules.{Check, Facts, RuleSet}

  @spec run(map() | nil) :: %{checked: non_neg_integer(), found: non_neg_integer()}
  def run(actor) do
    if App.Settings.fsdc?() do
      rules = RuleSet |> Ash.Query.filter(enabled == true) |> Ash.read!(authorize?: false)
      open = open_incidents()

      {checked, found} =
        rules
        |> subjects()
        |> Enum.reduce({0, 0}, fn {point, subject, entity, data, at}, {checked, found} ->
          context = Facts.context(point, subject, entity.person_id, data, at, refs(entity))

          new =
            point
            |> Check.run(subject, context)
            |> Enum.reject(&MapSet.member?(open, {&1.rule.key, entity.id}))

          Check.record(new, :found, %{id: entity.id, person_id: entity.person_id}, actor)
          {checked + 1, found + length(new)}
        end)

      %{checked: checked, found: found}
    else
      %{checked: 0, found: 0}
    end
  end

  @doc """
  What the rules can check among existing data, as `{point, subject,
  entity, data, at}`: records of the kinds they name, signed documents of
  the types they name. `person_ids` narrows it to those people.
  """
  @spec subjects([map()], [String.t()] | nil) :: [tuple()]
  def subjects(rules, person_ids \\ nil) do
    Enum.concat([
      records(rules, person_ids),
      documents(rules, person_ids),
      assignments(rules, person_ids)
    ])
  end

  @doc "What the facts need to know about an entity (`App.Rules.Facts.context/6`)."
  @spec refs(map()) :: map()
  def refs(entity), do: %{id: entity.id, basis_id: Map.get(entity, :basis_id)}

  defp for_people(query, nil), do: query
  defp for_people(query, ids), do: Ash.Query.filter(query, person_id in ^ids)

  defp kinds(rules, point, prefix) do
    rules
    |> Enum.filter(&(point in &1.points))
    |> Enum.flat_map(& &1.subjects)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&(&1 |> String.replace_prefix(prefix, "") |> String.to_existing_atom()))
    |> Enum.uniq()
  end

  defp records(rules, person_ids) do
    case kinds(rules, "record.save", "record:") do
      [] ->
        []

      kinds ->
        PersonRecord
        |> Ash.Query.filter(kind in ^kinds)
        |> for_people(person_ids)
        |> Ash.Query.load(:data)
        |> Ash.read!(authorize?: false)
        |> Enum.map(&{"record.save", "record:#{&1.kind}", &1, &1.data, nil})
    end
  end

  defp documents(rules, person_ids) do
    case kinds(rules, "document.sign", "document:") do
      [] ->
        []

      types ->
        Document
        |> Ash.Query.filter(type in ^types and state == :signed)
        |> for_people(person_ids)
        |> Ash.Query.load(:data)
        |> Ash.read!(authorize?: false)
        |> Enum.map(&{"document.sign", "document:#{&1.type}", &1, &1.data, &1.signed_at})
    end
  end

  defp assignments(rules, person_ids) do
    if Enum.any?(rules, &("assignment.save" in &1.points and "assignment" in &1.subjects)) do
      App.People.Assignment
      |> for_people(person_ids)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{"assignment.save", "assignment", &1, assignment_data(&1), nil})
    else
      []
    end
  end

  defp assignment_data(assignment) do
    %{
      "positionId" => assignment.position_id,
      "startsOn" => Date.to_iso8601(assignment.starts_on),
      "endsOn" => assignment.ends_on && Date.to_iso8601(assignment.ends_on)
    }
  end

  defp open_incidents do
    App.Audit.Incident
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false)
    |> MapSet.new(&{&1.rule_key, &1.subject_id})
  end
end
