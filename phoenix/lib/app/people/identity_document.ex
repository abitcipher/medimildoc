defmodule App.People.IdentityDocument do
  @moduledoc """
  A physical/legal identity document held by a `Person` —
  passport, national ID card, military ID, driver's license, birth
  certificate, ... Distinct from `App.People.PersonIdentifier`: a
  document is the *physical artifact* (series/number/issuing
  authority/dates as printed on it); an identifier is a *standing number*
  that may or may not be tied to any single document (an SSN isn't
  printed on any one card; a passport's own number is both — record it
  here as the document's `number`, and separately as a `PersonIdentifier`
  of `id_type: :passport` only if it's also being tracked as a
  cross-referenceable number in its own right; this resource doesn't do
  that linking automatically).

  One row per document a person has ever held, not just the current
  one — `expires_on` alongside real dates lets "currently valid
  documents" be a query (`expires_on is nil or expires_on >= today`)
  rather than a separate flag to keep in sync.

  First-class resource, same reasoning as `PersonIdentifier`: needs real
  relational queries ("documents expiring in the next 30 days"), not a
  polymorphic JSONB blob.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "identity_documents"
    repo App.Repo

    custom_indexes do
      index [:number_digest]
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

  # Encryption at rest (docs/design/access-control-phase1.md): `number`
  # (the document number) is stored encrypted in `encrypted_number`
  # and decrypted only when `:number` is loaded explicitly (where it is
  # shown), so the access log records numbers people actually saw. Access control is still the policies below; this
  # protects database dumps and backups.
  cloak do
    vault App.Vault
    attributes [:number]
    # Logs who read what (App.Audit.AccessLog); refuses to decrypt if it
    # can't.
    on_decrypt {App.Audit.AccessLogger, :on_decrypt, []}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :document_type, :atom do
      allow_nil? false

      constraints one_of: [
                    :passport,
                    :national_id_card,
                    :military_id,
                    :drivers_license,
                    :birth_certificate,
                    :residence_permit,
                    :other
                  ]
    end

    # Many document schemes don't have a separate "series" from "number"
    # (a US passport is just a number) — optional, not required-together
    # with document_type.
    attribute :series, :string do
      allow_nil? true
      constraints max_length: 50
    end

    attribute :number, :string do
      allow_nil? false
      constraints max_length: 100
    end

    # Search hash of `number` (App.Search.Digest, App.People.Changes.SetDigest).
    attribute :number_digest, :string

    attribute :issuing_authority, :string do
      allow_nil? true
      constraints max_length: 255
    end

    # ISO 3166-1 alpha-2 recommended, not enforced — see
    # App.People.PersonIdentifier.country for why.
    attribute :issuing_country, :string do
      allow_nil? true
      constraints max_length: 2
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
    # Internal only (see the forbid policy): rewrites `number` so it is
    # stored under the vault's current default cipher. Used by
    # App.Encryption to encrypt rows that still have plaintext and to
    # re-encrypt after a key rotation. No validations on purpose — it
    # re-stores an existing value, and one legacy row must not block a
    # deploy.
    update :rewrite_encrypted do
      # Recomputes the search hash too (SetDigest), so not atomic.
      require_atomic? false
      accept [:number]
    end

    defaults [:read, :destroy]

    create :create do
      primary? true

      change {App.People.Changes.LearnSuggestedValues,
              fields: [issuing_authority: "issuing_authority"]}

      accept [
        :person_id,
        :document_type,
        :series,
        :number,
        :issuing_authority,
        :issuing_country,
        :issued_on,
        :expires_on,
        :note
      ]

      validate compare(:expires_on, greater_than_or_equal_to: {:ref, :issued_on}) do
        where present(:expires_on)
        message "must be on or after the issue date"
      end
    end

    update :update do
      primary? true

      change {App.People.Changes.LearnSuggestedValues,
              fields: [issuing_authority: "issuing_authority"]}

      accept [
        :document_type,
        :series,
        :number,
        :issuing_authority,
        :issuing_country,
        :issued_on,
        :expires_on,
        :note
      ]

      validate compare(:expires_on, greater_than_or_equal_to: {:ref, :issued_on}) do
        where present(:expires_on)
        message "must be on or after the issue date"
      end

      change App.Audit.DetectChangeConflict
      require_atomic? false
    end
  end

  changes do
    change {App.People.Changes.SetDigest, field: :number, digest: :number_digest},
      on: [:create, :update]
  end
end
