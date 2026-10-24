defmodule App.Api.Validations.GlobalProfiles do
  @moduledoc """
  A service client's profiles exist and are global: a client belongs to
  no unit, so a unit-scoped profile would give it nothing.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    profiles = Ash.Changeset.get_attribute(changeset, :profiles) || []

    case Enum.reject(
           profiles,
           &(&1 in App.Access.profiles() and App.Access.profile_scope(&1) == :global)
         ) do
      [] ->
        :ok

      bad ->
        {:error, field: :profiles, message: "not global access profiles: #{Enum.join(bad, ", ")}"}
    end
  end
end
