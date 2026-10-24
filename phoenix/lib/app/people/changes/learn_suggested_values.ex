defmodule App.People.Changes.LearnSuggestedValues do
  @moduledoc """
  After a successful save, tells IHDS which organisational names were
  entered, so they are suggested next time (docs/design/reference-data-and-files.md,
  step 3; `App.IHDS.learn/2`). Only values that are new or changed are
  sent, and only for the categories `App.IHDS.learned_categories/0` allows.

  Options:

  - `fields: [issuing_authority: "issuing_authority"]` — attribute →
    category, for plain resources;
  - `record_data: true` — for `PersonRecord`: every property of the
    kind's JSON Schema marked `"x-suggest": "<category>"`.

  IHDS stores the bare value and a count, never which person or record it
  came from; the call runs in the background and cannot fail the save.
  """
  use Ash.Resource.Change

  alias App.People.PersonRecordSchema

  @impl true
  def change(changeset, opts, _context) do
    changeset
    # Read in a before-action hook that runs first: the `data` argument
    # is only set by then, and AshCloak's own before-action hook removes
    # it when it encrypts the value.
    |> Ash.Changeset.before_action(
      fn changeset ->
        values =
          attribute_values(changeset, opts[:fields] || []) ++
            record_values(changeset, opts[:record_data])

        Ash.Changeset.put_context(changeset, :learn_values, values)
      end,
      prepend?: true
    )
    # Sent only once the save succeeded.
    |> Ash.Changeset.after_action(fn changeset, result ->
      for {category, value} <- changeset.context[:learn_values] || [],
          do: App.IHDS.learn(category, value)

      {:ok, result}
    end)
  end

  defp attribute_values(changeset, fields) do
    for {field, category} <- fields,
        Ash.Changeset.changing_attribute?(changeset, field),
        value = Ash.Changeset.get_attribute(changeset, field),
        is_binary(value),
        do: {category, value}
  end

  defp record_values(_changeset, falsy) when falsy in [nil, false], do: []

  defp record_values(changeset, true) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    properties = (PersonRecordSchema.schema(kind) || %{})["properties"] || %{}

    case Ash.Changeset.fetch_argument(changeset, :data) do
      {:ok, %{} = data} ->
        previous = previous_data(changeset)

        for {key, %{"x-suggest" => category}} <- properties,
            value = data[key],
            is_binary(value),
            value != previous[key],
            do: {category, value}

      _ ->
        []
    end
  end

  # The stored data when it was loaded for this update (decrypted);
  # otherwise nothing to compare with, and every value counts as new.
  defp previous_data(%{action_type: :update, data: %{data: %{} = data}}), do: data
  defp previous_data(_changeset), do: %{}
end
