defmodule App.People.Assignment do
  @moduledoc """
  One entry in a person's assignment history to an `App.People.Position` —
  `ends_on: nil` means
  currently active; a person accumulates any number of past assignments, a
  full history rather than a single overwritten "current position" field.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "assignments"
    repo App.Repo

    references do
      reference :basis_document, on_delete: :nilify
      reference :end_document, on_delete: :nilify
    end
  end

  policies do
    # Permissions, not roles (docs/design/access-control-phase1.md);
    # which roles and profiles hold them is priv/access_profiles.json.
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.read"}
    end

    policy action([:from_order, :end_by_order]) do
      forbid_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.write"}
    end
  end

  attributes do
    # Ash-generated (app-side, Ash.UUIDv7.generate/0), monotonic per node —
    # not dependent on Postgres's own native uuidv7(); still upgrading to
    # PG18 project-wide per the "latest stable" decision.
    uuid_v7_primary_key :id

    attribute :starts_on, :date do
      allow_nil? false
    end

    attribute :ends_on, :date do
      allow_nil? true
    end

    timestamps()
  end

  relationships do
    belongs_to :person, App.People.Person do
      allow_nil? false
    end

    belongs_to :position, App.People.Position do
      allow_nil? false
    end

    # The signed order this assignment (or its end) comes from
    # (docs/design/documents-core.md, personnel orders); nil for a direct
    # change, which App.Audit.LogCorrection records instead.
    belongs_to :basis_document, App.Documents.Document do
      allow_nil? true
      public? true
    end

    # The signed order that ended it (transfer or release).
    belongs_to :end_document, App.Documents.Document do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      # The correction row needs the record, not an atomic statement.
      require_atomic? false
      change App.Audit.LogCorrection
    end

    create :create do
      primary? true
      accept [:person_id, :position_id, :starts_on, :ends_on]
      # A direct change (not by a signed order) is logged.
      change App.Audit.LogCorrection
      change {App.Rules.Changes.Check, point: "assignment.save"}

      validate compare(:ends_on, greater_than_or_equal_to: {:ref, :starts_on}) do
        where present(:ends_on)
        message "must be on or after the start date"
      end
    end

    # Internal: the effects of a signed personnel order (App.Documents.Effects,
    # run with authorize?: false). They carry the order and are not
    # corrections.
    create :from_order do
      accept [:person_id, :position_id, :starts_on, :basis_document_id]
      change {App.Rules.Changes.Check, point: "assignment.save"}
    end

    update :end_by_order do
      require_atomic? false
      accept [:ends_on, :end_document_id]
      change {App.Rules.Changes.Check, point: "assignment.save"}

      validate compare(:ends_on, greater_than_or_equal_to: {:ref, :starts_on}) do
        message "must be on or after the start date"
      end
    end

    update :update do
      primary? true
      accept [:starts_on, :ends_on]
      change App.Audit.LogCorrection
      change {App.Rules.Changes.Check, point: "assignment.save"}

      validate compare(:ends_on, greater_than_or_equal_to: {:ref, :starts_on}) do
        where present(:ends_on)
        message "must be on or after the start date"
      end

      change App.Audit.DetectChangeConflict
      require_atomic? false
    end
  end

  calculations do
    calculate :current?, :boolean, expr(is_nil(ends_on))
  end
end
