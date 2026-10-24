defmodule App.Rules.RuleSet do
  @moduledoc """
  One rule set (docs/design/data-consistency.md): a JDM graph returning
  `%{"valid", "code", "message"}`, with a severity (`block` refuses the
  action, `flag` saves and marks, `observe` only records; each violation
  is an incident), the check points it runs at (`record.save`,
  `document.submit`, `document.sign`) and the subjects it applies to
  (`record:<kind>`, `document:<type>`).

  Seeded from `priv/rules/*.json` (`App.Rules.Library.sync/0`); edited in
  the JDM Editor. Every saved graph becomes a new version; the previous
  one is kept in `App.Rules.RuleSetVersion`.
  """
  use Ash.Resource,
    domain: App.Rules,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "rule_sets"
    repo App.Repo
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "rules.manage"}
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end

    policy action([:seed, :ship]) do
      forbid_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "rules.manage"}
    end
  end

  attributes do
    attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :severity, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:block, :flag, :observe]
      default :flag
    end

    attribute :points, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :subjects, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true
    attribute :graph, :map, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :updated_by_email, :string, public?: true
    timestamps()
  end

  actions do
    defaults [:read]

    create :seed do
      accept [:key, :label, :description, :severity, :points, :subjects, :graph, :version]
    end

    # Internal: a newer shipped version (App.Rules.Library.sync/0), only for
    # rule sets nobody edited in the app. Keeps severity and on/off.
    update :ship do
      accept [:label, :description, :points, :subjects, :graph, :version]
    end

    update :configure do
      require_atomic? false
      accept [:severity, :enabled]
      change App.Rules.Changes.Stamp
    end

    update :update_graph do
      require_atomic? false
      accept [:graph]
      change App.Rules.Changes.ValidateGraph
      change App.Rules.Changes.KeepVersion
      change App.Rules.Changes.Stamp
    end
  end
end
