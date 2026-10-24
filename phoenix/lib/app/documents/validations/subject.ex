defmodule App.Documents.Validations.Subject do
  @moduledoc """
  A document names the person it is about, unless its type is about no
  person (`"subject": "none"`, letters — docs/design/correspondence.md);
  then it names none.
  """
  use Ash.Resource.Validation

  alias App.Documents.Types

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)

    cond do
      type not in Types.ids() ->
        :ok

      Types.about_person?(type) and is_nil(person_id) ->
        {:error, field: :person_id, message: "is required"}

      not Types.about_person?(type) and person_id != nil ->
        {:error, field: :person_id, message: "this document is about no person"}

      true ->
        :ok
    end
  end
end
