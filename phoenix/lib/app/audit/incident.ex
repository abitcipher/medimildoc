defmodule App.Audit.Incident do
  @moduledoc """
  A data-consistency violation (docs/design/data-consistency.md), treated
  as a potential security incident whether it comes from a mistake or from
  forgery: which rule (and version), at which check point, on which
  subject, by whom, what was decided (refused / saved and flagged /
  observed), the rule's code and message, and the **facts** the rule was
  given — dates, ids, codes, never a record's medical content.

  Written by the rules engine only; read and reviewed with `audit.read`
  (explained — an error, corrected — or confirmed). Never deleted.
  """
  use Ash.Resource,
    domain: App.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "incidents"
    repo App.Repo

    custom_indexes do
      index [:subject_id]
      index [:status]
    end
  end

  policies do
    policy action(:review) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end

    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end

    # Written only by the rules engine; `review` is the one update.
    policy action_type([:create, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :rule_key, :string, allow_nil?: false, public?: true
    attribute :rule_version, :integer, public?: true

    attribute :severity, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:block, :flag, :observe]
    end

    # What happened to the action: refused (block), saved (flag/observe),
    # or found by a sweep over existing data.
    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:refused, :saved, :found]
    end

    attribute :point, :string, allow_nil?: false, public?: true
    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :subject_id, :uuid, public?: true
    attribute :person_id, :uuid, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :actor_email, :string, public?: true
    attribute :code, :string, public?: true
    attribute :message, :string, public?: true
    attribute :facts, :map, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:open, :explained, :confirmed]
      default :open
    end

    attribute :review_note, :string, public?: true
    attribute :reviewed_by_email, :string, public?: true
    attribute :reviewed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, create: :*]

    update :review do
      require_atomic? false
      accept [:status, :review_note]
      validate attribute_in(:status, [:explained, :confirmed])

      change fn changeset, %{actor: actor} ->
        Ash.Changeset.force_change_attributes(changeset, %{
          reviewed_by_email: actor && to_string(actor.email),
          reviewed_at: DateTime.utc_now()
        })
      end
    end
  end
end
