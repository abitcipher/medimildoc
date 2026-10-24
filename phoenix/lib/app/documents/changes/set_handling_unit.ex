defmodule App.Documents.Changes.SetHandlingUnit do
  @moduledoc """
  The unit that handles a document (docs/design/documents-core.md §Access):
  the unit of the post it names (`position`, an appointment of a newcomer
  in no unit yet) or of the care provider it names (`provider`, when the
  provider is one of our units). Unit-scoped users of that unit may read
  and handle the document as well as those of the person's unit.

  Kept in plain `handling_unit_id` (the fields are encrypted) and set from
  the `data` argument before AshCloak's own hook removes it — with
  `recipient_provider_id`, the care provider the document is addressed to
  (what an external system may read, docs/design/fhir-api.md).
  """
  use Ash.Resource.Change

  alias App.Documents.Access

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(
      changeset,
      fn changeset ->
        case Ash.Changeset.fetch_argument(changeset, :data) do
          {:ok, %{} = data} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:handling_unit_id, Access.handling_unit(data))
            |> Ash.Changeset.force_change_attribute(
              :recipient_provider_id,
              Access.recipient_provider(data)
            )

          _ ->
            changeset
        end
      end,
      prepend?: true
    )
  end
end
