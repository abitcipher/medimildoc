defmodule App.Api.AccessToken do
  @moduledoc """
  A short-lived access token issued to an external system by the SMART
  token endpoint (`App.Api.Smart`): its SHA-256, the resource types granted
  and when it ends. Written and read by the system only.
  """
  use Ash.Resource,
    domain: App.Api,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "api_access_tokens"
    repo App.Repo

    references do
      reference :client, on_delete: :delete
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :token_digest, :string, allow_nil?: false
    attribute :scopes, {:array, :string}, allow_nil?: false, default: []
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :client, App.Api.Client, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:client_id, :token_digest, :scopes, :expires_at]]
  end

  identities do
    identity :unique_token, [:token_digest]
  end
end
