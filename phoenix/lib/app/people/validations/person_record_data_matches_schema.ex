defmodule App.People.Validations.PersonRecordDataMatchesSchema do
  @moduledoc """
  Ash validation-callback adapter around the pure
  `App.People.PersonRecordSchema.validate/2` — enforces "JSON
  Schema is mandatory for every data type" at the resource layer itself, not
  just in a future form.
  """
  use Ash.Resource.Validation

  @impl true
  #
  # `data` is encrypted at rest (AshCloak, docs/design/access-control-phase1.md
  # so it arrives as an action argument, not an attribute. An update
  # that doesn't pass `data` leaves the stored value untouched, and there is
  # nothing to validate; a create without it validates an empty map.
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    case Ash.Changeset.fetch_argument(changeset, :data) do
      {:ok, data} -> validate_data(kind, data || %{})
      :error when changeset.action_type == :create -> validate_data(kind, %{})
      :error -> :ok
    end
  end

  defp validate_data(kind, data) do
    case App.People.PersonRecordSchema.validate(kind, data) do
      :ok -> :ok
      {:error, errors} -> {:error, field: :data, message: Enum.join(errors, "; ")}
    end
  end
end
