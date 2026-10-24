defmodule App.Api.UsedJti do
  @moduledoc """
  The ids (`jti`) of client assertions already used at the token endpoint,
  kept until they expire, so a captured assertion can't be replayed
  (SMART backend services). System only.
  """
  use Ash.Resource,
    domain: App.Api,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "api_used_jtis"
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
    attribute :jti, :string, allow_nil?: false, constraints: [max_length: 255]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :client, App.Api.Client, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:client_id, :jti, :expires_at]]
  end

  identities do
    identity :once, [:client_id, :jti]
  end
end
