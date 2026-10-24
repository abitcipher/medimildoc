defmodule App.Notify do
  @moduledoc """
  Notifications (docs/design/search-timeline-notifications.md): users
  subscribe to events per channel; an event writes one `Notification`
  per subscribed channel — the outbox, in the same transaction as what
  caused it. In-app notifications are simply there; the others are
  published to RabbitMQ (`App.Notify.Outbox`) and delivered through Apprise
  API (`App.Notify.Dispatcher`).

  Messages carry what happened and a link — never a person's name,
  personal or medical details. Events are written with
  `App.Notify.Emitter.emit/3`, kept out of this module: the resources
  name their domain, so helpers here would make an import cycle.
  """
  use Ash.Domain

  resources do
    resource App.Notify.Channel
    resource App.Notify.Subscription
    resource App.Notify.Notification
  end
end
