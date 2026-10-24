defmodule App.Rules.Changes.Check do
  @moduledoc """
  FSDC check point on an action (docs/design/data-consistency.md):
  `point: "record.save"` on person records, `"document.submit"` /
  `"document.sign"` on documents, `"assignment.save"` on assignments. Before the write the rules for the point
  and the subject run (`App.Rules.Check`); a `block` violation refuses the
  action. After the transaction — committed or rolled back — every
  violation is written as an incident, so a refused attempt is kept too.

  Prepended before-action: AshCloak's own hook encrypts the `data`
  argument and removes it.
  """
  use Ash.Resource.Change

  alias App.Documents.Changes.Sign
  alias App.Rules.Check
  alias App.Rules.Facts

  # The violations found before the write reach the after-transaction hook
  # through the process dictionary under a reference made here: when a
  # before-action fails, Ash hands that hook the changeset as it was
  # before the hooks ran, without anything they put in its context.
  @impl true
  def change(changeset, opts, %{actor: actor}) do
    point = Keyword.fetch!(opts, :point)
    ref = make_ref()

    changeset
    |> Ash.Changeset.before_action(&evaluate(&1, point, ref), prepend?: true)
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      record(changeset, result, actor, Process.delete({__MODULE__, ref}) || [])
      result
    end)
  end

  defp evaluate(changeset, point, ref) do
    {subject, data} = subject_and_data(changeset)
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)
    at = if String.starts_with?(point, "document."), do: DateTime.utc_now()

    refs = %{
      id: changeset.data && Map.get(changeset.data, :id),
      basis_id: Ash.Changeset.get_attribute(changeset, :basis_id)
    }

    violations =
      Check.run(point, subject, Facts.context(point, subject, person_id, data, at, refs))

    Process.put({__MODULE__, ref}, violations)

    if Check.blocking?(violations) do
      message =
        violations
        |> Enum.filter(&(&1.rule.severity == :block))
        |> Enum.map_join("; ", &(&1.message || &1.code))

      Ash.Changeset.add_error(changeset, message: message)
    else
      changeset
    end
  end

  defp subject_and_data(%{resource: App.Documents.Document} = changeset) do
    document = changeset.data
    {"document:#{document.type}", Sign.stored_data(document)}
  end

  defp subject_and_data(%{resource: App.People.Assignment} = changeset),
    do: {"assignment", assignment_data(changeset)}

  defp subject_and_data(changeset) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    data =
      case Ash.Changeset.fetch_argument(changeset, :data) do
        {:ok, %{} = data} -> data
        _ -> stored_record_data(changeset)
      end

    {"record:#{kind}", data}
  end

  defp stored_record_data(%{action_type: :update, data: %{data: %{} = data}}) do
    if match?(%Ash.NotLoaded{}, data), do: %{}, else: data
  end

  defp stored_record_data(_changeset), do: %{}

  defp assignment_data(changeset) do
    %{
      "positionId" => Ash.Changeset.get_attribute(changeset, :position_id),
      "startsOn" => iso(Ash.Changeset.get_attribute(changeset, :starts_on)),
      "endsOn" => iso(Ash.Changeset.get_attribute(changeset, :ends_on))
    }
  end

  defp iso(%Date{} = date), do: Date.to_iso8601(date)
  defp iso(_value), do: nil

  defp record(changeset, result, actor, violations) do
    case violations do
      [_ | _] ->
        {outcome, id} =
          case result do
            {:ok, record} -> {:saved, record.id}
            _ -> {:refused, changeset.data && Map.get(changeset.data, :id)}
          end

        person_id = Ash.Changeset.get_attribute(changeset, :person_id)
        Check.record(violations, outcome, %{id: id, person_id: person_id}, actor)

      _ ->
        :ok
    end
  end
end
