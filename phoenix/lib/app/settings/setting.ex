defmodule App.Settings.Setting do
  @moduledoc "One system setting (`App.Settings`): key, value, who changed it and when."
  use Ash.Resource,
    domain: App.Settings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "settings"
    repo App.Repo
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "settings.manage"}
    end
  end

  attributes do
    attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
    # %{"v" => value}: any JSON value.
    attribute :value, :map, allow_nil?: false, public?: true
    attribute :updated_by_email, :string, public?: true
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :put do
      accept [:key, :value]
      upsert? true
      upsert_fields [:value, :updated_by_email, :updated_at]

      change fn changeset, %{actor: actor} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :updated_by_email,
          actor && to_string(actor.email)
        )
      end
    end
  end
end
