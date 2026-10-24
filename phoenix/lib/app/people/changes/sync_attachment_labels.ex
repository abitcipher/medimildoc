defmodule App.People.Changes.SyncAttachmentLabels do
  @moduledoc """
  On a `PersonRecord` update: when its classification changes, its files
  get the same classification, so they stay exactly as readable as the
  record (`App.People.Attachment`).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :classification) do
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        App.People.Attachment
        |> Ash.Query.filter(record_id == ^record.id)
        |> Ash.bulk_update!(:sync_labels, %{classification: record.classification},
          authorize?: false,
          strategy: [:atomic, :stream]
        )

        {:ok, record}
      end)
    else
      changeset
    end
  end
end
