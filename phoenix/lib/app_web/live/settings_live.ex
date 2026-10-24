defmodule AppWeb.SettingsLive do
  @moduledoc """
  System settings (`App.Settings`; `settings.manage`). First setting: FSDC
  on or off (docs/design/data-consistency.md).
  """
  use AppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Settings"),
       fsdc: App.Settings.fsdc?(),
       max_away: App.Settings.get("leave.max_away_percent"),
       step_days: App.Settings.get("documents.step_days")
     )}
  end

  @impl true
  def handle_event("toggle_fsdc", _params, socket) do
    case App.Settings.put("fsdc.enabled", not socket.assigns.fsdc, socket.assigns.current_user) do
      :ok ->
        fsdc = App.Settings.fsdc?()

        {:noreply,
         socket
         |> assign(fsdc: fsdc)
         |> put_flash(
           :info,
           if(fsdc,
             do: gettext("Data consistency checks are on"),
             else: gettext("Data consistency checks are off")
           )
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  # docs/design/leave-calendar.md: the share of a unit that may be away.
  def handle_event("set_max_away", %{"max_away" => value}, socket) do
    case Integer.parse(value || "") do
      {percent, ""} when percent in 1..100 ->
        :ok = App.Settings.put("leave.max_away_percent", percent, socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(max_away: percent)
         |> put_flash(:info, gettext("Saved"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Enter a whole number from 1 to 100."))}
    end
  end

  # docs/design/inbox-first.md: days a step may wait before it is overdue.
  def handle_event("set_step_days", %{"step_days" => value}, socket) do
    case Integer.parse(value || "") do
      {days, ""} when days in 1..60 ->
        :ok = App.Settings.put("documents.step_days", days, socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(step_days: days)
         |> put_flash(:info, gettext("Saved"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Enter a whole number from 1 to 60."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-4 p-4">
        <h1 class="text-xl font-semibold">{gettext("Settings")}</h1>
        <section class="flex items-center justify-between gap-4 rounded-box border border-base-300 p-4">
          <div class="min-w-0">
            <p class="flex items-center gap-2 font-medium">
              {gettext("Data consistency checks (FSDC)")}
              <.field_description description={
                gettext(
                  "When on, the rules on the Rules page are checked whenever records are saved and documents are sent or signed; violations become incidents."
                )
              } />
            </p>
          </div>
          <input
            id="fsdc-toggle"
            type="checkbox"
            class="toggle toggle-primary"
            checked={@fsdc}
            phx-click="toggle_fsdc"
            aria-label={gettext("Data consistency checks (FSDC)")}
          />
        </section>
        <section class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <p class="flex items-center gap-2 font-medium">
              {gettext("Most of a unit away at once")}
              <.field_description description={
                gettext(
                  "On the leave calendar and on leave requests: more people away on a day than this share of the unit is a conflict. One person may always be away."
                )
              } />
            </p>
          </div>
          <form id="max-away-form" phx-change="set_max_away" class="flex items-center gap-2">
            <input
              id="max-away"
              type="number"
              name="max_away"
              min="1"
              max="100"
              value={@max_away}
              phx-debounce="600"
              class="input input-sm w-20"
              aria-label={gettext("Most of a unit away at once")}
            />
            <span>%</span>
          </form>
        </section>
        <section class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <p class="flex items-center gap-2 font-medium">
              {gettext("Days to approve or sign")}
              <.field_description description={
                gettext(
                  "A document waiting for someone to approve or sign it is overdue after this many days; it is then marked in their tasks and on the start page."
                )
              } />
            </p>
          </div>
          <form id="step-days-form" phx-change="set_step_days" class="flex items-center gap-2">
            <input
              id="step-days"
              type="number"
              name="step_days"
              min="1"
              max="60"
              value={@step_days}
              phx-debounce="600"
              class="input input-sm w-20"
              aria-label={gettext("Days to approve or sign")}
            />
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
