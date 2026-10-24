defmodule App.Documents.Acknowledgement do
  @moduledoc """
  The person a signed order is about has acknowledged it
  (docs/design/acknowledgements.md): once per document, never changed or
  deleted — a record of fact. Either by the person in the app
  (`:acknowledge`, today, `method: :self`), or recorded on their behalf
  (`:record`) by HR or a commander who covers them — read out in person or
  signed on paper, on a date.

  Read only through its document (as the system, after the document itself
  was read through its policies), like the document's history.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Documents.Checks

  postgres do
    table "document_acknowledgements"
    repo App.Repo

    references do
      reference :document, on_delete: :delete
      reference :person, on_delete: :delete
      reference :recorded_by, on_delete: :nilify
    end

    custom_indexes do
      index [:person_id]
    end
  end

  policies do
    policy action(:acknowledge) do
      authorize_if Checks.AcknowledgeOwn
    end

    policy action(:record) do
      authorize_if Checks.CanRecordAcknowledgement
    end

    policy action_type(:read) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Today unless recorded for an earlier day (App.Documents.Changes.Acknowledge
    # checks the range).
    attribute :acknowledged_on, :date do
      allow_nil? false
      public? true
      default &Date.utc_today/0
    end

    # self — by the person in the app; in_person — read out to them (at a
    # formation, a briefing); paper — they signed a paper sheet.
    attribute :method, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:self, :in_person, :paper]
    end

    attribute :recorded_by_email, :string, public?: true

    attribute :note, :string do
      public? true
      constraints max_length: 500
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :document, App.Documents.Document, allow_nil?: false, public?: true
    belongs_to :person, App.People.Person, allow_nil?: false, public?: true
    belongs_to :recorded_by, App.Accounts.User, public?: true
  end

  actions do
    defaults [:read]

    # The person, in the app, today.
    create :acknowledge do
      accept [:document_id]
      change set_attribute(:method, :self)
      change App.Documents.Changes.Acknowledge
    end

    # On the person's behalf: read out in person or signed on paper.
    create :record do
      accept [:document_id, :acknowledged_on, :method, :note]
      validate attribute_in(:method, [:in_person, :paper])
      change App.Documents.Changes.Acknowledge
    end
  end

  identities do
    identity :one_per_document, [:document_id]
  end
end
