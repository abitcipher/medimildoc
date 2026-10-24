defmodule App.People.Changes.SetEffectiveOn do
  @moduledoc """
  Sets a person record's `effective_on` from its data
  (`App.People.RecordDates`) unless it was given. Reads the `data`
  argument in a before-action prepended ahead of AshCloak's, which
  removes it.
  """
  use Ash.Resource.Change

  alias App.People.RecordDates

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(
      changeset,
      fn changeset ->
        with :error <- Ash.Changeset.fetch_change(changeset, :effective_on),
             {:ok, data} <- Ash.Changeset.fetch_argument(changeset, :data),
             %Date{} = date <- RecordDates.from_data(data) do
          Ash.Changeset.force_change_attribute(changeset, :effective_on, date)
        else
          _ -> changeset
        end
      end,
      prepend?: true
    )
  end
end
