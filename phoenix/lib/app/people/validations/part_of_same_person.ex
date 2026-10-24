defmodule App.People.Validations.PartOfSamePerson do
  @moduledoc """
  A `PersonRecord` may belong to another record (`part_of_id`) only if
  that record is the same person's and of a kind the child's schema
  allows (`x-part-of`; e.g. vital signs within an encounter).
  """
  use Ash.Resource.Validation

  alias App.People.{PersonRecord, PersonRecordSchema}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :part_of_id) do
      nil -> :ok
      parent_id -> check(changeset, parent_id)
    end
  end

  defp check(changeset, parent_id) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)

    allowed =
      if kind in PersonRecordSchema.kinds(), do: PersonRecordSchema.part_of(kind), else: []

    case Ash.get(PersonRecord, parent_id, authorize?: false) do
      {:ok, %{person_id: ^person_id, kind: parent_kind}} ->
        if parent_kind in allowed,
          do: :ok,
          else: {:error, field: :part_of_id, message: "can't belong to a record of this kind"}

      _ ->
        {:error, field: :part_of_id, message: "is not a record of this person"}
    end
  end
end
