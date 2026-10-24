defmodule App.People.Changes.ApplyRecordKindDefaults do
  @moduledoc """
  Fills in what a `PersonRecord` inherits from its kind
  (docs/design/access-control-phase1.md ): the security labels, when
  the caller didn't set them, and the kind's current schema version, which
  is always stamped so a record says which schema its `data` was
  validated against.
  """
  use Ash.Resource.Change

  alias App.People.PersonRecordSchema

  @impl true
  def change(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    if kind in PersonRecordSchema.kinds() do
      changeset
      |> default_attribute(:confidentiality, PersonRecordSchema.default_confidentiality(kind))
      |> default_attribute(:classification, PersonRecordSchema.default_classification(kind))
      |> Ash.Changeset.force_change_attribute(:schema_version, PersonRecordSchema.version(kind))
    else
      changeset
    end
  end

  defp default_attribute(changeset, attribute, value) do
    if is_nil(Ash.Changeset.get_attribute(changeset, attribute)),
      do: Ash.Changeset.force_change_attribute(changeset, attribute, value),
      else: changeset
  end
end
