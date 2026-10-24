defmodule App.Notify.Subscription do
  @moduledoc """
  A user wants messages about one event on one channel
  (docs/design/search-timeline-notifications.md). Each user manages only
  their own.
  """
  use Ash.Resource,
    domain: App.Notify,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Notify.Events

  postgres do
    table "notify_subscriptions"
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

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:user)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :event, :atom do
      allow_nil? false
      public? true
      constraints one_of: Events.subscribable()
    end

    attribute :channel, :atom do
      allow_nil? false
      public? true
      constraints one_of: Events.channels()
    end

    create_timestamp :inserted_at
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
      accept [:user_id, :event, :channel]
      upsert? true
      upsert_identity :unique
    end
  end

  identities do
    identity :unique, [:user_id, :event, :channel]
  end
end
