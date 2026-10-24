defmodule AppWeb.EventsLive.Index do
  @moduledoc """
  The general event log (docs/design/events-and-person-login.md):
  access events (sign-ins, accounts) on their own tab, all events on
  another, each one's CloudEvents packet on demand; the switches for the
  log and for publishing (`settings.manage`). Reading needs `audit.read`
  (the event resource's policy; the route gate is UX only). Newest first.
  """
  use AppWeb, :live_view

  require Ash.Query

  alias App.EventLog
  alias App.Events.{Catalog, Envelope, Event}

  @access_domains ~w(auth accounts)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Event log"))
     |> assign(:manage?, AppWeb.Authz.can?(socket.assigns.current_user, "settings.manage"))
     |> assign(:queue?, is_binary(Application.get_env(:app, App.Notify, [])[:rabbitmq_url]))
     |> assign(:packet, nil)
     |> load_switches()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "all", do: "all", else: "access"
    severity = if params["severity"] in Catalog.severities(), do: params["severity"]

    {:noreply,
     assign(socket, tab: tab, severity: severity, query: query(tab, severity), packet: nil)}
  end

  defp query(tab, severity) do
    types =
      if tab == "access",
        do: Enum.filter(Catalog.types(), &(Catalog.domain(&1) in @access_domains)),
        else: Catalog.types()

    Event
    |> Ash.Query.filter(type in ^types)
    |> then(&if(severity, do: Ash.Query.filter(&1, severity == ^severity), else: &1))
    |> Ash.Query.sort(occurred_at: :desc)
  end

  defp load_switches(socket),
    do: assign(socket, logging?: EventLog.logging?(), publishing?: EventLog.publishing?())

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/events?#{Enum.reject([tab: socket.assigns.tab, severity: params["severity"]], fn {_, v} -> v in [nil, ""] end)}"
     )}
  end

  def handle_event("show", %{"id" => id}, socket) do
    case Ash.get(Event, id, actor: socket.assigns.current_user) do
      {:ok, event} -> {:noreply, assign(socket, :packet, Envelope.build(event))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :packet, nil)}

  def handle_event("switch", %{"what" => what, "on" => on}, socket) do
    actor = socket.assigns.current_user
    on? = on == "true"

    result =
      case what do
        "logging" -> EventLog.set_logging(on?, actor)
        "publishing" -> EventLog.set_publishing(on?, actor)
      end

    case result do
      :ok -> {:noreply, socket |> load_switches() |> put_flash(:info, gettext("Saved."))}
      _ -> {:noreply, put_flash(socket, :error, gettext("Not allowed."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("Event log")}
          <.field_description description={
            gettext(
              "Events of the system: sign-ins and accounts on the Access tab, everything on All events. Each event is a CloudEvents packet named hrda.<domain>.<subject>.<action>; key and critical ones can be published to external subscribers through RabbitMQ. The data-access log of sensitive records is kept separately and is always on."
            )
          } />
        </h1>

        <section id="event-switches" class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
            <.switch
              id="switch-logging"
              what="logging"
              on={@logging?}
              disabled={not @manage?}
              label={gettext("Event log")}
              help={
                gettext(
                  "Off: nothing is written except switching the log or publishing on or off, which is always written with who did it."
                )
              }
            />
            <.switch
              id="switch-publishing"
              what="publishing"
              on={@publishing?}
              disabled={not @manage? or not @logging?}
              label={gettext("Publish to subscribers")}
              help={
                gettext(
                  "Key and critical events go to the RabbitMQ exchange hrda.events, routing key = event type. Needs the event log on."
                )
              }
            />
            <span :if={@publishing? and not @queue?} class="badge badge-warning badge-sm">
              {gettext("No message queue configured on this server")}
            </span>
          </div>
        </section>

        <div class="flex flex-wrap items-center justify-between gap-2">
          <div role="tablist" class="tabs tabs-border">
            <.link
              role="tab"
              patch={~p"/events?#{tab_query("access", @severity)}"}
              class={["tab", @tab == "access" && "tab-active"]}
              id="tab-access"
            >
              {gettext("Access")}
            </.link>
            <.link
              role="tab"
              patch={~p"/events?#{tab_query("all", @severity)}"}
              class={["tab", @tab == "all" && "tab-active"]}
              id="tab-all"
            >
              {gettext("All events")}
            </.link>
          </div>
          <form id="event-filter" phx-change="filter">
            <label for="event-severity" class="sr-only">{gettext("Severity")}</label>
            <select id="event-severity" name="severity" class="select select-sm w-40">
              <option value="" selected={is_nil(@severity)}>{gettext("Any severity")}</option>
              <option :for={s <- severities()} value={s} selected={s == @severity}>
                {severity_label(s)}
              </option>
            </select>
          </form>
        </div>

        <.top_pager id="events-table">
          <Cinder.collection
            id="events-table"
            query={@query}
            actor={@current_user}
            click={fn event -> JS.push("show", value: %{id: event.id}) end}
          >
            <:col :let={event} label={gettext("When")}>
              <span class="whitespace-nowrap font-mono text-xs">
                {Calendar.strftime(event.occurred_at, "%Y-%m-%d %H:%M:%S")}
              </span>
            </:col>
            <:col :let={event} label={gettext("Event")}>
              <span class="font-mono text-xs">{event.type}</span>
            </:col>
            <:col :let={event} label={gettext("Severity")}>
              <span class={["badge badge-sm", severity_class(event.severity)]}>
                {severity_label(event.severity)}
              </span>
            </:col>
            <:col :let={event} label={gettext("Details")}>
              <span class="font-mono text-xs opacity-80">{summary(event.data)}</span>
            </:col>
            <:col :let={event} label="">
              <.icon
                :if={event.publish}
                name={if event.published_at, do: "hero-paper-airplane", else: "hero-clock"}
                class="size-4 opacity-60"
              />
            </:col>
          </Cinder.collection>
        </.top_pager>

        <div
          :if={@packet}
          id="event-packet"
          class="modal modal-open"
          phx-window-keydown="close"
          phx-key="escape"
        >
          <div class="modal-box max-w-2xl">
            <div class="mb-2 flex items-center justify-between gap-2">
              <h2 class="font-mono text-sm font-semibold">{@packet["type"]}</h2>
              <button
                type="button"
                phx-click="close"
                class="btn btn-ghost btn-sm btn-square"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
            <pre class="max-h-[60vh] overflow-auto rounded-box bg-base-200 p-3 text-xs">{Jason.encode!(@packet, pretty: true)}</pre>
          </div>
          <div class="modal-backdrop" phx-click="close"></div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :what, :string, required: true
  attr :on, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :label, :string, required: true
  attr :help, :string, required: true

  defp switch(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center gap-2 text-sm">
      <input
        type="checkbox"
        id={@id}
        class="toggle toggle-sm toggle-primary"
        checked={@on}
        disabled={@disabled}
        phx-click="switch"
        phx-value-what={@what}
        phx-value-on={to_string(not @on)}
      />
      <span class="font-medium">{@label}</span>
      <.field_description description={@help} />
    </label>
    """
  end

  defp tab_query(tab, severity),
    do: Enum.reject([tab: tab, severity: severity], fn {_, v} -> is_nil(v) end)

  defp severities, do: Enum.reverse(Catalog.severities())

  defp severity_label("info"), do: gettext("Info")
  defp severity_label("notice"), do: gettext("Notice")
  defp severity_label("warning"), do: gettext("Warning")
  defp severity_label("critical"), do: gettext("Critical")

  defp severity_class("critical"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class("notice"), do: "badge-info badge-outline"
  defp severity_class(_info), do: "badge-ghost"

  defp summary(data) when map_size(data) == 0, do: "—"

  defp summary(data),
    do: data |> Enum.sort() |> Enum.map_join(" · ", fn {k, v} -> "#{k}=#{format(v)}" end)

  defp format(value) when is_list(value), do: Enum.join(value, ",")

  # A digest in full is in the packet; the row shows its start.
  defp format(value) when is_binary(value) and byte_size(value) > 24,
    do: String.slice(value, 0, 12) <> "…"

  defp format(value), do: to_string(value)
end
