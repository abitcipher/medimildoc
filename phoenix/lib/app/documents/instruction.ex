defmodule App.Documents.Instruction do
  @moduledoc """
  An instruction (resolution) on a registered incoming letter
  (docs/design/correspondence.md): what to do, who does it, by when. Given
  by the records officer or a head covering the letter's unit
  (`Checks.MayInstruct`); closed by its executor or whoever gave it, with
  a note — or by a signed reply (`App.Documents.Instructions.close_by_reply/1`).
  The executor may read the letter and write the reply.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Documents.Checks

  postgres do
    table "document_instructions"
    repo App.Repo

    references do
      reference :document, on_delete: :delete
      reference :executor, on_delete: :nilify
      reference :issued_by, on_delete: :nilify
      reference :reply, on_delete: :nilify
    end

    custom_indexes do
      index [:document_id]
      index [:executor_id, :status]
    end
  end

  policies do
    policy action(:give) do
      authorize_if Checks.MayInstruct
    end

    policy action(:complete) do
      authorize_if expr(executor_id == ^actor(:id) or issued_by_id == ^actor(:id))
    end

    # The document page reads them as the system after reading the letter.
    policy action_type(:read) do
      authorize_if expr(executor_id == ^actor(:id) or issued_by_id == ^actor(:id))
    end

    # Replies close them (App.Documents.Instructions, authorize?: false).
    policy action([:close_by_reply, :remind]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints max_length: 2000, trim?: true
    end

    attribute :due_on, :date, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :done]
    end

    attribute :done_at, :utc_datetime_usec, public?: true

    attribute :done_note, :string do
      public? true
      constraints max_length: 2000
    end

    attribute :reminded_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :document, App.Documents.Document, allow_nil?: false, public?: true
    belongs_to :executor, App.Accounts.User, allow_nil?: false, public?: true
    belongs_to :issued_by, App.Accounts.User, public?: true
    # The signed reply that closed it.
    belongs_to :reply, App.Documents.Document, public?: true
  end

  actions do
    defaults [:read]

    create :give do
      accept [:document_id, :text, :executor_id, :due_on]
      change relate_actor(:issued_by)
      change App.Documents.Changes.NotifyInstruction
    end

    update :complete do
      require_atomic? false
      accept [:done_note]
      validate attribute_equals(:status, :open)
      change set_attribute(:status, :done)
      change set_attribute(:done_at, &DateTime.utc_now/0)
      change App.Documents.Changes.NotifyInstruction
    end

    update :close_by_reply do
      accept [:reply_id]
      change set_attribute(:status, :done)
      change set_attribute(:done_at, &DateTime.utc_now/0)
    end

    update :remind do
      accept [:reminded_at]
    end
  end
end
