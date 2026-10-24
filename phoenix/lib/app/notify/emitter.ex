defmodule App.Notify.Emitter do
  @moduledoc """
  Writes notifications for an event (docs/design/search-timeline-notifications.md):
  one outbox row per subscribed channel, in the caller's transaction.
  """

  require Ash.Query

  alias App.Notify.{Events, Notification, Subscription}

  @doc """
  Writes the notifications of `event` for each of `user_ids` on the
  channels they subscribed to it (`:registration` goes to e-mail and the
  app without a subscription). `params` fill the message
  (`App.Notify.Events.message/2`); `path` is the link inside the app.
  """
  @spec emit(atom(), [String.t()], map()) :: :ok
  def emit(event, user_ids, params \\ %{}) do
    user_ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    {title, body} = Events.message(event, params)

    for {user_id, channel} <- channels(event, user_ids) do
      Notification
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: user_id,
          event: event,
          channel: channel,
          title: title,
          body: body,
          path: params[:path]
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  defp channels(:registration, user_ids),
    do: for(id <- user_ids, c <- [:in_app, :email], do: {id, c})

  # The set-password link: the user's chosen channels, e-mail by default,
  # never in the app.
  defp channels(:set_password, user_ids) do
    chosen =
      Subscription
      |> Ash.Query.filter(event == :set_password and user_id in ^user_ids and channel != :in_app)
      |> Ash.read!(authorize?: false)
      |> Enum.group_by(& &1.user_id, & &1.channel)

    for id <- user_ids, c <- Map.get(chosen, id, [:email]), do: {id, c}
  end

  defp channels(event, user_ids) do
    Subscription
    |> Ash.Query.filter(event == ^event and user_id in ^user_ids)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.user_id, &1.channel})
  end
end
