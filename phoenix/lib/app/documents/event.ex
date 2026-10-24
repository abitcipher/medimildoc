defmodule App.Documents.Event do
  @moduledoc """
  A document's history (ISO 15489 audit trail): one append-only row per
  action — created, sent, approved, returned, signed, cancelled, effect
  applied, acknowledged by the person — with who, when and the comment. Never updated or deleted
  except with the document's person (demo purge).
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_events"
    repo App.Repo

    references do
      reference :document, on_delete: :delete
    end

    custom_indexes do
      index [:document_id]
    end
  end

  policies do
    # Loaded with the document it belongs to, never listed on its own.
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :action, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :created,
                    :submitted,
                    :approved,
                    :returned,
                    :signed,
                    :cancelled,
                    :effect_applied,
                    :acknowledged
                  ]
    end

    attribute :actor_id, :uuid, public?: true
    attribute :actor_email, :string, public?: true
    attribute :comment, :string, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :document, App.Documents.Document, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, create: :*]
  end
end
