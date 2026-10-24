defmodule App.Documents.Changes.CheckEffects do
  @moduledoc """
  Before sending and before signing: the document's effects must still be
  possible (`App.Documents.Effects.check/1`, e.g. an appointment for
  someone who already holds a post). Otherwise nothing changes and the
  reason is shown.
  """
  use Ash.Resource.Change

  alias App.Documents.Changes.Sign
  alias App.Documents.Effects

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      document = %{changeset.data | data: Sign.stored_data(changeset.data)}

      case Effects.check(document) do
        :ok -> changeset
        {:error, message} -> Ash.Changeset.add_error(changeset, message: message)
      end
    end)
  end
end
