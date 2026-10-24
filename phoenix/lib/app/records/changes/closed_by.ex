defmodule App.Records.Changes.ClosedBy do
  @moduledoc "Who closed a case (their e-mail, kept even if the account goes)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{email: email}}),
    do: Ash.Changeset.force_change_attribute(changeset, :closed_by_email, to_string(email))

  def change(changeset, _opts, _context), do: changeset
end
