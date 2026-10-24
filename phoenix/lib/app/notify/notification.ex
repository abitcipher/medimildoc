defmodule App.Notify.Notification do
  @moduledoc """
  One message to one user on one channel — the outbox
  (docs/design/search-timeline-notifications.md). Written with what caused
  it; in-app messages are delivered by being here. The others go
  `:pending` → `:queued` (published to RabbitMQ) → `:sent`, or `:failed`
  with the next attempt scheduled; after the last attempt they stay
  `:failed`. Users read and mark read only their own.
  """
  use Ash.Resource,
    domain: App.Notify,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "notifications"
    repo App.Repo

    references do
      reference :user, on_delete: :delete
    end

    custom_indexes do
      index [:status, :next_attempt_at]
      index [:user_id, :inserted_at]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action(:mark_read) do
      authorize_if relates_to_actor_via(:user)
    end

    # Written and delivered by the system only (authorize?: false).
    policy action([:create, :queued, :delivered, :failed]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :event, :atom, allow_nil?: false, public?: true
    attribute :channel, :atom, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    # A path inside the app ("/documents/…"); the link is built with the host.
    attribute :path, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :queued, :sent, :failed]
      default :pending
    end

    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
    attribute :next_attempt_at, :utc_datetime_usec, public?: true
    attribute :last_error, :string, public?: true
    attribute :sent_at, :utc_datetime_usec, public?: true
    attribute :read_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, App.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:user_id, :event, :channel, :title, :body, :path]

      # In the app it is delivered by being written.
      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :channel) == :in_app do
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :sent)
          |> Ash.Changeset.force_change_attribute(:sent_at, DateTime.utc_now())
        else
          Ash.Changeset.force_change_attribute(changeset, :next_attempt_at, DateTime.utc_now())
        end
      end
    end

    update :mark_read do
      accept []
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    update :queued do
      accept []
      change set_attribute(:status, :queued)
    end

    update :forget_link do
      accept []
      change set_attribute(:path, nil)
    end

    update :delivered do
      accept []
      change set_attribute(:status, :sent)
      change set_attribute(:sent_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, nil)
    end

    update :failed do
      require_atomic? false
      argument :error, :string, allow_nil?: false
      argument :retry_at, :utc_datetime_usec
      change set_attribute(:status, :failed)
      change set_attribute(:last_error, arg(:error))
      change set_attribute(:next_attempt_at, arg(:retry_at))
      change atomic_update(:attempts, expr(attempts + 1))
    end
  end
end
