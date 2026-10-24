defmodule AppWeb.NotificationsLive do
  @moduledoc """
  The user's notifications (docs/design/search-timeline-notifications.md):
  messages in the app, their channels (addresses per kind) and their
  subscriptions (event × channel). Everything here is the viewer's own.
  """
  use AppWeb, :live_view

  require Ash.Query

  alias App.Notify.{Apprise, Channel, Events, Notification, Subscription}

  @kinds [:email, :telegram, :signal, :matrix]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Notifications"), kinds: @kinds) |> load()}

  defp load(socket) do
    actor = socket.assigns.current_user

    messages =
      Notification
      |> Ash.Query.filter(channel == :in_app)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(50)
      |> Ash.read!(actor: actor)

    assign(socket,
      messages: messages,
      channels: Channel |> Ash.read!(actor: actor) |> Map.new(&{&1.kind, &1}),
      subscribed: Subscription |> Ash.read!(actor: actor) |> MapSet.new(&{&1.event, &1.channel}),
      events: Enum.filter(Events.subscribable(), &offered?(&1, actor))
    )
  end

  # Incidents only for those who may review them.
  defp offered?(:incident, actor), do: App.Access.can?(actor, "audit.read")
  # Only for an account that signs in with a PersonID.
  defp offered?(:set_password, actor), do: not is_nil(actor.login_id)
  defp offered?(_event, _actor), do: true

  @impl true
  def handle_event("toggle", %{"event" => event, "channel" => channel}, socket) do
    actor = socket.assigns.current_user
    event = String.to_existing_atom(event)
    channel = String.to_existing_atom(channel)

    if MapSet.member?(socket.assigns.subscribed, {event, channel}) do
      Subscription
      |> Ash.Query.filter(event == ^event and channel == ^channel)
      |> Ash.read!(actor: actor)
      |> Enum.each(&Ash.destroy!(&1, actor: actor))
    else
      Subscription
      |> Ash.Changeset.for_create(:create, %{user_id: actor.id, event: event, channel: channel},
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end

    {:noreply, load(socket)}
  end

  def handle_event("save_channel", %{"kind" => kind} = params, socket) do
    actor = socket.assigns.current_user
    kind = String.to_existing_atom(kind)
    address = String.trim(params["address"] || "")

    result =
      case {address, socket.assigns.channels[kind]} do
        {"", nil} ->
          :ok

        {"", channel} ->
          Ash.destroy(channel, actor: actor)

        {address, _} ->
          Channel
          |> Ash.Changeset.for_create(
            :create,
            %{
              user_id: actor.id,
              kind: kind,
              address: address,
              enabled: params["enabled"] == "true"
            },
            actor: actor
          )
          |> Ash.create(actor: actor)
      end

    case result do
      {:error, error} -> {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
      _ -> {:noreply, socket |> put_flash(:info, gettext("Saved")) |> load()}
    end
  end

  def handle_event("read_all", _params, socket) do
    actor = socket.assigns.current_user

    for message <- socket.assigns.messages, is_nil(message.read_at) do
      message
      |> Ash.Changeset.for_update(:mark_read, %{}, actor: actor)
      |> Ash.update!(actor: actor)
    end

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-6 p-4">
        <h1 class="text-xl font-semibold">{gettext("Notifications")}</h1>

        <section id="messages" class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-2">
            <h2 class="font-semibold">{gettext("Messages")}</h2>
            <button
              :if={Enum.any?(@messages, &is_nil(&1.read_at))}
              type="button"
              phx-click="read_all"
              class="btn btn-xs"
            >
              {gettext("Mark all read")}
            </button>
          </div>
          <p :if={@messages == []} class="text-sm opacity-60">{gettext("No messages.")}</p>
          <ul
            :if={@messages != []}
            class="divide-y divide-base-200 rounded-box border border-base-300"
          >
            <li
              :for={message <- @messages}
              class={["px-3 py-2", is_nil(message.read_at) && "bg-base-200"]}
            >
              <div class="flex min-w-0 items-baseline justify-between gap-2">
                <span class="truncate font-medium">{AppWeb.NotifyLabels.title(message.title)}</span>
                <span class="shrink-0 text-xs opacity-60">
                  {AppWeb.DateFormat.display(DateTime.to_date(message.inserted_at))}
                </span>
              </div>
              <p :if={message.body} class="truncate text-sm opacity-80">{message.body}</p>
              <.link :if={message.path} navigate={message.path} class="link link-hover text-xs">
                {gettext("Open")}
              </.link>
            </li>
          </ul>
        </section>

        <section id="channels" class="flex flex-col gap-2">
          <h2 class="flex items-center gap-2 font-semibold">
            {gettext("Channels")}
            <.field_description description={
              gettext(
                "Where messages outside the app go. Messages say what happened and link here — never a person's name or any personal or medical detail."
              )
            } />
          </h2>
          <form
            :for={kind <- @kinds}
            id={"channel-#{kind}"}
            phx-submit="save_channel"
            class="flex flex-wrap items-end gap-2 rounded-box border border-base-300 p-3"
          >
            <input type="hidden" name="kind" value={kind} />
            <label class="flex min-w-0 grow flex-col gap-1 text-sm">
              <span class="flex items-center gap-2">
                {channel_label(kind)}
                <.text_badge
                  :if={!Apprise.configured?(kind)}
                  text={gettext("not set up on the server")}
                  class="badge-xs badge-ghost"
                />
              </span>
              <input
                type="text"
                name="address"
                value={@channels[kind] && @channels[kind].address}
                placeholder={placeholder(kind, @current_user)}
                class="input input-sm w-full"
                autocomplete="off"
              />
            </label>
            <label class="flex items-center gap-1 text-sm">
              <input type="hidden" name="enabled" value="false" />
              <input
                type="checkbox"
                name="enabled"
                value="true"
                class="checkbox checkbox-sm"
                checked={is_nil(@channels[kind]) or @channels[kind].enabled}
              />
              {gettext("On")}
            </label>
            <button type="submit" class="btn btn-sm">{gettext("Save")}</button>
          </form>
        </section>

        <section id="subscriptions" class="flex flex-col gap-2">
          <h2 class="font-semibold">{gettext("Subscriptions")}</h2>
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Event")}</th>
                  <th :for={channel <- Events.channels()} class="text-center">
                    {channel_label(channel)}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @events}>
                  <td>{event_label(event)}</td>
                  <td :for={channel <- Events.channels()} class="text-center">
                    <span
                      :if={event == :set_password and channel == :in_app}
                      class="opacity-40"
                      data-float-tip={gettext("Never in the app: the link signs you in")}
                    >
                      —
                    </span>
                    <input
                      :if={not (event == :set_password and channel == :in_app)}
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      checked={MapSet.member?(@subscribed, {event, channel})}
                      phx-click="toggle"
                      phx-value-event={event}
                      phx-value-channel={channel}
                      aria-label={"#{event_label(event)} — #{channel_label(channel)}"}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp channel_label(:in_app), do: gettext("In the app")
  defp channel_label(:email), do: gettext("E-mail")
  defp channel_label(:telegram), do: "Telegram"
  defp channel_label(:signal), do: "Signal"
  defp channel_label(:matrix), do: "Matrix"

  defp event_label(:document_waiting), do: gettext("A document waits for my decision")

  defp event_label(:document_overdue),
    do: gettext("A document waiting for my decision is overdue")

  defp event_label(:document_returned), do: gettext("My document was returned")
  defp event_label(:document_signed), do: gettext("My document was signed")

  defp event_label(:document_to_acknowledge),
    do: gettext("An order about me awaits my acknowledgement")

  defp event_label(:instruction_given), do: gettext("I get a new instruction")
  defp event_label(:instruction_overdue), do: gettext("An instruction to me is overdue")
  defp event_label(:instruction_done), do: gettext("An instruction I gave is done")
  defp event_label(:incident), do: gettext("New data-consistency incident")

  defp event_label(:set_password),
    do: gettext("Link to set my PersonID password (e-mail if none chosen)")

  defp placeholder(:email, user), do: to_string(user.email)
  defp placeholder(:telegram, _user), do: gettext("Chat id, e.g. 123456789")
  defp placeholder(:signal, _user), do: "+380…"
  defp placeholder(:matrix, _user), do: "!room:matrix.org"
end
