defmodule App.Records.Case do
  @moduledoc """
  A case (справа) of the file plan for one year (docs/design/registers-file-plan.md):
  its index (`02-15`), title, retention period and the reference to the
  list of standard documents it comes from, the unit that keeps it, and
  the document types filed into it. A type goes into at most one case a
  year; signed documents of that type and year are filed into it
  (`App.Documents.Changes.Sign`, earlier ones by `App.Records.FilePlan`).

  Read by the records officer and HR; changed by the records officer
  (`records.manage`).
  """
  use Ash.Resource,
    domain: App.Records,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Access.Checks.HasPermission

  postgres do
    table "file_plan_cases"
    repo App.Repo

    references do
      reference :organization, on_delete: :nilify
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {HasPermission, permission: "records.manage"}
      authorize_if {HasPermission, permission: "people.write"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {HasPermission, permission: "records.manage"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :year, :integer do
      allow_nil? false
      public? true
      constraints min: 2000, max: 2100
    end

    attribute :index, :string do
      allow_nil? false
      public? true
      constraints max_length: 20, trim?: true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 300, trim?: true
    end

    # As written in the file plan: "75 р.", "5 р.", "Постійно", "До заміни новими".
    attribute :retention, :string do
      allow_nil? false
      public? true
      constraints max_length: 60, trim?: true
    end

    # For the inventory and disposal (docs/design/registers-file-plan.md
    # §Closing): kept permanently, or for this many years.
    attribute :permanent, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :retention_years, :integer do
      public? true
      constraints min: 1, max: 100
    end

    # Closed at the year's end (or earlier): nothing more is filed into it.
    attribute :closed_on, :date, public?: true
    attribute :closed_by_email, :string, public?: true

    # The article of the list of standard documents ("ст. 16-б").
    attribute :retention_ref, :string do
      public? true
      constraints max_length: 60, trim?: true
    end

    attribute :document_types, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :note, :string do
      public? true
      constraints max_length: 500
    end

    timestamps()
  end

  relationships do
    # The unit that keeps the case.
    belongs_to :organization, App.People.Organization, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :year,
        :index,
        :title,
        :retention,
        :retention_ref,
        :permanent,
        :retention_years,
        :document_types,
        :note,
        :organization_id
      ]

      validate App.Records.Validations.DocumentTypes, before_action?: true
    end

    update :update do
      require_atomic? false

      accept [
        :index,
        :title,
        :retention,
        :retention_ref,
        :permanent,
        :retention_years,
        :document_types,
        :note,
        :organization_id
      ]

      validate App.Records.Validations.DocumentTypes, before_action?: true
    end

    update :close do
      require_atomic? false
      accept []
      validate attribute_equals(:closed_on, nil)
      change set_attribute(:closed_on, &Date.utc_today/0)
      change App.Records.Changes.ClosedBy
    end

    update :reopen do
      accept []
      change set_attribute(:closed_on, nil)
      change set_attribute(:closed_by_email, nil)
    end

    # Only an empty case: the database refuses to remove one that documents
    # are filed into (documents.case_id, on delete restrict);
    # App.Records.FilePlan.delete/2 says so first.
    destroy :destroy do
      primary? true
    end
  end

  identities do
    identity :index_per_year, [:year, :index]
  end
end
