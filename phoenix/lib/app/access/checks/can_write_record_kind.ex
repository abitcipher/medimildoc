defmodule App.Access.Checks.CanWriteRecordKind do
  @moduledoc """
  Write check for `PersonRecord`: the actor holds the write permission of
  the record's category — everywhere, or, for unit-scoped profiles
  (docs/design/access-control-phase2.md), only for people currently in
  their unit. On create the kind and person come from the changeset; on
  update and destroy from the stored record (neither changes after
  creation).
  """
  use Ash.Policy.SimpleCheck

  alias App.Access.{RecordAccess, Unit}
  alias App.People.PersonRecordSchema

  @impl true
  def describe(_opts), do: "actor may write records of this kind (in scope)"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    if kind in PersonRecordSchema.kinds() do
      case RecordAccess.kind_scope(actor, kind, :write) do
        :global ->
          true

        :unit ->
          changeset
          |> Ash.Changeset.get_attribute(:person_id)
          |> Unit.person_in_unit?(Unit.org_ids(actor))

        :none ->
          false
      end
    else
      false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
