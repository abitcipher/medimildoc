defmodule App.Access.Checks.CanWriteAttachment do
  @moduledoc """
  Adding or deleting a file needs write access to what it belongs to: the
  record's kind (`CanWriteRecordKind`), `people.write` for a portrait
  photo, `people.private.write` for other files about a person.
  """
  use Ash.Policy.SimpleCheck

  alias App.Access.Checks.CanWriteRecordKind

  @impl true
  def describe(_opts), do: "actor may write the file's record or person"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset} = context, opts) do
    cond do
      Ash.Changeset.get_attribute(changeset, :record_id) ->
        CanWriteRecordKind.match?(actor, context, opts)

      Ash.Changeset.get_attribute(changeset, :purpose) == :photo ->
        App.Access.can?(actor, "people.write")

      true ->
        App.Access.can?(actor, "people.private.write")
    end
  end

  def match?(_actor, _context, _opts), do: false
end
