defmodule App.Notify.Delivery do
  @moduledoc """
  Delivers one outbox notification (docs/design/search-timeline-notifications.md):
  finds the user's address for the channel (e-mail falls back to the
  sign-in address), sends it through Apprise and records the outcome. A
  failure is retried later — after 1, 5, 30 minutes, 2 and 12 hours —
  and then stays failed.
  """

  require Ash.Query

  alias App.Notify.{Apprise, Channel, Notification}

  @backoff_minutes [1, 5, 30, 120, 720]

  @doc "The number of attempts after which a notification stays failed."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: length(@backoff_minutes)

  @doc "Delivers the notification with this id (if it still waits); returns its outcome."
  @spec deliver(String.t()) :: :sent | :failed | :skipped
  def deliver(id) do
    case Ash.get(Notification, id, authorize?: false, load: [:user]) do
      {:ok, %{status: status} = notification} when status in [:pending, :queued, :failed] ->
        notification |> send() |> record(notification)

      _ ->
        :skipped
    end
  end

  defp send(notification) do
    with {:ok, address} <- address(notification),
         url when is_binary(url) <- Apprise.target(notification.channel, address) do
      Apprise.send(url, notification.title, body(notification))
    else
      nil -> {:error, "channel #{notification.channel} is not configured on the server"}
      error -> error
    end
  end

  defp address(%{channel: channel, user: user}) do
    Channel
    |> Ash.Query.filter(user_id == ^user.id and kind == ^channel and enabled == true)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{address: address}} -> {:ok, address}
      {:ok, nil} when channel == :email -> {:ok, to_string(user.email)}
      _ -> {:error, "no #{channel} address"}
    end
  end

  defp body(%{body: body, path: nil}), do: body || ""

  defp body(%{body: body, path: path}),
    do: Enum.join(Enum.reject([body, link(path)], &(&1 in [nil, ""])), "\n\n")

  defp link(path) do
    base = Application.get_env(:app, App.Notify, [])[:app_url] || ""
    base <> path
  end

  defp record(:ok, notification) do
    notification
    |> Ash.Changeset.for_update(:delivered, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
    |> forget_link()

    :sent
  end

  defp record({:error, error}, notification) do
    retry_at =
      case Enum.at(@backoff_minutes, notification.attempts) do
        nil -> nil
        minutes -> DateTime.add(DateTime.utc_now(), minutes * 60, :second)
      end

    notification
    |> Ash.Changeset.for_update(:failed, %{error: error, retry_at: retry_at}, authorize?: false)
    |> Ash.update!(authorize?: false)

    :failed
  end

  # A set-password link is not kept once it went out
  # (docs/design/events-and-person-login.md).
  defp forget_link(%{event: :set_password} = notification) do
    notification
    |> Ash.Changeset.for_update(:forget_link, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp forget_link(notification), do: notification
end
