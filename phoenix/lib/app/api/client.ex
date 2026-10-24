defmodule App.Api.Client do
  @moduledoc """
  A client of the FHIR read API (docs/design/fhir-api.md).

  - `:service` — an integration created by an admin (`users.manage`),
    acting with the access profiles given to it (global-scope profiles
    only: a client belongs to no unit).
  - `:personal` — a token a person creates to read their own record; only
    for accounts linked to a person.
  - `:external` — a medical system of a care provider from the register
    (docs/design/fhir-api.md): no static token; it proves itself
    with a JWT signed by its private key (SMART backend services,
    `App.Api.Smart`), checked against the public keys registered here
    (`jwks`), and reads only what `scopes` allow, about patients referred
    to its provider.

  The token is generated here and returned once (metadata `:token`); only
  its SHA-256 is stored, with its first characters to recognize it.
  """
  use Ash.Resource,
    domain: App.Api,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @prefix "hrda_"

  postgres do
    table "api_clients"
    repo App.Repo

    references do
      reference :user, on_delete: :delete
      reference :provider, on_delete: :delete
    end
  end

  policies do
    policy action(:create_service) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end

    policy action(:create_external) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end

    policy action(:create_personal) do
      authorize_if App.Api.Checks.LinkedToPerson
    end

    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
      authorize_if expr(kind == :personal and user_id == ^actor(:id))
    end

    policy action(:revoke) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
      authorize_if expr(kind == :personal and user_id == ^actor(:id))
    end

    policy action(:touch) do
      forbid_if always()
    end
  end

  @doc "The stored form of a token."
  @spec digest(String.t()) :: String.t()
  def digest(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:service, :personal, :external]
    end

    attribute :profiles, {:array, :atom} do
      allow_nil? false
      public? true
      default []
    end

    # Static token (service, personal); none for an external system.
    attribute :token_digest, :string
    attribute :token_hint, :string, public?: true

    # External systems: public keys (a JWK Set) and the resource types
    # they may read ("*" = all served to external systems).
    attribute :jwks, :map, public?: true
    attribute :scopes, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :last_used_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    # The owner of a personal token; who created a service client.
    belongs_to :user, App.Accounts.User do
      allow_nil? false
      public? true
    end

    # External systems: the care provider they belong to.
    belongs_to :provider, App.Care.Provider, public?: true
  end

  actions do
    defaults [:read]

    create :create_service do
      accept [:name, :profiles, :expires_at]
      change relate_actor(:user)
      change set_attribute(:kind, :service)
      validate App.Api.Validations.GlobalProfiles
      change App.Api.Changes.IssueToken
    end

    create :create_external do
      accept [:name, :provider_id, :jwks, :scopes, :expires_at]
      change relate_actor(:user)
      change set_attribute(:kind, :external)
      validate App.Api.Validations.ExternalClient
    end

    create :create_personal do
      accept [:name, :expires_at]
      change relate_actor(:user)
      change set_attribute(:kind, :personal)
      change App.Api.Changes.IssueToken
    end

    update :revoke do
      accept []
      change set_attribute(:active, false)
    end

    update :touch do
      accept []
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  identities do
    identity :unique_token, [:token_digest]
  end

  @doc false
  def prefix, do: @prefix
end
