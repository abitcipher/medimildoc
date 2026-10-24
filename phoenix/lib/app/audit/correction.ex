defmodule App.Audit.Correction do
  @moduledoc """
  A direct change to data that is normally changed by a signed document
  (user, 2026-09-29: "orders preferred, direct edits remain — keep a
  correction path, which is logged"). One row per created, changed or
  deleted assignment that has no basis order: who, when, what changed.
  Append-only; read with `audit.read`.
  """
  use Ash.Resource,
    domain: App.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "corrections"
    repo App.Repo

    custom_indexes do
      index [:person_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end

    # Written only by App.Audit.LogCorrection (authorize?: false).
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :resource, :string, allow_nil?: false, public?: true
    attribute :record_id, :uuid, allow_nil?: false, public?: true
    attribute :person_id, :uuid, public?: true

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:create, :update, :destroy]
    end

    attribute :actor_id, :uuid, public?: true
    attribute :actor_email, :string, public?: true
    # Changed attributes as {from, to} (plain values: posts and dates).
    attribute :changes, :map, public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, create: :*]
  end
end
