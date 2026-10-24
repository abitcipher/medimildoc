defmodule AppWeb.SheetsRowFormComponent do
  @moduledoc """
  SHEETS-UI (docs/design/sheets-ui.md): the selected row of the Assignments
  tab as the app's own assignment form, in the sidebar. The selection
  (`AppWeb.SheetsSelectionComponent`) gives the row; this reads it
  through the Sheets API, finds the person, and shows who they are
  (`AppWeb.SheetPerson`), their current post (from the database) and the
  form (`assignment` form schema, the same as on the person's page) filled
  from the row.

  - "Write to the sheet" puts the form's values into the row's cells (the
    sheet then marks them as changed) — for a batch imported later;
  - "Check" plans this one row exactly like an import
    (`App.People.AssignmentSync.plan/4`) and, once confirmed, carries it out
    (a draft order, or a corrected start date) and writes the row again
    from the database, with its Status (`AppWeb.SheetStatus`).

  The row is compared with the app as soon as it is selected
  (SHEETS-UI.9): which cells differ from the current post, or that the
  app changed it after the export.
  """
  use AppWeb, :live_component

  require Ash.Query

  alias App.Google.AssignmentSheets
  alias App.People.{Assignment, AssignmentSync, Person, PersonId}

  alias AppWeb.{
    AssignmentPlan,
    FormSchemas,
    JsonSchemaForm,
    SheetLayout,
    SheetPerson,
    SheetStatus
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       row: nil,
       keys: nil,
       cells: nil,
       person: nil,
       summary: nil,
       current: nil,
       values: %{},
       labels: nil,
       diff: [],
       plan: nil,
       result: nil,
       message: nil
     )}
  end

  # `selected`: the sheet row to show (from the selection component);
  # `reload`: a counter — read the row again (the tab was carried out).
  @impl true
  def update(assigns, socket) do
    {selected, assigns} = Map.pop(assigns, :selected)
    {reload, assigns} = Map.pop(assigns, :reload)
    reload? = reload != socket.assigns[:reload] and socket.assigns[:reload] != nil
    socket = assign(socket, assigns) |> assign(reload: reload)

    cond do
      selected && selected != socket.assigns.row -> {:ok, load_row(socket, selected)}
      reload? and socket.assigns.row != nil -> {:ok, load_row(socket, socket.assigns.row)}
      true -> {:ok, socket}
    end
  end

  @impl true
  # SHEETS-UI.3: the person's Record card, written into the tab "Card"
  # and shown there.
  def handle_event("card", %{"id" => id}, socket) do
    %{token: token, spreadsheet_id: ssid, actor: actor} = socket.assigns

    case AppWeb.SheetCard.open(token, ssid, actor, id) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           message: {:ok, gettext("Written to the tab %{tab}.", tab: AppWeb.SheetCard.tab())}
         )
         |> push_event("sheets:select", %{sheet: AppWeb.SheetCard.tab(), a1: "A1"})}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           message: {:error, gettext("Sheets error: %{reason}", reason: inspect(reason))}
         )}
    end
  end

  def handle_event("change", %{"row" => values}, socket),
    do: {:noreply, assign(socket, values: values)}

  # The form's values (kept on every change) into the row's cells.
  def handle_event("write_cells", _params, socket) do
    %{token: token, spreadsheet_id: ssid, keys: keys, row: n, values: values} = socket.assigns

    result =
      [{"Position", values["position_id"] || ""}, {"Since", since_cell(values["starts_on"])}]
      |> Enum.flat_map(fn {key, value} ->
        case Enum.find_index(keys, &(&1 == key)) do
          nil -> []
          i -> [AssignmentSheets.write_row(token, ssid, n, SheetLayout.letter(i), [value])]
        end
      end)
      |> Enum.find(:ok, &(&1 != :ok))

    message =
      case result do
        :ok -> {:ok, gettext("Written to row %{row}. Check the sheet to carry it out.", row: n)}
        {:error, reason} -> {:error, gettext("Sheets error: %{reason}", reason: inspect(reason))}
      end

    {:noreply, assign(socket, message: message)}
  end

  def handle_event("check", %{"row" => values}, socket) do
    %{actor: actor, keys: keys, cells: cells, row: n} = socket.assigns

    edited =
      keys
      |> Enum.with_index()
      |> Enum.map(fn
        {"Position", _} -> values["position_id"] || ""
        {"Since", _} -> display_date(values["starts_on"])
        {_key, i} -> Enum.at(cells, i, "")
      end)

    plan = AssignmentSync.plan(actor, [keys, edited], Date.utc_today(), first_row: n)
    {:noreply, assign(socket, values: values, plan: plan, result: nil, message: nil)}
  end

  def handle_event("confirm_import", _params, %{assigns: %{plan: plan}} = socket)
      when plan != nil do
    result = AssignmentSync.apply(socket.assigns.actor, plan)

    status = SheetStatus.for_result(plan, result)[socket.assigns.row] || ""

    # Re-reading the row resets the panel; the report stays.
    {:noreply,
     socket
     |> assign(plan: nil)
     |> refresh_row(status)
     |> assign(result: result)}
  end

  def handle_event("cancel_import", _params, socket), do: {:noreply, assign(socket, plan: nil)}

  # A cell by its key; "" when the tab has no such column.
  defp cell(keys, cells, key) do
    case Enum.find_index(keys, &(&1 == key)) do
      nil -> ""
      i -> Enum.at(cells, i, "")
    end
  end

  defp options(nil), do: []
  defp options(labels), do: labels |> Map.values() |> Enum.sort() |> Enum.map(&{&1, &1})

  defp diff_text({:position, sheet, app}),
    do:
      gettext("Post in the sheet: %{sheet} (in the app: %{app})",
        sheet: blank(sheet),
        app: blank(app)
      )

  defp diff_text({:since, sheet, app}),
    do:
      gettext("Start date in the sheet: %{sheet} (in the app: %{app})",
        sheet: blank(sheet && Calendar.strftime(sheet, "%d.%m.%Y")),
        app: blank(app && Calendar.strftime(app, "%d.%m.%Y"))
      )

  defp blank(value) when value in [nil, ""], do: "—"
  defp blank(value), do: value

  defp load_row(socket, n) do
    %{token: token, spreadsheet_id: ssid, actor: actor} = socket.assigns

    case AssignmentSheets.read_row(token, ssid, n) do
      {:ok, keys, cells} ->
        cell = &cell(keys, cells, &1)
        person = find_person(actor, cell.("PersonID"))
        current = person && current(actor, person)
        labels = socket.assigns.labels || AssignmentSync.label_map(actor)

        assign(socket,
          row: n,
          keys: keys,
          cells: cells,
          person: person,
          summary: person && SheetPerson.load(person, actor),
          current: current,
          values: %{"position_id" => cell.("Position"), "starts_on" => iso(cell.("Since"))},
          labels: labels,
          diff: if(person, do: diff(cell, current, labels, "ExportedPosition" in keys), else: []),
          plan: nil,
          result: nil,
          message: nil
        )

      {:error, reason} ->
        assign(socket,
          row: n,
          person: nil,
          message: {:error, gettext("Sheets error: %{reason}", reason: inspect(reason))}
        )
    end
  end

  # How the row differs from the app: `[{:position, sheet, app}, {:since,
  # sheet, app}]`, or `[:stale]` when it wasn't edited but the app changed
  # the person after the export (importing it would undo that).
  defp diff(cell, current, labels, copies?) do
    differs = differs(cell, current, labels)

    if differs != [] and copies? and unedited?(cell) and stale?(cell, current),
      do: [:stale],
      else: differs
  end

  defp differs(cell, current, labels) do
    app_position = (current && labels[current.position_id]) || ""
    app_since = current && current.starts_on

    since =
      case AssignmentSync.parse_date(cell.("Since")) do
        {:ok, date} -> date
        {:error, _} -> nil
      end

    [
      cell.("Position") != app_position && {:position, cell.("Position"), app_position},
      since != app_since && {:since, since, app_since}
    ]
    |> Enum.filter(& &1)
  end

  defp unedited?(cell),
    do:
      cell.("Position") == cell.("ExportedPosition") and
        AssignmentSync.parse_date(cell.("Since")) ==
          AssignmentSync.parse_date(cell.("ExportedSince"))

  defp stale?(cell, current),
    do: cell.("Version") != ((current && AssignmentSync.version(current)) || "")

  # The row again from the database, so the sheet matches what was done.
  defp refresh_row(socket, status) do
    %{actor: actor, token: token, spreadsheet_id: ssid, row: n, person: person} = socket.assigns
    [header | rows] = AssignmentSync.export(actor).assignments
    code = PersonId.format(person.person_id)

    with [_ | _] = values <- Enum.find(rows, &(List.first(&1) == code)),
         :ok <-
           AssignmentSheets.write_row(
             token,
             ssid,
             n,
             "A",
             SheetLayout.row("assignments", header ++ ["Status"], values ++ [status])
           ) do
      load_row(socket, n)
    else
      {:error, reason} ->
        assign(socket,
          message: {:error, gettext("Sheets error: %{reason}", reason: inspect(reason))}
        )

      _ ->
        socket
    end
  end

  defp find_person(_actor, ""), do: nil

  defp find_person(actor, code) do
    code = PersonId.unformat(code)

    Person
    |> Ash.Query.filter(person_id == ^code)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, person} -> person
      _ -> nil
    end
  end

  defp current(actor, person) do
    # The earliest started open one, as the export shows it.
    Assignment
    |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
    |> Ash.Query.sort(starts_on: :asc)
    |> Ash.Query.load(position: :organization)
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  # The sheet shows dd.mm.yyyy; the form's date input takes ISO.
  defp iso(value) do
    case AssignmentSync.parse_date(value) do
      {:ok, %Date{} = date} -> Date.to_iso8601(date)
      _ -> ""
    end
  end

  defp display_date(iso) do
    case Date.from_iso8601(iso || "") do
      {:ok, date} -> Calendar.strftime(date, "%d.%m.%Y")
      _ -> ""
    end
  end

  # A date cell is a serial number (formatted dd.mm.yyyy by the layout).
  defp since_cell(iso) do
    case Date.from_iso8601(iso || "") do
      {:ok, date} -> SheetLayout.serial(date)
      _ -> ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@row && is_nil(@person) && is_nil(@message)} class="text-xs opacity-70">
        {gettext("No person in this row (or not one you may see).")}
      </p>

      <div :if={@person} id={"#{@id}-person"} class="flex flex-col gap-1 text-sm">
        <SheetPerson.summary id={"#{@id}-summary"} summary={@summary} target={@myself} />
        <span :if={@current} class="text-xs">
          {gettext("Now: %{post}, %{unit}, since %{date}",
            post: @current.position.title,
            unit: @current.position.organization && @current.position.organization.name,
            date: Calendar.strftime(@current.starts_on, "%d.%m.%Y")
          )}
        </span>
        <span :if={!@current} class="text-xs opacity-70">{gettext("No current post.")}</span>
        <div id={"#{@id}-diff"} class="text-xs">
          <p :if={@diff == []} class="flex items-center gap-1 text-success">
            <.icon name="hero-check" class="size-3.5" /> {gettext("Same as in the app.")}
          </p>
          <p :if={@diff == [:stale]} class="flex items-start gap-1 text-warning">
            <.icon name="hero-arrow-path" class="size-3.5 shrink-0" />
            {gettext(
              "Changed in the app after the export: this row is out of date. Export again to edit it."
            )}
          </p>
          <ul :if={@diff not in [[], [:stale]]} class="flex flex-col gap-0.5 text-warning">
            <li :for={item <- @diff} class="flex items-start gap-1">
              <.icon name="hero-pencil" class="size-3.5 shrink-0" />
              <span>{diff_text(item)}</span>
            </li>
          </ul>
        </div>
      </div>

      <.form
        :if={@person && @can_write}
        for={%{}}
        id={"#{@id}-form"}
        phx-change="change"
        phx-submit="check"
        phx-target={@myself}
        class="flex flex-col gap-2"
      >
        <JsonSchemaForm.json_schema_form
          schema={FormSchemas.schema(:assignment)}
          ui_schema={FormSchemas.ui_schema(:assignment)}
          values={@values}
          name="row"
          field_options={%{"position_id" => options(@labels)}}
        />
        <div class="form-actions flex flex-wrap gap-2">
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" /> {gettext("Check")}
          </button>
          <button
            type="button"
            id={"#{@id}-write"}
            phx-click="write_cells"
            phx-target={@myself}
            class="btn btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Write to the sheet")}
          </button>
        </div>
      </.form>

      <div
        :if={@message}
        role={if elem(@message, 0) == :ok, do: "status", else: "alert"}
        class={[
          "alert alert-soft text-xs",
          if(elem(@message, 0) == :ok, do: "alert-success", else: "alert-error")
        ]}
      >
        {elem(@message, 1)}
      </div>

      <AssignmentPlan.preview :if={@plan} id="row-preview" plan={@plan} target={@myself} compact />
      <AssignmentPlan.report :if={@result} result={@result} />
    </div>
    """
  end
end
