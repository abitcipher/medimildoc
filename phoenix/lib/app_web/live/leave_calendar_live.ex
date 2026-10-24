defmodule AppWeb.LeaveCalendarLive do
  @moduledoc """
  The leave calendar (docs/design/leave-calendar.md): for a unit (with its
  sub-units) and a month, who is away which day — recorded leave as solid
  bars by type, leave on its way (a request in approval, an unsigned leave
  order) dashed — and the days in conflict: more away than the limit
  (`leave.max_away_percent` of the unit, at least one), or two or more
  holders of key posts (posts others report to) away.

  Wide screens: a grid, people by days, scrolling sideways inside its own
  frame. Phones: the conflicts and, per person, their absences this month.
  Everything is read as the viewer (`App.Leave.CalendarData`). Unit and
  month are in the URL (`?unit=…&month=2026-10`).
  """
  use AppWeb, :live_view

  alias App.Leave.{Calendar, CalendarData}

  import AppWeb.CalendarUI, only: [weekend?: 1, weekday: 1, month_label: 1]

  alias App.People.{Organization, Person, PersonRecordSchema}
  alias AppWeb.CalendarUI

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    units =
      Organization
      |> Ash.read!(actor: actor)
      |> Enum.sort_by(& &1.name)

    {:ok,
     assign(socket,
       page_title: gettext("Leave calendar"),
       units: units,
       default_unit: default_unit(actor, units),
       percent: App.Settings.get("leave.max_away_percent"),
       # Leave types, then business trips (docs/design/business-trips.md).
       type_labels:
         PersonRecordSchema.schema(:leave)["properties"]["leaveType"]["x-enum-labels"]
         |> Enum.to_list()
         |> Kernel.++([{"trip", PersonRecordSchema.schema(:business_trip)["x-label"]}])
     )}
  end

  # The viewer's own unit when they have one, else the first top unit.
  defp default_unit(actor, units) do
    case actor.person_id && CalendarData.unit_of(actor.person_id) do
      id when is_binary(id) -> id
      _ -> Enum.find_value(units, &(is_nil(&1.parent_id) && &1.id))
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    unit = params["unit"] || socket.assigns.default_unit
    month = parse_month(params["month"])
    {:noreply, socket |> assign(unit: unit, month: month) |> load()}
  end

  defp parse_month(value) do
    with value when is_binary(value) <- value,
         {:ok, date} <- Date.from_iso8601(value <> "-01") do
      date
    else
      _ -> Date.beginning_of_month(Date.utc_today())
    end
  end

  defp load(%{assigns: %{unit: nil}} = socket),
    do:
      socket
      |> assign(members: [], absences: [], dates: [], days: [], conflicts: [], shown: 0)
      |> stream(:rows, [], reset: true)

  defp load(socket) do
    %{unit: unit, month: month, percent: percent, current_user: actor} = socket.assigns
    dates = Calendar.month_days(month)

    %{members: members, absences: absences} =
      CalendarData.load(unit, List.first(dates), List.last(dates), actor)

    days = Calendar.days(members, absences, dates, percent)

    socket
    |> assign(
      members: members,
      absences: absences,
      dates: dates,
      days: days,
      conflicts: Calendar.conflicts(days)
    )
    |> CalendarUI.first_rows(members)
  end

  @impl true
  # More people as the grid is scrolled to its end (AppWeb.CalendarUI).
  def handle_event("more_rows", _params, socket),
    do: {:noreply, CalendarUI.more_rows(socket, socket.assigns.members)}

  def handle_event("unit", %{"unit" => unit}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(unit, socket.assigns.month))}

  defp calendar_path(unit, month),
    do: ~p"/leave-calendar?#{[unit: unit, month: month_param(month)]}"

  defp month_param(date), do: Elixir.Calendar.strftime(date, "%Y-%m")

  defp shift(month, n), do: month |> Date.beginning_of_month() |> Date.shift(month: n)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-6xl flex-col gap-4 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Leave calendar")}
            <.field_description description={
              gettext(
                "Who of the unit is away which day: recorded leave and sick leave as solid bars, leave still on its way dashed. A day is in conflict when more people are away than the limit set in Settings, or when two or more holders of key posts (posts others report to) are away."
              )
            } />
          </h1>
          <div class="flex flex-wrap items-center gap-2">
            <form id="calendar-unit" phx-change="unit">
              <label for="calendar-unit-select" class="sr-only">{gettext("Unit")}</label>
              <select id="calendar-unit-select" name="unit" class="select select-sm max-w-64">
                <option :for={unit <- @units} value={unit.id} selected={unit.id == @unit}>
                  {unit.name}
                </option>
              </select>
            </form>
            <div class="join">
              <.link
                patch={calendar_path(@unit, shift(@month, -1))}
                class="btn btn-sm join-item"
                aria-label={gettext("Previous month")}
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </.link>
              <.link
                patch={calendar_path(@unit, Date.utc_today())}
                class="btn btn-sm join-item tabular-nums"
              >
                {month_label(@month)}
              </.link>
              <.link
                patch={calendar_path(@unit, shift(@month, 1))}
                class="btn btn-sm join-item"
                aria-label={gettext("Next month")}
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </.link>
            </div>
          </div>
        </div>

        <section id="calendar-conflicts" class="flex flex-col gap-2">
          <h2 class="flex items-center gap-2 font-semibold">
            {gettext("Conflicts")}
            <span class={[
              "badge badge-sm",
              @conflicts != [] && "badge-error",
              @conflicts == [] && "badge-ghost"
            ]}>
              {length(@conflicts)}
            </span>
          </h2>
          <p :if={@conflicts == []} class="text-sm opacity-70">
            {gettext("No day this month has too many people away.")}
          </p>
          <ul :if={@conflicts != []} class="flex flex-col gap-1 text-sm">
            <li :for={conflict <- @conflicts} class="flex flex-wrap items-center gap-x-2">
              <.icon
                name={if conflict.over?, do: "hero-exclamation-triangle", else: "hero-user-group"}
                class={["size-4", conflict.over? && "text-error", !conflict.over? && "text-warning"]}
              />
              <span class="font-medium tabular-nums">{range_label(conflict)}</span>
              <span :if={conflict.over?}>
                {gettext("up to %{count} away, limit %{limit}",
                  count: conflict.max_away,
                  limit: conflict.limit
                )}
              </span>
              <span :if={conflict.leaders?}>{gettext("several leaders away")}</span>
            </li>
          </ul>
        </section>

        <section id="calendar-grid" class="hidden flex-col gap-3 md:flex">
          <p :if={@members == []} class="text-sm opacity-70">
            {gettext("Nobody is assigned in this unit.")}
          </p>
          <%!-- Its own scroll box: rows load as it is scrolled to the end
               (phx-viewport-bottom watches the nearest scrolling element);
               the days stay on top. --%>
          <div :if={@members != []} class="max-h-[70vh] overflow-auto">
            <table class="border-separate border-spacing-0 text-xs">
              <thead class="sticky top-0 z-20 bg-base-100">
                <tr>
                  <th class="sticky left-0 z-10 min-w-44 bg-base-100 px-2 text-left font-semibold">
                    {gettext("Person")}
                  </th>
                  <th
                    :for={day <- @days}
                    class={[
                      "w-6 min-w-6 px-0 pb-1 text-center font-normal tabular-nums",
                      weekend?(day.date) && "bg-base-200"
                    ]}
                    data-float-tip={day_tip(day)}
                  >
                    <div class={[
                      "mx-0.5 mb-1 h-1 rounded-full",
                      day.over? && "bg-error",
                      (!day.over? and day.leaders?) && "bg-warning"
                    ]}>
                    </div>
                    <div class="opacity-60">{weekday(day.date)}</div>
                    <div class={day.date == Date.utc_today() && "font-bold text-primary"}>
                      {day.date.day}
                    </div>
                  </th>
                </tr>
              </thead>
              <tbody
                id="calendar-rows"
                phx-update="stream"
                phx-viewport-bottom={@shown < length(@members) && "more_rows"}
              >
                <tr
                  :for={{dom_id, %{member: member}} <- @streams.rows}
                  id={dom_id}
                  class="hover:bg-base-200/50"
                >
                  <th class="sticky left-0 z-10 max-w-56 truncate bg-base-100 px-2 py-1 text-left font-normal">
                    <.link navigate={~p"/people/#{member.person_id}"} class="link link-hover">
                      {Person.full_name(member.person)}
                    </.link>
                    <span :if={member.leader?} data-float-tip={gettext("Key post")}>
                      <.icon name="hero-star-mini" class="size-3 text-warning" />
                      <span class="sr-only">{gettext("Key post")}</span>
                    </span>
                  </th>
                  <td
                    :for={date <- @dates}
                    class={["h-6 p-0", weekend?(date) && "bg-base-200/60"]}
                  >
                    <div
                      :for={absence <- Calendar.on(date, @absences, member.person_id) |> Enum.take(1)}
                      class={[
                        "mx-px h-4 rounded-sm",
                        type_class(absence.type),
                        absence.pending? && "border border-dashed border-base-content/60 opacity-50"
                      ]}
                      data-float-tip={absence_tip(absence, @type_labels)}
                    >
                    </div>
                  </td>
                </tr>
              </tbody>
              <tfoot class="sticky bottom-0 z-20 bg-base-100">
                <tr>
                  <th class="sticky left-0 z-10 bg-base-100 px-2 pt-2 text-left text-xs font-semibold opacity-70">
                    {gettext("Away")}
                  </th>
                  <td
                    :for={day <- @days}
                    class={[
                      "pt-2 text-center tabular-nums",
                      day.over? && "font-bold text-error",
                      day.away == 0 && "opacity-30"
                    ]}
                  >
                    {day.away}
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
          <div :if={@members != []} class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
            <span :for={{type, label} <- @type_labels} class="flex items-center gap-1">
              <span class={["inline-block size-3 rounded-sm", type_class(type)]}></span>
              {AppWeb.SchemaText.translate(label)}
            </span>
            <span class="flex items-center gap-1">
              <span class="inline-block size-3 rounded-sm border border-dashed border-base-content/60 bg-base-300"></span>
              {gettext("on its way")}
            </span>
            <span class="flex items-center gap-1">
              <span class="inline-block h-1 w-3 rounded-full bg-error"></span>
              {gettext("too many away")}
            </span>
            <span class="flex items-center gap-1">
              <span class="inline-block h-1 w-3 rounded-full bg-warning"></span>
              {gettext("several leaders away")}
            </span>
            <span class="flex items-center gap-1">
              <.icon name="hero-star-mini" class="size-3 text-warning" /> {gettext("key post")}
            </span>
          </div>
        </section>

        <section id="calendar-list" class="flex flex-col gap-2 md:hidden">
          <h2 class="font-semibold">{gettext("Away this month")}</h2>
          <p :if={away_members(@members, @absences) == []} class="text-sm opacity-70">
            {gettext("Nobody is away this month.")}
          </p>
          <ul class="flex flex-col gap-2">
            <li
              :for={member <- away_members(@members, @absences)}
              class="rounded-box border border-base-300 p-3 text-sm"
            >
              <.link navigate={~p"/people/#{member.person_id}"} class="link link-hover font-medium">
                {Person.full_name(member.person)}
              </.link>
              <ul class="mt-1 flex flex-col gap-1">
                <li
                  :for={absence <- Enum.filter(@absences, &(&1.person_id == member.person_id))}
                  class="flex flex-wrap items-center gap-x-2"
                >
                  <span class={[
                    "inline-block size-3 shrink-0 rounded-sm",
                    type_class(absence.type),
                    absence.pending? && "border border-dashed border-base-content/60 opacity-50"
                  ]}></span>
                  <span class="tabular-nums">{range_label(%{from: absence.first, to: absence.last})}</span>
                  <span class="opacity-70">{type_label(absence.type, @type_labels)}</span>
                  <span :if={absence.pending?} class="opacity-70">· {gettext("on its way")}</span>
                </li>
              </ul>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp away_members(members, absences) do
    away = MapSet.new(absences, & &1.person_id)
    Enum.filter(members, &MapSet.member?(away, &1.person_id))
  end

  defp range_label(%{from: from, to: to}) when from == to, do: AppWeb.DateFormat.display(from)

  defp range_label(%{from: from, to: to}),
    do: "#{AppWeb.DateFormat.display(from)} – #{AppWeb.DateFormat.display(to)}"

  defp day_tip(day) do
    away = gettext("%{count} away (limit %{limit})", count: day.away, limit: day.limit)
    pending = if day.pending > 0, do: " · " <> gettext("%{count} on its way", count: day.pending)

    leaders =
      if day.leaders_away > 0,
        do: " · " <> gettext("leaders away: %{count}", count: day.leaders_away)

    "#{AppWeb.DateFormat.display(day.date)}: #{away}#{pending}#{leaders}"
  end

  defp absence_tip(absence, labels) do
    base =
      "#{type_label(absence.type, labels)}: #{range_label(%{from: absence.first, to: absence.last})}"

    if absence.pending?, do: base <> " · " <> gettext("on its way"), else: base
  end

  defp type_label(type, labels), do: AppWeb.SchemaText.choice(type || "", Map.new(labels))

  # A fixed palette, apart from the theme colours that mark conflicts
  # (error: too many away, warning: several leaders away).
  defp type_class("annual"), do: "bg-sky-500"
  defp type_class("family"), do: "bg-violet-500"
  defp type_class("study"), do: "bg-teal-500"
  defp type_class("sick"), do: "bg-fuchsia-500"
  defp type_class("unpaid"), do: "bg-slate-400"
  defp type_class("trip"), do: "bg-indigo-400"
  defp type_class(_other), do: "bg-lime-500"
end
