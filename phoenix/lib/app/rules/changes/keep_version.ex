defmodule App.Rules.Changes.KeepVersion do
  @moduledoc "Keeps the graph being replaced as a `RuleSetVersion` and bumps the version."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.force_change_attribute(:version, changeset.data.version + 1)
    |> Ash.Changeset.after_action(fn _changeset, rule_set ->
      App.Rules.RuleSetVersion
      |> Ash.Changeset.for_create(
        :create,
        %{
          key: rule_set.key,
          version: rule_set.version - 1,
          graph: changeset.data.graph,
          replaced_by_email: actor && to_string(actor.email)
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      {:ok, rule_set}
    end)
  end
end
