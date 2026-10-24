defmodule App.Events.Event do
  @moduledoc """
  One event of the general event log (docs/design/events-and-person-login.md
  its type (`hrda.<domain>.<subject>.<action>`, declared in
  `priv/events.json`), severity, source, subject, actor and data — ids,
  codes and outcomes, never personal details. The CloudEvents packet is
  built from it by `App.Events.Envelope`.

  Append-only: written only by `App.EventLog.emit/3` (no policy allows
  creating), never changed except being marked published, never deleted
  by the app. Reading needs `audit.read`.
  """
  use Ash.Resource,
    domain: App.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "events"
    repo App.Repo

    custom_indexes do
      index [:occurred_at]
      index [:type]
      # The publisher's queue: marked for publishing, not published yet.
      index [:occurred_at], where: "publish AND published_at IS NULL", name: "events_unpublished"
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :type, :string do
      allow_nil? false
      public? true
    end

    attribute :severity, :string do
      allow_nil? false
      public? true
    end

    # CloudEvents source: /hrda/<instance>/<domain>.
    attribute :source, :string do
      allow_nil? false
      public? true
    end

    # <kind>/<id> when the event is about one thing, e.g. user/<uuid>.
    attribute :subject, :string do
      allow_nil? true
      public? true
    end

    attribute :actor_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :correlation_id, :string do
      allow_nil? true
      public? true
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
    end

    # Sent to external subscribers (declared so and publishing on).
    attribute :publish, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :occurred_at
  end

  actions do
    defaults [:read]

    create :record do
      accept [:type, :severity, :source, :subject, :actor_id, :correlation_id, :data, :publish]
    end

    update :published do
      accept []
      change set_attribute(:published_at, &DateTime.utc_now/0)
    end
  end
end
