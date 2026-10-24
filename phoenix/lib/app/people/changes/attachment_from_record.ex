defmodule App.People.Changes.AttachmentFromRecord do
  @moduledoc """
  For a new `Attachment`: when it goes on a record, checks the record is
  the same person's and copies the record's `kind` and `classification`
  (the attachment's read filter uses them); stamps the uploader's email.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> from_record()
    |> stamp_uploader(context.actor)
  end

  defp from_record(changeset) do
    case Ash.Changeset.get_attribute(changeset, :record_id) do
      nil ->
        changeset

      record_id ->
        person_id = Ash.Changeset.get_attribute(changeset, :person_id)

        case Ash.get(App.People.PersonRecord, record_id, authorize?: false) do
          {:ok, %{person_id: ^person_id} = record} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:kind, record.kind)
            |> Ash.Changeset.force_change_attribute(:classification, record.classification)

          _ ->
            Ash.Changeset.add_error(changeset,
              field: :record_id,
              message: "is not a record of this person"
            )
        end
    end
  end

  defp stamp_uploader(changeset, %{email: email}),
    do: Ash.Changeset.force_change_attribute(changeset, :uploaded_by_email, to_string(email))

  defp stamp_uploader(changeset, _actor), do: changeset
end
