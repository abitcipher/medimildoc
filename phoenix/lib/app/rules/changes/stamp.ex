defmodule App.Rules.Changes.Stamp do
  @moduledoc "Who changed the rule set last."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: actor}),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :updated_by_email,
        actor && to_string(actor.email)
      )
end
