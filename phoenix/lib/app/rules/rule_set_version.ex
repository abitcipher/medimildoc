defmodule App.Rules.RuleSetVersion do
  @moduledoc "A previous graph of a rule set, kept when it was replaced (append-only)."
  use Ash.Resource,
    domain: App.Rules,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "rule_set_versions"
    repo App.Repo

    custom_indexes do
      index [:key, :version], unique: true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "rules.manage"}
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true
    attribute :graph, :map, allow_nil?: false, public?: true
    attribute :replaced_by_email, :string, public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, create: :*]
  end
end
