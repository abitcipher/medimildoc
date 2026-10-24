defmodule App.Notify.Outbox do
  @moduledoc """
  Publishes due outbox notifications to RabbitMQ
  (docs/design/search-timeline-notifications.md): every few seconds it
  takes notifications waiting for delivery — new ones, failed ones whose
  next attempt is due, and queued ones that were never delivered (a lost
  message) — publishes their ids to the `hrda.notify` topic exchange with
  the channel as routing key, and marks them queued. Channels with no
  sender configured are left waiting. While RabbitMQ is unreachable
  nothing is lost: the rows stay due and the next tick reconnects.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias App.Notify.{Apprise, Delivery, Notification}

  @exchange "hrda.notify"
  @tick_ms 5_000
  @batch 100
  @lost_after_seconds 600

  @doc "The exchange notifications are published to."
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
          publish_due(state.channel)
          state

        {:error, reason} ->
          Logger.warning("notify outbox: RabbitMQ unavailable (#{inspect(reason)})")
          %{state | channel: nil}
      end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | channel: nil}}

  defp connect(%{channel: %AMQP.Channel{}} = state), do: {:ok, state}

  defp connect(state) do
    with {:ok, conn} <- AMQP.Connection.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(channel, @exchange, :topic, durable: true) do
      Process.monitor(conn.pid)
      {:ok, %{state | channel: channel}}
    end
  end

  defp publish_due(channel) do
    now = DateTime.utc_now()
    lost = DateTime.add(now, -@lost_after_seconds, :second)
    max = Delivery.max_attempts()

    Notification
    |> Ash.Query.filter(
      channel != :in_app and
        (status == :pending or
           (status == :failed and not is_nil(next_attempt_at) and next_attempt_at <= ^now and
              attempts <= ^max) or
           (status == :queued and updated_at < ^lost))
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&Apprise.configured?(&1.channel))
    |> Enum.each(fn notification ->
      :ok =
        AMQP.Basic.publish(
          channel,
          @exchange,
          Atom.to_string(notification.channel),
          notification.id,
          persistent: true,
          content_type: "text/plain"
        )

      notification
      |> Ash.Changeset.for_update(:queued, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)
    end)
  end
end
