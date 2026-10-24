defmodule App.People.Validations.AtMostOneCurrentIdentifier do
  @moduledoc """
  Rejects marking a `PersonIdentifier` `is_current: true` when the same
  person already has another *current* identifier of the same
  `id_type`+`country`. A person accumulating a second
  passport number, say, isn't an error — documents get reissued — but
  having two *simultaneously current* passport numbers for the same
  country is: whichever query later asks "what's this person's current
  passport number" would get an ambiguous answer.

  Superseding an old identifier is a two-step, not an implicit side
  effect here: flip the old row to `is_current: false` first (a plain
  `:update`), then create/flip the new one. Not automated on purpose —
  automatically demoting "the other current row" on save would be a
  surprising side effect on a `PersonIdentifier` the caller never
  touched.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :is_current) do
      person_id = Ash.Changeset.get_attribute(changeset, :person_id)
      id_type = Ash.Changeset.get_attribute(changeset, :id_type)
      country = Ash.Changeset.get_attribute(changeset, :country)
      this_id = Ash.Changeset.get_attribute(changeset, :id)

      case other_current_exists?(person_id, id_type, country, this_id) do
        true ->
          {:error,
           field: :is_current,
           message: "already has a current #{id_type} identifier for this country"}

        false ->
          :ok
      end
    else
      :ok
    end
  end

  defp other_current_exists?(person_id, id_type, _country, _this_id)
       when is_nil(person_id) or is_nil(id_type),
       do: false

  defp other_current_exists?(person_id, id_type, country, this_id) do
    require Ash.Query

    App.People.PersonIdentifier
    |> Ash.Query.filter(person_id == ^person_id and id_type == ^id_type and is_current == true)
    |> filter_same_country(country)
    |> then(fn query ->
      if this_id, do: Ash.Query.filter(query, id != ^this_id), else: query
    end)
    |> Ash.exists(authorize?: false)
    |> case do
      {:ok, exists?} -> exists?
      # Same defensive stance as OrganizationParentNotACycle: a query
      # failure here isn't this validation's problem to raise on — treat
      # it as "can't confirm a conflict", not "block the write".
      _ -> false
    end
  end

  # Plain `country == ^country` would silently miss conflicts when
  # `country` is nil on both sides (SQL NULL = NULL is unknown, not
  # true) — plausible here, since several id_types imply a single country
  # and callers may leave it blank. Branching in Elixir (rather than
  # asking the expr DSL to compare `^nil == ^nil`) also sidesteps a
  # spurious "comparing values with nil" warning Ash's expression
  # compiler emits for that pattern.
  defp filter_same_country(query, nil), do: Ash.Query.filter(query, is_nil(country))
  defp filter_same_country(query, country), do: Ash.Query.filter(query, country == ^country)
end
