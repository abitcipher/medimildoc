defmodule App.Documents.Changes.CreateSteps do
  @moduledoc """
  Sending a draft: one route step per chosen assignee, in route order, as a
  new round (a returned document sent again gets fresh steps; the old ones
  stay as history). The first step is pending, the rest wait.

  `assignees` has one list per route entry; an entry takes exactly one
  assignee unless it allows several (`"multiple": true`, board members),
  and every assignee must hold the entry's permission. Checked before the
  write (it reads users), so a wrong choice changes nothing.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Documents.{Access, Route, Step, Types}
  alias App.Documents.Changes.Sign

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&check_assignees/1)
    |> Ash.Changeset.after_action(fn changeset, document ->
      create_steps(document, Ash.Changeset.get_argument(changeset, :assignees))
      {:ok, document}
    end)
  end

  defp check_assignees(changeset) do
    route = Types.route(changeset.data.type)
    assignees = Ash.Changeset.get_argument(changeset, :assignees) || []

    problem =
      cond do
        length(assignees) != length(route) ->
          "choose assignees for every step"

        not Enum.all?(Enum.zip(route, assignees), &count_fits?/1) ->
          "each step needs one assignee (several only where the route allows)"

        not Enum.all?(Enum.zip(route, assignees), &eligible?(&1, document(changeset))) ->
          "an assignee does not hold the permission for their step"

        true ->
          nil
      end

    if problem,
      do: Ash.Changeset.add_error(changeset, field: :assignees, message: problem),
      else: changeset
  end

  # One assignee, or none where the entry is optional, several where it
  # allows them (docs/design/parallel-approval.md).
  defp count_fits?({entry, []}), do: entry["optional"] == true
  defp count_fits?({entry, ids}), do: entry["multiple"] == true or length(ids) == 1

  # Every assignee holds the step's permission for this document (unit
  # scope included: a commander of an unrelated unit can't sign).
  defp eligible?({entry, ids}, document) do
    users = App.Accounts.User |> Ash.Query.filter(id in ^ids) |> Ash.read!(authorize?: false)

    length(users) == length(Enum.uniq(ids)) and
      Enum.all?(users, &Access.holds?(&1, entry["permission"], document))
  end

  defp document(changeset),
    do: %{changeset.data | data: Sign.stored_data(changeset.data)}

  # One step per assignee, in route order; an optional entry left empty
  # has none. The first stage starts (all of it when parallel).
  defp create_steps(document, assignees) do
    round = next_round(document.id)

    steps =
      document.type
      |> Types.route()
      |> Enum.zip(assignees)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{entry, ids}, stage} -> Enum.map(ids, &{entry, stage, &1}) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{entry, stage, assignee_id}, position} ->
        %{
          document_id: document.id,
          round: round,
          position: position,
          stage: stage,
          parallel: entry["parallel"] == true,
          action: String.to_existing_atom(entry["action"]),
          label: entry["label"],
          assignee_id: assignee_id,
          status: :waiting
        }
      end)

    active = Route.next_active(steps)
    now = DateTime.utc_now()

    Enum.each(steps, fn attrs ->
      attrs =
        if attrs.position in active,
          do: %{attrs | status: :pending} |> Map.put(:pending_since, now),
          else: attrs

      Step
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!(authorize?: false)
    end)
  end

  defp next_round(document_id) do
    Step
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.round)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end
end
