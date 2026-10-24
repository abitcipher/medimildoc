defmodule App.People.Changes.DeleteStoredFiles do
  @moduledoc """
  On destroying an `Attachment`, a `PersonRecord` or a `Person`: removes
  the stored objects of the files that go with it (the database cascade
  removes the rows). The keys are collected before the delete; the objects
  are removed after it succeeded, so a failed delete leaves both in place.
  A storage error is logged, not raised: the data is gone either way, and
  an orphaned object is unreachable without its row.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias App.People.Attachment

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.put_context(
        changeset,
        :stored_file_keys,
        keys(changeset.resource, changeset.data)
      )
    end)
    |> Ash.Changeset.after_action(fn changeset, result ->
      Enum.each(changeset.context[:stored_file_keys] || [], &delete_object/1)
      {:ok, result}
    end)
  end

  defp delete_object(key) do
    with {:error, reason} <- App.Storage.delete(key) do
      Logger.warning("stored file #{key} not deleted: #{inspect(reason)}")
    end
  end

  defp keys(Attachment, attachment), do: [attachment.object_key]

  defp keys(App.People.PersonRecord, record), do: object_keys(record_id: record.id)
  defp keys(App.People.Person, person), do: object_keys(person_id: person.id)

  defp object_keys(filter) do
    Attachment
    |> Ash.Query.filter(^filter)
    |> Ash.Query.select([:object_key])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.object_key)
  end
end
