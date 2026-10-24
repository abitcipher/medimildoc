defmodule App.Events.Publisher do
  @moduledoc """
  Publishes events to external subscribers (docs/design/events-and-person-login.md
  every few seconds the events marked for publishing and not yet
  published go to the topic exchange `hrda.events` — routing key = the
  event type, body = its CloudEvents packet (`App.Events.Envelope`),
  content type `application/cloudevents+json`, persistent, message id =
  event id — and are marked published. A subscriber binds its own queue,
  e.g. to `hrda.auth.#`. While RabbitMQ is unreachable the events wait;
  nothing is lost. Runs only with `RABBITMQ_URL`, like the notifications
  outbox.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias App.Events.{Envelope, Event}

  @exchange "hrda.events"
  @tick_ms 5_000
  @batch 200

  @doc "The exchange events are published to."
  @spec exchange() :: String.t()
  def exchange, do: @exchange

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :tick)
    {:ok, %{url: Keyword.fetch!(opts, :url), channel: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      case connect(state) do
        {:ok, state} ->
          publish_due(&amqp_publish(state.channel, &1, &2, &3))
          state

        {:error, reason} ->
          Logger.warning("event publisher: RabbitMQ unavailable (#{inspect(reason)})")
          %{state | channel: nil}
      end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | channel: nil}}

  @doc """
  Publishes the waiting events, oldest first, through `publish`
  (`fn routing_key, body, message_id -> :ok end`), marking each published
  after it went out. Stops at the first failure (the rest wait for the
  next tick). Returns how many went out.
  """
  @spec publish_due((String.t(), String.t(), String.t() -> :ok | term())) :: non_neg_integer()
  def publish_due(publish) do
    Event
    |> Ash.Query.filter(publish == true and is_nil(published_at))
    |> Ash.Query.sort(occurred_at: :asc, id: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce_while(0, fn event, sent ->
      case publish.(event.type, event |> Envelope.build() |> Jason.encode!(), event.id) do
        :ok ->
          event |> Ash.Changeset.for_update(:published, %{}) |> Ash.update!(authorize?: false)
          {:cont, sent + 1}

        error ->
          Logger.warning("event publisher: #{inspect(error)}")
          {:halt, sent}
      end
    end)
  end

  defp connect(%{channel: %AMQP.Channel{}} = state), do: {:ok, state}

  defp connect(state) do
    with {:ok, conn} <- AMQP.Connection.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(channel, @exchange, :topic, durable: true) do
      Process.monitor(conn.pid)
      {:ok, %{state | channel: channel}}
    end
  end

  defp amqp_publish(channel, routing_key, body, id) do
    AMQP.Basic.publish(channel, @exchange, routing_key, body,
      persistent: true,
      content_type: "application/cloudevents+json",
      message_id: id,
      type: routing_key
    )
  end
end
