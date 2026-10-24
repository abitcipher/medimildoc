defmodule App.People.Position do
  @moduledoc """
  A billet/post within an `App.People.Organization` — a title plus an
  optional `reports_to` position, forming the reporting chain at the
  *position* level (NATO/military convention: the chain of command belongs
  to the post, not whoever currently holds it). A person's current manager
  is derived by following `reports_to` to whoever currently occupies that
  position (`App.People.current_manager/2`), never stored redundantly on
  the person.

  `authorised_grade` is the *billet's* established
  grade — what the post is nominally graded at — deliberately separate
  from `App.People.PersonRecordSchema`'s `:rank_history`, which tracks a
  *person's* actual grade over time. The two can legitimately disagree
  (an under- or over-graded incumbent is normal, not a data error); this
  resource makes no attempt to reconcile them. Same illustrative,
  APERSP-01-shaped-but-unverified pattern as `:rank_history`'s `grade`
  — not a verified closed code set.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "positions"
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

    attribute :title, :string do
      allow_nil? false
      constraints max_length: 255
    end

    # Illustrative APERSP-01-shaped placeholder, same caveat as
    # PersonRecordSchema's :rank_history — see moduledoc.
    attribute :authorised_grade, :string do
      allow_nil? true

      constraints match: ~r/^(OF|OR)-?[0-9]{1,2}$|^OF\(D\)$/
    end

    # Authorised strength: how many people this post is for ("Rifleman
    # ×10"). One post per title, unit, grade and reporting line (identity
    # below); several holders share it instead of identical copies.
    attribute :strength, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 1000
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, App.People.Organization do
      allow_nil? false
    end

    belongs_to :reports_to, __MODULE__ do
      allow_nil? true
    end

    has_many :direct_reports, __MODULE__ do
      destination_attribute :reports_to_id
    end

    has_many :assignments, App.People.Assignment
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :organization_id, :reports_to_id, :authorised_grade, :strength]
    end

    update :update do
      primary? true
      accept [:title, :organization_id, :reports_to_id, :authorised_grade, :strength]
      change App.Audit.DetectChangeConflict
      require_atomic? false
    end
  end

  identities do
    # No two posts alike: the same title, unit, grade and reporting line is
    # one post with a strength. nil equals nil here (a post without a grade
    # or manager still collides with its copy).
    identity :unique_post, [:title, :organization_id, :authorised_grade, :reports_to_id],
      nils_distinct?: false,
      message: "an identical post exists in this unit; raise its strength instead"
  end

  aggregates do
    # People holding the post now (compare with `strength`).
    count :holders, :assignments do
      filter expr(is_nil(ends_on))
      public? true
    end
  end
end
