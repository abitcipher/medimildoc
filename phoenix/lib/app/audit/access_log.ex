defmodule App.Audit.AccessLog do
  @moduledoc """
  One row per sensitive record a signed-in user read
  (docs/design/access-control-phase1.md): clinical, vetting and
  pay/family records, national ID numbers and document numbers.

  Written by `App.Audit.AccessLogger` at the moment the encrypted value is
  decrypted for that user, so every read path that exposes the value is
  covered — the person page, tables, any future API — not just the ones a
  LiveView remembers to log. Never written by an actor directly (no policy
  authorizes create), and never updated or deleted by the app. Reading it
  needs `audit.read` (the CISO profile).
  """
  use Ash.Resource,
    domain: App.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "access_logs"
    repo App.Repo
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :actor_id, :uuid do
      allow_nil? false
      public? true
    end

    # Denormalized so the log stays readable if the user row ever goes.
    attribute :actor_email, :string do
      allow_nil? false
      public? true
    end

    # The Ash resource module as a string, e.g. "App.People.PersonRecord".
    attribute :resource, :string do
      allow_nil? false
      public? true
    end

    attribute :record_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :person_id, :uuid do
      allow_nil? true
      public? true
    end

    # The record kind (PersonRecord), ID type or document type.
    attribute :kind, :string do
      allow_nil? true
      public? true
    end

    # Why the access happened; set by Break the Glass in phase 2.
    attribute :reason, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :accessed_at
  end

  actions do
    defaults [:read]

    create :log do
      accept [:actor_id, :actor_email, :resource, :record_id, :person_id, :kind, :reason]
    end
  end
end
