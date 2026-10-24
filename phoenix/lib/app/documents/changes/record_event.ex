defmodule App.Documents.Changes.RecordEvent do
  @moduledoc "Appends a history row (`opts[:action]`) after the action succeeded, in its transaction."
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, document ->
      write(
        document,
        opts[:action],
        context.actor,
        Ash.Changeset.get_argument(changeset, :comment)
      )

      {:ok, document}
    end)
  end

  @doc "Writes one history row for `document` (also used by effects)."
  @spec write(map(), atom(), map() | nil, String.t() | nil) :: :ok
  def write(document, action, actor, comment) do
    App.Documents.Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        document_id: document.id,
        action: action,
        actor_id: actor && actor.id,
        actor_email: actor && to_string(actor.email),
        comment: comment
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    :ok
  end
end
