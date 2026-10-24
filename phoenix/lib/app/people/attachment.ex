defmodule App.People.Attachment do
  @moduledoc """
  A stored file about a person: a portrait photo, scans, imaging (X-ray,
  CT, MRI — DICOM is downloaded, not viewed), documents
  (docs/design/reference-data-and-files.md). The bytes live in RustFS
  (`App.Storage`) under an opaque `object_key`; this row holds the name,
  type, size, SHA-256 and who uploaded it.

  **Access follows what the file belongs to:**

  - attached to a record (`record_id`): exactly who may read that record —
    the row copies the record's `kind` and `classification`, so the same
    read filter (`App.Access.Checks.ReadableRecords`: category, unit,
    clearance, Break the Glass) applies; writing needs write access to
    that kind;
  - a person's portrait (`purpose: :photo`, no record): anyone who may see
    the person (`people.read`); writing needs `people.write`;
  - any other file about a person: private personal data
    (`people.private.read` / `.write`, unit-scoped).

  Downloads are short-lived signed links (`App.Storage.link/3`); issuing
  one for a sensitive file writes the access log first
  (`App.Audit.AccessLogger.log_file_link/2`).
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Access.SecurityLabels

  postgres do
    table "attachments"
    repo App.Repo

    # Files go with what they belong to (the stored objects are removed by
    # App.People.Changes.DeleteStoredFiles; these catch anything else).
    # Never nilify record_id: a medical file would become a person-level
    # file with different read rules.
    references do
      reference :person, on_delete: :delete
      reference :record, on_delete: :delete
      reference :uploaded_by, on_delete: :nilify
    end

    custom_indexes do
      index [:person_id]
      index [:record_id]
    end
  end

  @purposes [:photo, :document, :imaging, :other]

  @doc "What a file can be: portrait photo, document/scan, imaging, other."
  @spec purposes() :: [atom()]
  def purposes, do: @purposes

  policies do
    policy action_type(:read) do
      authorize_if App.Access.Checks.ReadableAttachments
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if App.Access.Checks.CanWriteAttachment
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :purpose, :atom do
      allow_nil? false
      public? true
      constraints one_of: @purposes
    end

    attribute :file_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :size, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :sha256, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[0-9a-f]{64}$/
    end

    # Opaque: never derived from the file name or the person.
    attribute :object_key, :string do
      allow_nil? false
      public? true
    end

    # Copied from the record at attach time (kept in sync by
    # App.People.Changes.SyncAttachmentLabels), so the record read filter
    # applies to attachments as is. nil for files not on a record.
    attribute :kind, :atom do
      public? true
    end

    attribute :classification, :atom do
      public? true
      constraints one_of: SecurityLabels.classifications()
    end

    attribute :uploaded_by_email, :string do
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :person, App.People.Person do
      allow_nil? false
      public? true
    end

    belongs_to :record, App.People.PersonRecord do
      public? true
    end

    belongs_to :uploaded_by, App.Accounts.User do
      public? true
    end
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      # Stored files go too (App.Storage objects; the rows cascade).
      change App.People.Changes.DeleteStoredFiles
      require_atomic? false
    end

    create :create do
      primary? true

      accept [
        :person_id,
        :record_id,
        :purpose,
        :file_name,
        :content_type,
        :size,
        :sha256,
        :object_key
      ]

      change App.People.Changes.AttachmentFromRecord
      change relate_actor(:uploaded_by, allow_nil?: true)
    end

    update :sync_labels do
      accept [:classification]
    end
  end
end
