defmodule App.People.BiometricRecord do
  @moduledoc """
  A biometric capture belonging to a `Person` — facial
  photo, signature, or a fingerprint (one row per finger captured, hence
  `finger`). **Structure only, deliberately not wired to any upload UI or
  storage backend yet** — `storage_key` is just a placeholder string
  field for wherever the actual file ends up (local disk, S3-compatible
  object storage, ...), a decision this resource intentionally doesn't
  make. Biometric data is categorically more sensitive than anything
  else in this system (GDPR Art. 9 "special category" territory, and
  similar under most other jurisdictions' data-protection law) — actual
  capture/storage wiring needs its own explicit decision (where it's
  stored, whether raw images or derived templates only, retention/
  consent handling), not a side effect of adding this resource shape.

  Same uniform access rule as every other People resource
  for now (any role reads, admin/hr writes) — arguably the single
  strongest candidate in this whole system for a narrower read policy
  not implemented here without being asked.

  First-class resource, not a `PersonRecord` kind, for the same "needs
  its own shape, not a JSON blob" reasoning as `PersonIdentifier`/
  `IdentityDocument` — though unlike those two, there's no meaningful
  cross-record uniqueness to enforce here (a person can have any number
  of biometric captures of any modality over time).
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "biometric_records"
    repo App.Repo
  end

  policies do
    # Private personal data: only holders of people.private.* (HR,
    # registrar; admin while ADMIN_FULL_DATA_ACCESS is on). A plain
    # viewer no longer sees these (docs/design/access-control-phase1.md).
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.private.read"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.private.write"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :modality, :atom do
      allow_nil? false
      constraints one_of: [:photo, :signature, :fingerprint]
    end

    # Only meaningful (and required) when modality == :fingerprint —
    # enforced by the create/update actions' own validation below, not a
    # blanket allow_nil?: false, since it's genuinely N/A for :photo/
    # :signature.
    attribute :finger, :atom do
      allow_nil? true

      constraints one_of: [
                    :left_thumb,
                    :left_index,
                    :left_middle,
                    :left_ring,
                    :left_pinky,
                    :right_thumb,
                    :right_index,
                    :right_middle,
                    :right_ring,
                    :right_pinky
                  ]
    end

    # Where the actual file lives — deliberately opaque (no assumed
    # scheme) until a storage backend is chosen; nil is expected/normal
    # until then. See moduledoc.
    attribute :storage_key, :string do
      allow_nil? true
      constraints max_length: 500
    end

    attribute :content_type, :string do
      allow_nil? true
      constraints max_length: 100
    end

    attribute :captured_on, :date do
      allow_nil? true
    end

    attribute :note, :string do
      allow_nil? true
      constraints max_length: 1000
    end

    timestamps()
  end

  relationships do
    belongs_to :person, App.People.Person do
      allow_nil? false
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:person_id, :modality, :finger, :storage_key, :content_type, :captured_on, :note]

      validate present(:finger) do
        where attribute_equals(:modality, :fingerprint)
        message "is required when modality is fingerprint"
      end

      validate absent(:finger) do
        where attribute_does_not_equal(:modality, :fingerprint)
        message "is only meaningful when modality is fingerprint"
      end
    end

    update :update do
      primary? true
      accept [:modality, :finger, :storage_key, :content_type, :captured_on, :note]

      validate present(:finger) do
        where attribute_equals(:modality, :fingerprint)
        message "is required when modality is fingerprint"
      end

      validate absent(:finger) do
        where attribute_does_not_equal(:modality, :fingerprint)
        message "is only meaningful when modality is fingerprint"
      end

      change App.Audit.DetectChangeConflict
      require_atomic? false
    end
  end
end
