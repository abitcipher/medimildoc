defmodule App.People.Changes.ProposedPersonId do
  @moduledoc """
  A new person's PersonID chosen in advance (SHEETS-UI: the sidebar shows
  it before saving and can generate another if the first looks
  unsightly). The argument `proposed_person_id` is only ever a code the
  app generated (`App.People.PersonId.generate_unique/0`) and showed —
  it is still checked: the shape (`PersonId.valid?/1`) here, and that no
  one holds it in a before_action hook (no DB reads in a change body);
  the unique identity is the final backstop. Without it the attribute's
  own default generates one, as before.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.People.PersonId

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :proposed_person_id) do
      nil ->
        changeset

      proposed ->
        code = PersonId.unformat(proposed)

        if PersonId.valid?(code) do
          changeset
          |> Ash.Changeset.force_change_attribute(:person_id, code)
          |> Ash.Changeset.before_action(&not_taken(&1, code))
        else
          Ash.Changeset.add_error(changeset,
            field: :proposed_person_id,
            message: "is not a PersonID the app would generate"
          )
        end
    end
  end

  defp not_taken(changeset, code) do
    taken? =
      App.People.Person
      |> Ash.Query.filter(person_id == ^code)
      |> Ash.exists?(authorize?: false)

    if taken?,
      do: Ash.Changeset.add_error(changeset, field: :proposed_person_id, message: "is taken"),
      else: changeset
  end
end
