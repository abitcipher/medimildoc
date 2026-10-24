defmodule App.Documents.DocumentFile do
  @moduledoc """
  A file that belongs to a document (docs/design/correspondence.md): the
  scan of an incoming letter, an enclosure. Added and removed only while
  the document is a draft, by someone who may write it
  (`App.Documents.Files`); its SHA-256 is part of the signed content hash.
  Read only through its document, like the document's history.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_files"
    repo App.Repo

    references do
      reference :document, on_delete: :delete
      reference :uploaded_by, on_delete: :nilify
    end

    custom_indexes do
      index [:document_id]
    end
  end

  # Everything goes through App.Documents.Files (authorize?: false) after
  # it has checked the document itself.
  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :file_name, :string, allow_nil?: false, public?: true
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :size, :integer, allow_nil?: false, public?: true
    attribute :sha256, :string, allow_nil?: false, public?: true
    attribute :object_key, :string, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :document, App.Documents.Document, allow_nil?: false, public?: true
    belongs_to :uploaded_by, App.Accounts.User, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :document_id,
        :file_name,
        :content_type,
        :size,
        :sha256,
        :object_key,
        :uploaded_by_id
      ]
    end
  end
end
