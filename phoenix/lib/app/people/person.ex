defmodule App.People.Person do
  @moduledoc """
  Core identity only — deliberately minimal. Everything that changes over a
  person's life (medical history, status changes, pay, family status,
  service record, ...) lives in `App.People.PersonRecord` or a future
  first-class resource, never bolted onto this attribute list — keeping
  this resource stable is what keeps the rest of the model extensible.

  Extended "core identity" with the basics a real identity
  record needs (patronymic, place of birth) directly as attributes here —
  they don't change over a person's life, so they don't belong in
  `PersonRecord`. What DOES vary in *count* over a lifetime (national ID
  numbers, identity documents, biometric captures — someone can have
  several, of several types, some superseded) lives in three sibling
  first-class resources instead, for the same reason `Assignment` is a
  resource and not a `PersonRecord` kind: they need real relational
  uniqueness/lookup (e.g. "has anyone else already got this SSN"), which
  a polymorphic JSONB `data` blob doesn't give you for free.
  `App.People.PersonIdentifier`, `App.People.IdentityDocument`,
  `App.People.BiometricRecord`.
  """
  use Ash.Resource,
    domain: App.People,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "people"
    repo App.Repo
  end

  policies do
    # Permissions, not roles (docs/design/access-control-phase1.md);
    # which roles and profiles hold them is priv/access_profiles.json.
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.read"}
      # Everyone reads their own person (docs/design/events-and-person-login.md:
      # the role person has no people.read; their tasks and documents load it).
      authorize_if expr(id == ^actor(:person_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.write"}
    end
  end

  attributes do
    # See App.People.Assignment for why uuid_v7 (not a Postgres-native
    # feature dependency — Ash generates it app-side).
    uuid_v7_primary_key :id

    attribute :given_name, :string do
      allow_nil? false
      constraints max_length: 255
    end

    attribute :family_name, :string do
      allow_nil? false
      constraints max_length: 255
    end

    # Optional — many naming systems (patronymic given names, e.g.
    # Ukrainian/Russian) have one, many don't.
    # Kept as a plain third name component, not folded into given_name —
    # keeps given/family/patronymic independently sortable/displayable,
    # matching how the identity documents that carry this name usually
    # print all three separately.
    attribute :patronymic, :string do
      allow_nil? true
      constraints max_length: 255
    end

    # Deliberately not unique/required here: at first entry into the system
    # a person may not have an account or even a known email yet.
    # Added "may or may not have" data at creation time). Linking this
    # to the sheets_token `sub` claim (App.SheetsToken) is a future step,
    # not assumed here.
    attribute :email, :string do
      allow_nil? true
      constraints max_length: 255
    end

    attribute :date_of_birth, :date do
      allow_nil? true
    end

    # Place of birth — three separate fields, not one
    # free-text string, so each is independently queryable/displayable
    # (e.g. "everyone born in region X"). ISO 3166-1 alpha-2 recommended
    # for `birth_country` (interop with the FHIR/identifier work — a
    # country CODE, not name, is what cross-references cleanly against
    # `PersonIdentifier.country` below), but not enforced by a `match`
    # constraint: unlike `birth_region`/`birth_locality` (inherently
    # free-text — administrative subdivisions and settlement names don't
    # have one universal code), forcing a closed code list on country of
    # birth would wrongly reject entries for places whose sovereignty
    # changed, historical states, etc. Same reasoning as
    # `grade` fields: shape, not a verified authoritative list.
    attribute :birth_country, :string do
      allow_nil? true
      constraints max_length: 2
    end

    attribute :birth_region, :string do
      allow_nil? true
      constraints max_length: 255
    end

    attribute :birth_locality, :string do
      allow_nil? true
      constraints max_length: 255
    end

    # Optional reference codes next to the free-text fields above
    # (docs/design/reference-data-and-files.md, step 3): set when the place
    # was picked from IHDS — a KATOTTH code in Ukraine, a GeoNames id
    # elsewhere; regions: KATOTTH level-1 code or GeoNames admin1 "FR.11".
    # A place not in the list keeps only its text.
    attribute :birth_region_code, :string do
      allow_nil? true
      constraints max_length: 32
    end

    attribute :birth_locality_code, :string do
      allow_nil? true
      constraints max_length: 32
    end

    # A short, human-memorable secondary identifier;
    # never client-supplied (not in any action's `accept`, and
    # `writable? false` here as a second guard; a code the app generated
    # and showed can be proposed on create — Changes.ProposedPersonId) — `default` runs the
    # same way `uuid_v7_primary_key`'s does (Ash.UUIDv7.generate/0),
    # just with a DB-backed uniqueness check baked in. See
    # `App.People.PersonId` for the shape/keyspace/uniqueness story.
    attribute :person_id, :string do
      allow_nil? false
      writable? false
      default &App.People.PersonId.generate_unique/0
      constraints max_length: 12
    end

    # Generated test data (App.Demo, docs/design/access-control-phase1.md)
    # Not accepted by any action: only the generator sets it, via
    # force_change_attribute. Shown as a badge; App.Demo.purge/0 deletes by it.
    attribute :synthetic, :boolean do
      allow_nil? false
      public? true
      default false
    end

    timestamps()
  end

  relationships do
    has_many :assignments, App.People.Assignment
    has_many :records, App.People.PersonRecord
    has_many :identifiers, App.People.PersonIdentifier
    has_many :identity_documents, App.People.IdentityDocument
    has_many :biometric_records, App.People.BiometricRecord
    has_many :attachments, App.People.Attachment

    # The sign-in account linked to this person, if any
    # (docs/design/access-control-phase2.md).
    has_one :account, App.Accounts.User do
      destination_attribute :person_id
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
        :given_name,
        :family_name,
        :patronymic,
        :email,
        :date_of_birth,
        :birth_country,
        :birth_region,
        :birth_region_code,
        :birth_locality,
        :birth_locality_code
      ]

      # A PersonID the app generated and showed before saving (SHEETS-UI).
      argument :proposed_person_id, :string
      change App.People.Changes.ProposedPersonId
    end

    update :update do
      primary? true

      accept [
        :given_name,
        :family_name,
        :patronymic,
        :email,
        :date_of_birth,
        :birth_country,
        :birth_region,
        :birth_region_code,
        :birth_locality,
        :birth_locality_code
      ]

      change App.Audit.DetectChangeConflict
      # The conflict-detection change does its own Ash.get/3 before the
      # write — can't be expressed as a single atomic SQL UPDATE.
      require_atomic? false
    end
  end

  identities do
    # The real backstop behind App.People.PersonId.generate_unique/0's
    # check-and-retry loop — belt and suspenders against
    # a race between two concurrent creates that both pass the
    # pre-insert check for the same candidate.
    identity :unique_person_id, [:person_id]
  end

  @doc """
  `"given_name [patronymic] family_name"` — the one place this
  composition happens, so `patronymic` actually shows up
  everywhere a person's name is displayed, instead of every call site
  independently interpolating `given_name`/`family_name` and forgetting
  it (as several already had before this helper existed).
  """
  @spec full_name(t()) :: String.t()
  def full_name(%__MODULE__{patronymic: nil} = person) do
    "#{person.given_name} #{person.family_name}"
  end

  def full_name(%__MODULE__{} = person) do
    "#{person.given_name} #{person.patronymic} #{person.family_name}"
  end
end
