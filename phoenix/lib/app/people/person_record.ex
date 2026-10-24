defmodule App.People.PersonRecord do
  @moduledoc """
  Modular, JSON-Schema-validated extension data for a person — the
  mechanism. `kind` selects which JSON Schema
  (`App.People.PersonRecordSchema`) governs `data`; adding a new kind means
  dropping in schema files, not a migration or a resource change — `kind`'s
  own `one_of` constraint and every UI kind-picker read
  `PersonRecordSchema.kinds()` directly, never a separate hardcoded list
  `data` may be FHIR-flavored (`:medical_condition`),
  NATO-STANAG-flavored (`:rank_history`, `:contact_info`,
  `:language_proficiency`, explicitly *not* verified
  against the primary standards texts), or plain (`:status_change`,
  `:family_status`, `:compensation`, `:dependent`) — see
  `priv/person_record_schemas/` for exactly what shape each kind expects.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias App.Access.SecurityLabels
  alias App.People.PersonRecordSchema

  postgres do
    table "person_records"
    repo App.Repo

    # Deleting an encounter keeps its vital signs, as records of their own.
    references do
      reference :part_of, on_delete: :nilify
    end

    custom_indexes do
      index [:part_of_id]
    end
  end

  policies do
    # App.Encryption calls this with authorize?: false; no actor may.
    policy action(:rewrite_encrypted) do
      forbid_if always()
    end

    # docs/design/access-control-phase1.md each kind belongs to a
    # category (declared in its schema file), and reading or writing a
    # record needs that category's permission. Reads are a filter, so
    # records the actor may not see are never returned at all.
    policy action_type(:read) do
      authorize_if App.Access.Checks.ReadableRecords
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if App.Access.Checks.CanWriteRecordKind
    end
  end

  # Encryption at rest (docs/design/access-control-phase1.md): `data`
  # (medical and vetting details, pay, family — every kind shares this one
  # attribute, so one rule covers them all) is stored encrypted in
  # `encrypted_data` and decrypted on read. Access control is still the policies below; this
  # protects database dumps and backups.
  cloak do
    vault App.Vault
    attributes [:data]
    decrypt_by_default [:data]
    # Logs who read what (App.Audit.AccessLog); refuses to decrypt if it
    # can't.
    on_decrypt {App.Audit.AccessLogger, :on_decrypt, []}
  end

  attributes do
    # See App.People.Assignment for why uuid_v7.
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: PersonRecordSchema.kinds()
    end

    attribute :data, :map do
      allow_nil? false
      default %{}
    end

    # Which version of that kind's JSON Schema this record was validated
    # against — schemas will evolve; old rows shouldn't silently become
    # unreadable when they do.
    attribute :schema_version, :string do
      allow_nil? false
      default "1"
    end

    # Security labels (docs/design/access-control-phase1.md), modelled
    # on FHIR meta.security. Defaulted from the kind on create
    # (App.People.Changes.ApplyRecordKindDefaults); can be raised, never
    # lowered below the kind's default.
    attribute :confidentiality, :atom do
      allow_nil? false
      public? true
      constraints one_of: SecurityLabels.confidentiality_levels()
    end

    attribute :classification, :atom do
      allow_nil? true
      public? true
      constraints one_of: SecurityLabels.classifications()
    end

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
    end

    # When the fact became true, if different from when it was recorded
    # (e.g. a diagnosis entered today for a condition that started weeks ago).
    attribute :effective_on, :date do
      allow_nil? true
    end

    # The record this one belongs to, of the same person: vital signs
    # within an encounter (docs/design/clinical-module.md). Which kinds may
    # belong to which is declared in the child kind's schema (`x-part-of`).
    attribute :part_of_id, :uuid do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :person, App.People.Person do
      allow_nil? false
    end

    belongs_to :part_of, __MODULE__ do
      source_attribute :part_of_id
      define_attribute? false
    end

    has_many :parts, __MODULE__ do
      destination_attribute :part_of_id
    end

    # Files on this record (App.People.Attachment), loaded through their
    # own read policy.
    has_many :attachments, App.People.Attachment do
      destination_attribute :record_id
    end
  end

  actions do
    # Internal only (see the forbid policy): rewrites `data` so it is
    # stored under the vault's current default cipher. Used by
    # App.Encryption to encrypt rows that still have plaintext and to
    # re-encrypt after a key rotation. No validations on purpose — it
    # re-stores an existing value, and one legacy row must not block a
    # deploy.
    update :rewrite_encrypted do
      # Also re-derives effective_on (SetEffectiveOn), so not atomic.
      require_atomic? false
      accept [:data]
    end

    defaults [:read]

    destroy :destroy do
      primary? true
      # Stored files go too (App.Storage objects; the rows cascade).
      change App.People.Changes.DeleteStoredFiles
      require_atomic? false
    end

    create :create do
      primary? true
      change {App.People.Changes.LearnSuggestedValues, record_data: true}

      accept [
        :person_id,
        :kind,
        :data,
        :effective_on,
        :confidentiality,
        :classification,
        :part_of_id
      ]

      validate App.People.Validations.PartOfSamePerson
      change App.People.Changes.ApplyRecordKindDefaults
      change App.Clinical.Changes.CodeMedication
      change App.Clinical.Changes.InterpretLab
      change {App.Rules.Changes.Check, point: "record.save"}
      validate App.People.Validations.PersonRecordDataMatchesSchema
      validate App.People.Validations.RecordLabelsNotBelowKindDefault
    end

    update :update do
      primary? true
      change {App.People.Changes.LearnSuggestedValues, record_data: true}
      # The JSON Schema validation calls out to Elixir (ex_json_schema),
      # not expressible as a single atomic SQL statement.
      require_atomic? false
      accept [:data, :effective_on, :confidentiality, :classification, :part_of_id]
      validate App.People.Validations.PartOfSamePerson
      change App.People.Changes.ApplyRecordKindDefaults
      change App.Clinical.Changes.CodeMedication
      change App.Clinical.Changes.InterpretLab
      change {App.Rules.Changes.Check, point: "record.save"}
      validate App.People.Validations.PersonRecordDataMatchesSchema
      validate App.People.Validations.RecordLabelsNotBelowKindDefault
      change App.Audit.DetectChangeConflict
      change App.People.Changes.SyncAttachmentLabels
    end
  end

  changes do
    # The plain date a record is about, for the timeline (App.People.RecordDates).
    change App.People.Changes.SetEffectiveOn, on: [:create, :update]
  end
end
