defmodule App.Documents.Changes.DecideStep do
  @moduledoc """
  The actor decides their pending step (`opts[:decision]`; a deputy for its
  assignee): approved — once nothing of the round is pending any more, the
  next stage starts (`App.Documents.Route`, docs/design/parallel-approval.md);
  returned — the rest of the round is cancelled and the document goes back
  to its author as a draft;
  signed — the last step is done (App.Documents.Changes.Sign does the
  rest). Who may decide is the policy's job (`CurrentAssignee`).
  """
  use Ash.Resource.Change

  alias App.Documents.Queries

  require Ash.Query

  alias App.Documents.{Route, Step}

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Queries.step_for(context.actor, changeset.data) do
        nil ->
          Ash.Changeset.add_error(changeset, message: "no step is waiting for a decision")

        step ->
          comment = Ash.Changeset.get_argument(changeset, :comment)
          activated = decide(step, opts[:decision], comment, context.actor)
          # Who to tell a document now waits for them (App.Notify.Changes.DocumentEvents).
          Ash.Changeset.put_context(changeset, :activated_assignees, activated)
      end
    end)
  end

  # Returns the assignees of the steps that became pending.
  defp decide(step, decision, comment, actor) do
    # A deputy deciding for the assignee (docs/design/inbox-first.md).
    decided_by = if actor && actor.id != step.assignee_id, do: actor.id

    update(step, %{
      status: decision,
      comment: comment,
      decided_at: DateTime.utc_now(),
      decided_by_id: decided_by
    })

    round =
      Step
      |> Ash.Query.filter(document_id == ^step.document_id and round == ^step.round)
      |> Ash.read!(authorize?: false)

    case decision do
      :approved ->
        active = Route.next_active(round)
        now = DateTime.utc_now()

        round
        |> Enum.filter(&(&1.position in active))
        |> Enum.map(fn next ->
          update(next, %{status: :pending, pending_since: now})
          next.assignee_id
        end)

      :returned ->
        round
        |> Enum.filter(&(&1.status in [:waiting, :pending]))
        |> Enum.each(&update(&1, %{status: :cancelled}))

        []

      _ ->
        []
    end
  end

  defp update(step, attrs) do
    step
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end
end
