defmodule AppWeb.DutyRosterLive do
  @moduledoc """
  The duty roster (docs/design/duty-roster.md): for a unit (with its
  sub-units) and a month, who is on which duty which day, with what is
  wrong — a duty on a day of leave or a trip, two duties too close, a day
  with a duty type short of people. Commanders and HR plan by clicking a
  cell; others with access read. Unit and month are in the URL.
  """
  use AppWeb, :live_view

  import AppWeb.CalendarUI, only: [weekend?: 1, weekday: 1, month_label: 1]

  alias App.Duty.{Roster, RosterData, Shift, Types}
  alias App.Leave.{Calendar, CalendarData}
  alias App.People.{Organization, Person}
  alias AppWeb.{CalendarUI, FormSchemas, JsonSchemaForm}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    units = Organization |> Ash.read!(actor: actor) |> Enum.sort_by(& &1.name)

    {:ok,
     assign(socket,
       page_title: gettext("Duty roster"),
       units: units,
       default_unit: default_unit(actor, units),
       can_plan?: App.Access.can?(actor, "people.write") or App.Access.can?(actor, "orders.sign"),
       picking: nil,
       schema: shift_schema()
     )}
  end

  defp default_unit(actor, units) do
    case actor.person_id && CalendarData.unit_of(actor.person_id) do
      id when is_binary(id) -> id
      _ -> Enum.find_value(units, &(is_nil(&1.parent_id) && &1.id))
    end
  end

  # Duty types from priv/duty_types.json, so the form's schema doesn't repeat them.
  defp shift_schema do
    FormSchemas.schema(:duty_shift)
    |> put_in(["properties", "duty_type", "enum"], Types.ids())
    |> put_in(
      ["properties", "duty_type", "x-enum-labels"],
      Map.new(Types.all(), &{&1["id"], &1["label"]})
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    unit = params["unit"] || socket.assigns.default_unit
    month = parse_month(params["month"])
    {:noreply, socket |> assign(unit: unit, month: month, picking: nil) |> load()}
  end

  defp parse_month(value) do
    with value when is_binary(value) <- value,
         {:ok, date} <- Date.from_iso8601(value <> "-01") do
      date
    else
      _ -> Date.beginning_of_month(Date.utc_today())
    end
  end

  defp load(socket, opts \\ [])

  defp load(%{assigns: %{unit: nil}} = socket, _opts),
    do:
      socket
      |> assign(
        members: [],
        shifts: %{},
        dates: [],
        problems: %{},
        gaps: %{},
        absences: [],
        shown: 0
      )
      |> stream(:rows, [], reset: true)

  defp load(socket, opts) do
    %{unit: unit, month: month, current_user: actor} = socket.assigns
    dates = Calendar.month_days(month)

    %{members: members, absences: absences, shifts: shifts} =
      RosterData.load(unit, List.first(dates), List.last(dates), actor)

    socket
    |> assign(
      members: members,
      absences: absences,
      dates: dates,
      shifts: Map.new(shifts, &{{&1.person_id, &1.date}, &1}),
      problems: Roster.problems(shifts, absences),
      gaps: Roster.gaps(shifts, dates)
    )
    |> CalendarUI.first_rows(members, opts)
  end

  @impl true
  def handle_event("unit", %{"unit" => unit}, socket),
    do: {:noreply, push_patch(socket, to: roster_path(unit, socket.assigns.month))}

  def handle_event("pick", %{"person" => person_id, "date" => date}, socket) do
    with true <- socket.assigns.can_plan?,
         {:ok, date} <- Date.from_iso8601(date),
         %{} = member <- Enum.find(socket.assigns.members, &(&1.person_id == person_id)) do
      form =
        Shift
        |> AshPhoenix.Form.for_create(:create,
          actor: socket.assigns.current_user,
          id: "duty-shift"
        )
        |> to_form()

      {:noreply, assign(socket, picking: %{member: member, date: date}, form: form)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, picking: nil)}

  # More people as the grid is scrolled to its end (AppWeb.CalendarUI).
  def handle_event("more_rows", _params, socket),
    do: {:noreply, CalendarUI.more_rows(socket, socket.assigns.members)}

  def handle_event("validate", %{"form" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form: AshPhoenix.Form.validate(socket.assigns.form, with_cell(params, socket))
       )}

  def handle_event("save", %{"form" => params}, socket) do
    case existing(socket) do
      nil -> :ok
      shift -> Ash.destroy(shift, actor: socket.assigns.current_user)
    end

    case AshPhoenix.Form.submit(socket.assigns.form, params: with_cell(params, socket)) do
      {:ok, _} -> {:noreply, socket |> assign(picking: nil) |> load(keep: true)}
      {:error, form} -> {:noreply, socket |> assign(form: form) |> load(keep: true)}
    end
  end

  def handle_event("clear", _params, socket) do
    case existing(socket) do
      nil ->
        {:noreply, assign(socket, picking: nil)}

      shift ->
        _ = Ash.destroy(shift, actor: socket.assigns.current_user)
        {:noreply, socket |> assign(picking: nil) |> load(keep: true)}
    end
  end

  defp existing(%{assigns: %{picking: %{member: member, date: date}, shifts: shifts}}),
    do: Map.get(shifts, {member.person_id, date})

  defp existing(_socket), do: nil

  defp with_cell(params, %{assigns: %{picking: %{member: member, date: date}, unit: unit}}),
    do:
      Map.merge(params, %{
        "person_id" => member.person_id,
        "date" => Date.to_iso8601(date),
        "organization_id" => unit
      })

  defp roster_path(unit, month),
    do: ~p"/duty-roster?#{[unit: unit, month: Elixir.Calendar.strftime(month, "%Y-%m")]}"

  defp shift_month(month, n), do: month |> Date.beginning_of_month() |> Date.shift(month: n)

  defp type_label(id) do
    case Types.get(id) do
      nil -> id
      type -> AppWeb.SchemaText.translate(type["label"])
    end
  end

  # The first letters of the translated label: "Черговий частини" → "ЧЧ".
  defp abbr(id) do
    id
    |> type_label()
    |> String.split(~r/[\s\-]+/u, trim: true)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> String.slice(0, 3)
  end

  defp problem_count(problems, kind),
    do: Enum.count(problems, fn {_key, kinds} -> kind in kinds end)

  defp cell_class(nil, _problems), do: nil

  defp cell_class(_shift, problems) do
    cond do
      :away in problems -> "bg-error text-error-content"
      :no_rest in problems -> "bg-warning text-warning-content"
      true -> "bg-primary/15"
    end
  end

  defp cell_tip(nil, _problems), do: nil

  defp cell_tip(shift, problems) do
    [
      type_label(shift.duty_type),
      :away in problems && gettext("away that day"),
      :no_rest in problems && gettext("no rest between duties"),
      shift.note
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp gap_tip(gaps) do
    Enum.map_join(gaps, "; ", fn {type, have, need} -> "#{type_label(type)}: #{have}/#{need}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-6xl flex-col gap-4 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Duty roster")}
            <.field_description description={
              gettext(
                "Who of the unit is on which duty which day. Red: on duty while away (leave, sick leave, a trip). Amber: two duties too close. A day marked above lacks people for a duty. Commanders and HR plan by clicking a cell."
              )
            } />
          </h1>
          <div class="flex flex-wrap items-center gap-2">
            <form id="roster-unit" phx-change="unit">
              <label for="roster-unit-select" class="sr-only">{gettext("Unit")}</label>
              <select id="roster-unit-select" name="unit" class="select select-sm max-w-64">
                <option :for={unit <- @units} value={unit.id} selected={unit.id == @unit}>
                  {unit.name}
                </option>
              </select>
            </form>
            <div class="join">
              <.link
                patch={roster_path(@unit, shift_month(@month, -1))}
                class="btn btn-sm join-item"
                aria-label={gettext("Previous month")}
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </.link>
              <.link
                patch={roster_path(@unit, Date.utc_today())}
                class="btn btn-sm join-item tabular-nums"
              >
                {month_label(@month)}
              </.link>
              <.link
                patch={roster_path(@unit, shift_month(@month, 1))}
                class="btn btn-sm join-item"
                aria-label={gettext("Next month")}
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </.link>
            </div>
          </div>
        </div>

        <section id="roster-summary" class="flex flex-wrap gap-x-6 gap-y-1 text-sm">
          <span class={problem_count(@problems, :away) > 0 && "font-semibold text-error"}>
            {gettext("On duty while away: %{count}", count: problem_count(@problems, :away))}
          </span>
          <span class={problem_count(@problems, :no_rest) > 0 && "font-semibold text-warning"}>
            {gettext("Without rest: %{count}", count: problem_count(@problems, :no_rest))}
          </span>
          <span class={map_size(@gaps) > 0 && "font-semibold"}>
            {gettext("Days short of people: %{count}", count: map_size(@gaps))}
          </span>
        </section>

        <section :if={@picking} id="duty-pick" class="flex flex-col gap-2">
          <h2 class="flex flex-wrap items-center gap-2 font-semibold">
            {Person.full_name(@picking.member.person)}
            <span class="opacity-70">{AppWeb.DateFormat.display(@picking.date)}</span>
            <button
              type="button"
              phx-click="close"
              class="btn btn-ghost btn-xs ml-auto"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </h2>
          <.form for={@form} id="duty-shift-form" phx-change="validate" phx-submit="save">
            <JsonSchemaForm.json_schema_form
              schema={@schema}
              ui_schema={FormSchemas.ui_schema(:duty_shift)}
              form={@form}
            />
            <div class="mt-2 flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Assign")}</button>
              <button
                :if={Map.has_key?(@shifts, {@picking.member.person_id, @picking.date})}
                type="button"
                phx-click="clear"
                class="btn btn-ghost btn-sm text-error"
              >
                {gettext("Remove the duty")}
              </button>
            </div>
          </.form>
        </section>

        <section id="roster-grid" class="flex flex-col gap-3">
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
                    :for={date <- @dates}
                    class={[
                      "w-7 min-w-7 px-0 pb-1 text-center font-normal tabular-nums",
                      weekend?(date) && "bg-base-200"
                    ]}
                    data-float-tip={@gaps[date] && gap_tip(@gaps[date])}
                  >
                    <div class={["mx-0.5 mb-1 h-1 rounded-full", @gaps[date] && "bg-error"]}></div>
                    <div class="opacity-60">{weekday(date)}</div>
                    <div class={date == Date.utc_today() && "font-bold text-primary"}>{date.day}</div>
                  </th>
                </tr>
              </thead>
              <tbody
                id="roster-rows"
                phx-update="stream"
                phx-viewport-bottom={@shown < length(@members) && "more_rows"}
              >
                <tr
                  :for={{dom_id, %{member: member}} <- @streams.rows}
                  id={dom_id}
                  class="hover:bg-base-200/50"
                >
                  <th class="sticky left-0 z-10 max-w-56 truncate bg-base-100 px-2 py-1 text-left font-normal">
                    {Person.full_name(member.person)}
                  </th>
                  <td :for={date <- @dates} class={["h-7 p-0", weekend?(date) && "bg-base-200/60"]}>
                    <% shift = @shifts[{member.person_id, date}] %>
                    <% problems = Map.get(@problems, {member.person_id, date}, []) %>
                    <button
                      :if={@can_plan?}
                      type="button"
                      phx-click="pick"
                      phx-value-person={member.person_id}
                      phx-value-date={Date.to_iso8601(date)}
                      class={[
                        "mx-px block h-6 w-6 rounded-sm text-[10px] font-semibold",
                        cell_class(shift, problems),
                        !shift && "hover:bg-base-300"
                      ]}
                      data-float-tip={cell_tip(shift, problems)}
                      aria-label={"#{Person.full_name(member.person)} #{AppWeb.DateFormat.display(date)}"}
                    >
                      {shift && abbr(shift.duty_type)}
                    </button>
                    <span
                      :if={!@can_plan? and shift}
                      class={[
                        "mx-px grid h-6 w-6 place-items-center rounded-sm text-[10px] font-semibold",
                        cell_class(shift, problems)
                      ]}
                      data-float-tip={cell_tip(shift, problems)}
                    >
                      {abbr(shift.duty_type)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div :if={@members != []} class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
            <span :for={type <- Types.all()} class="flex items-center gap-1">
              <span class="font-semibold">{abbr(type["id"])}</span> {type_label(type["id"])}
              <span class="opacity-60">×{type["per_day"]}</span>
            </span>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
