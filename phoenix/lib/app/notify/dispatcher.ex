defmodule App.Notify.Dispatcher do
  @moduledoc """
  Consumes the notification queue (docs/design/search-timeline-notifications.md):
  each message is the id of an outbox notification, delivered by
  `App.Notify.Delivery` (Apprise API). Messages are always acknowledged:
  the outcome and any retry are kept on the notification row, which is
  the record of truth, not in the queue.
  """
  use Broadway

  alias App.Notify.{Delivery, Outbox}

  @queue "hrda.notify.deliver"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module:
          {BroadwayRabbitMQ.Producer,
           queue: @queue,
           connection: Keyword.fetch!(opts, :url),
           declare: [durable: true],
           bindings: [{Outbox.exchange(), [routing_key: "#"]}],
           after_connect: &declare_exchange/1,
           on_success: :ack,
           on_failure: :ack,
           qos: [prefetch_count: 10],
           backoff_type: :exp,
           backoff_min: 1_000,
           backoff_max: 60_000},
        concurrency: 1
      ],
      processors: [default: [concurrency: 4]]
    )
  end

  defp declare_exchange(channel),
    do: AMQP.Exchange.declare(channel, Outbox.exchange(), :topic, durable: true)

  @impl true
  def handle_message(_processor, message, _context) do
    Delivery.deliver(message.data)
    message
  end
end
