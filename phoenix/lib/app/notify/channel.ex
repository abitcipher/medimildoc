defmodule App.Notify.Channel do
  @moduledoc """
  Where a user receives messages of one kind (docs/design/search-timeline-notifications.md):
  an e-mail address, a Telegram chat id, a Signal number, a Matrix room.
  One per user and kind; the address is personal data and stored
  encrypted (decrypted by default: the owner sees it on their page, the
  dispatcher uses it). Each user manages only their own.
  """
  use Ash.Resource,
    domain: App.Notify,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "notify_channels"
    repo App.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type(:create) do
      authorize_if App.Notify.Checks.CreatesOwn
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end
  end

  cloak do
    vault App.Vault
    attributes [:address]
    decrypt_by_default [:address]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:email, :telegram, :signal, :matrix]
    end

    attribute :address, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, App.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:user_id, :kind, :address, :enabled]
      upsert? true
      upsert_identity :one_per_kind
      upsert_fields [:encrypted_address, :enabled, :updated_at]
    end

    update :update do
      primary? true
      accept [:address, :enabled]
    end
  end

  identities do
    identity :one_per_kind, [:user_id, :kind]
  end
end
