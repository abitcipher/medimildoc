defmodule App.People.Organization do
  @moduledoc """
  A company, department, team, or (NATO-standard
  decomposition) military unit/formation — self-referential, so a brigade
  can contain battalions, a battalion companies, or a civilian department
  can contain teams. `kind` is a plain constrained atom rather than a fixed
  enum baked into the table, so adding an echelon/org type is a one-line
  change here, not a migration ("modular growth").
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "organizations"
    repo App.Repo
  end

  policies do
    # Permissions, not roles (docs/design/access-control-phase1.md);
    # which roles and profiles hold them is priv/access_profiles.json.
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.read"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.write"}
    end
  end

  attributes do
    # See App.People.Assignment for why uuid_v7.
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      constraints max_length: 255
    end

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:company, :department, :team, :unit, :brigade, :battalion, :division]
      default :department
    end

    # Where the unit is (ORG-GRAPH.1, docs/design/org-graph.md): an ISO
    # 3166-1 alpha-2 country and a locality, picked from IHDS like a
    # person's birthplace (the code when it came from the list). A unit
    # without one is where its parent is.
    attribute :country, :string do
      allow_nil? true
      constraints max_length: 2
    end

    attribute :locality, :string do
      allow_nil? true
      constraints max_length: 255
    end

    attribute :locality_code, :string do
      allow_nil? true
      constraints max_length: 32
    end

    # Generated test data (App.Demo, docs/design/access-control-phase1.md
    # §7). Not accepted by any action: only the generator sets it, via
    # force_change_attribute. Shown as a badge; App.Demo.purge/0 deletes by it.
    attribute :synthetic, :boolean do
      allow_nil? false
      public? true
      default false
    end

    timestamps()
  end

  relationships do
    belongs_to :parent, __MODULE__ do
      allow_nil? true
    end

    has_many :children, __MODULE__ do
      destination_attribute :parent_id
    end

    has_many :positions, App.People.Position
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :kind, :parent_id, :country, :locality, :locality_code]
      validate App.People.Validations.OrganizationParentNotACycle
    end

    update :update do
      primary? true
      accept [:name, :kind, :parent_id, :country, :locality, :locality_code]
      validate App.People.Validations.OrganizationParentNotACycle
      change App.Audit.DetectChangeConflict
      # Both the validation and the conflict-detection change above do
      # their own Ash.get!/Ash.get calls — can't be expressed as a single
      # atomic SQL UPDATE.
      require_atomic? false
    end
  end
end
