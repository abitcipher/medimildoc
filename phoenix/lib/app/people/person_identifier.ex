defmodule App.People.PersonIdentifier do
  @moduledoc """
  A standing personal-identification number issued to a `Person` by some
  authority — a national tax/civil ID (INN, RNOKPP, PESEL,
  SSN, ...), not a physical document (see `App.People.IdentityDocument`
  for those). One row per number: a person legitimately accumulates
  several over a lifetime (a foreign residency's NIE alongside a home
  country's SSN; a reissued number after a name change) — `is_current`
  marks which one(s) are still valid, see
  `App.People.Validations.AtMostOneCurrentIdentifier` for what that does
  and doesn't enforce.

  `id_type` is a fixed-but-extensible atom list, not free text — every
  entry so far is a widely-known code covering multiple countries at
  once (:nif is used by both Spain and Portugal; :steuer_id and :id_nr
  are the same German number under its colloquial vs. official name),
  which is exactly why `country` is its own separate field rather than
  folded into the type. `:other` plus `other_type_label` is the escape
  hatch for anything not on the list — same "don't wait for a closed
  enum" posture as `PersonRecordSchema`'s kind-per-file mechanism, just
  without the file-per-kind ceremony since every id_type here shares one
  shape (type + country + value), unlike `PersonRecord.data`.

  A first-class resource, not a `PersonRecord` kind — needs real
  relational uniqueness (e.g. "does anyone else already have this SSN"),
  which a polymorphic JSONB blob doesn't give for free. `value` is
  genuinely sensitive PII; no encryption-at-rest is applied yet — flagged
  as a follow-up, not solved here.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "person_identifiers"
    repo App.Repo

    custom_indexes do
      index [:value_digest]
    end
  end

  policies do
    # App.Encryption calls this with authorize?: false; no actor may.
    policy action(:rewrite_encrypted) do
      forbid_if always()
    end

    # Private personal data: only holders of people.private.* (HR,
    # registrar; admin while ADMIN_FULL_DATA_ACCESS is on). A plain
    # viewer no longer sees these (docs/design/access-control-phase1.md).
    policy action_type(:read) do
      authorize_if {App.Access.Checks.ScopedPermission, permission: "people.private.read"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.private.write"}
    end
  end

  # Encryption at rest (docs/design/access-control-phase1.md): `value`
  # (the national ID number itself) is stored encrypted in `encrypted_value`
  # and decrypted only when `:value` is loaded explicitly (where it is
  # shown), so the access log records numbers people actually saw. Access control is still the policies below; this
  # protects database dumps and backups.
  cloak do
    vault App.Vault
    attributes [:value]
    # Logs who read what (App.Audit.AccessLog); refuses to decrypt if it
    # can't.
    on_decrypt {App.Audit.AccessLogger, :on_decrypt, []}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :id_type, :atom do
      allow_nil? false

      constraints one_of: [
                    :passport,
                    :inn,
                    :rnokpp,
                    :unzr,
                    :pesel,
                    :nip,
                    :id_nr,
                    :steuer_id,
                    :nino,
                    :nie,
                    :nif,
                    :codice_fiscale,
                    :ssn,
                    :sin,
                    :other
                  ]
    end

    # Only meaningful (and expected) when id_type == :other — not
    # validated as required-together, same "don't over-constrain a
    # free-text escape hatch" stance as PersonRecordSchema's :status_change.
    attribute :other_type_label, :string do
      allow_nil? true
      constraints max_length: 100
    end

    # ISO 3166-1 alpha-2 recommended, not enforced (see App.People.Person's
    # birth_country for why: shape, not a verified authoritative list).
    # Optional even though several id_types imply a single country
    # (:ssn -> US) — callers aren't forced to fill in the redundant obvious
    # case, but should for id_types that aren't country-specific (:nif,
    # :passport) if they want AtMostOneCurrentIdentifier to actually
    # discriminate between them.
    attribute :country, :string do
      allow_nil? true
      constraints max_length: 2
    end

    attribute :value, :string do
      allow_nil? false
      constraints max_length: 255
    end

    # Search hash of `value` (App.Search.Digest, App.People.Changes.SetDigest).
    attribute :value_digest, :string

    attribute :is_current, :boolean do
      allow_nil? false
      default true
    end

    attribute :issuing_authority, :string do
      allow_nil? true
      constraints max_length: 255
    end

    attribute :issued_on, :date do
      allow_nil? true
    end

    attribute :expires_on, :date do
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
    # Internal only (see the forbid policy): rewrites `value` so it is
    # stored under the vault's current default cipher. Used by
    # App.Encryption to encrypt rows that still have plaintext and to
    # re-encrypt after a key rotation. No validations on purpose — it
    # re-stores an existing value, and one legacy row must not block a
    # deploy.
    update :rewrite_encrypted do
      # Recomputes the search hash too (SetDigest), so not atomic.
      require_atomic? false
      accept [:value]
    end

    defaults [:read, :destroy]

    create :create do
      primary? true

      change {App.People.Changes.LearnSuggestedValues,
              fields: [issuing_authority: "issuing_authority"]}

      accept [
        :person_id,
        :id_type,
        :other_type_label,
        :country,
        :value,
        :is_current,
        :issuing_authority,
        :issued_on,
        :expires_on,
        :note
      ]

      validate compare(:expires_on, greater_than_or_equal_to: {:ref, :issued_on}) do
        where present(:expires_on)
        message "must be on or after the issue date"
      end

      validate App.People.Validations.AtMostOneCurrentIdentifier
    end

    update :update do
      primary? true

      change {App.People.Changes.LearnSuggestedValues,
              fields: [issuing_authority: "issuing_authority"]}

      accept [
        :id_type,
        :other_type_label,
        :country,
        :value,
        :is_current,
        :issuing_authority,
        :issued_on,
        :expires_on,
        :note
      ]

      validate compare(:expires_on, greater_than_or_equal_to: {:ref, :issued_on}) do
        where present(:expires_on)
        message "must be on or after the issue date"
      end

      validate App.People.Validations.AtMostOneCurrentIdentifier

      change App.Audit.DetectChangeConflict
      # AtMostOneCurrentIdentifier does its own Ash.exists/2 query before
      # the write (same reason Organization/PersonRecord need this).
      require_atomic? false
    end
  end

  changes do
    change {App.People.Changes.SetDigest, field: :value, digest: :value_digest},
      on: [:create, :update]
  end
end
