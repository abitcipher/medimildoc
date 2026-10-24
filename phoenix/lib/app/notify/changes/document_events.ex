defmodule App.Notify.Changes.DocumentEvents do
  @moduledoc """
  Notifications from a document's route (docs/design/search-timeline-notifications.md),
  written in the same transaction as the action (the outbox):

  - sent or approved → `:document_waiting` to whoever's step is now pending
    and to their active deputies;
  - returned → `:document_returned` to the author;
  - signed → `:document_signed` to the author and, for self-service types,
    to the person's own account; for an order the person acknowledges
    (docs/design/acknowledgements.md), also `:document_to_acknowledge` to
    the person's own account.

  Runs after the route changes of the action (placed last).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Documents.{Deputies, Step, Types}
  alias App.Notify.Emitter

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn changeset, document ->
      recipients =
        case {event, changeset.context[:activated_assignees]} do
          # A decision: only those whose steps it started (none while a
          # parallel stage is still running).
          {:waiting, activated} when is_list(activated) -> with_deputies(activated)
          _ -> recipients(event, document)
        end

      Emitter.emit(event_name(event), recipients, params(document))

      if event == :signed and Types.acknowledge?(document.type),
        do: Emitter.emit(:document_to_acknowledge, own_accounts(document), params(document))

      {:ok, document}
    end)
  end

  defp event_name(:waiting), do: :document_waiting
  defp event_name(:returned), do: :document_returned
  defp event_name(:signed), do: :document_signed

  # The assignees and their active deputies (docs/design/inbox-first.md).
  defp recipients(:waiting, document) do
    Step
    |> Ash.Query.filter(document_id == ^document.id and status == :pending)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.assignee_id)
    |> with_deputies()
  end

  defp recipients(:returned, document), do: [document.author_id]

  defp recipients(:signed, document) do
    own = if Types.self_service?(document.type), do: own_accounts(document), else: []
    [document.author_id | own]
  end

  defp with_deputies(assignees),
    do: assignees ++ (assignees |> Deputies.of() |> Map.values() |> List.flatten())

  # The account linked to the person the document is about (none for a
  # document about no person).
  defp own_accounts(%{person_id: nil}), do: []

  defp own_accounts(document) do
    App.Accounts.User
    |> Ash.Query.filter(person_id == ^document.person_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  @doc "What a document's notification names: its type, number and link."
  @spec params(map()) :: map()
  def params(document) do
    %{
      type: Types.label(document.type),
      number: document.number,
      path: "/documents/#{document.id}"
    }
  end
end
