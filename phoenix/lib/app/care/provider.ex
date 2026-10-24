defmodule App.Care.Provider do
  @moduledoc """
  An organization providing medical care (docs/design/referral-discharge.md;
  FHIR Organization with a healthcare type). `priority` marks our own
  medical units (user, 2026-09-29: "internal medical units" — no service
  contract, no transfer of information to third parties or system access
  for another organization needed); they come first in every list. An
  external provider records its agreement (`agreement_ref`, `agreement_until`).
  `organization_id` links a priority unit to our organization tree.

  Read by anyone who reads people; written with `providers.manage`.
  """
  use Ash.Resource,
    domain: App.Care,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [
    :name,
    :provider_type,
    :priority,
    :registry_code,
    :country,
    :locality,
    :address,
    :phone,
    :email,
    :agreement_ref,
    :agreement_until,
    :notes,
    :active,
    :organization_id
  ]

  postgres do
    table "care_providers"
    repo App.Repo

    references do
      reference :organization, on_delete: :nilify
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "people.read"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "providers.manage"}
    end
  end

  @types [
    :hospital,
    :clinic,
    :medical_unit,
    :diagnostic_center,
    :laboratory,
    :rehabilitation,
    :dental,
    :pharmacy,
    :other
  ]

  @doc "Provider types."
  @spec types() :: [atom()]
  def types, do: @types

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :provider_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @types
      default :hospital
    end

    attribute :priority, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # A national registry code (e.g. a healthcare facility or company
    # registration number), as written in that registry.
    attribute :registry_code, :string, public?: true, constraints: [max_length: 50]
    # ISO 3166-1 alpha-2 (IHDS, docs/design/reference-data-and-files.md).
    attribute :country, :string, public?: true, constraints: [max_length: 2]
    attribute :locality, :string, public?: true, constraints: [max_length: 200]
    attribute :address, :string, public?: true, constraints: [max_length: 500]
    attribute :phone, :string, public?: true, constraints: [max_length: 50]
    attribute :email, :string, public?: true, constraints: [max_length: 255]
    attribute :agreement_ref, :string, public?: true, constraints: [max_length: 200]
    attribute :agreement_until, :date, public?: true
    attribute :notes, :string, public?: true, constraints: [max_length: 2000]

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    # Generated test data (App.Demo); set only by the generator.
    attribute :synthetic, :boolean do
      allow_nil? false
      public? true
      default false
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, App.People.Organization do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    update :update do
      primary? true
      accept @fields
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
