defmodule App.People.Changes.SetDigest do
  @moduledoc """
  Keeps the search hash of an encrypted identifier (`App.Search.Digest`)
  in step with its value, on every create and update (re-encryption
  included). Reads the value argument in a before-action prepended ahead
  of AshCloak's own, which removes it.
  """
  use Ash.Resource.Change

  alias App.Search.Digest

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.fetch!(opts, :field)
    digest_field = Keyword.fetch!(opts, :digest)

    Ash.Changeset.before_action(
      changeset,
      fn changeset ->
        case Ash.Changeset.fetch_argument(changeset, field) do
          {:ok, value} ->
            Ash.Changeset.force_change_attribute(
              changeset,
              digest_field,
              Digest.digest(value)
            )

          :error ->
            changeset
        end
      end,
      prepend?: true
    )
  end
end
