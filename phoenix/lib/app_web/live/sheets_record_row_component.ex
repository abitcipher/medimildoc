defmodule AppWeb.SheetsRecordRowComponent do
  @moduledoc """
  SHEETS-UI.13/15/16 (docs/design/sheets-ui.md): the selected row of a
  People or record-kind tab as the app's own form (the dataset's JSON
  Schema, cut to the tab's fields: `AppWeb.SheetLayout.form/1`), with who
  it is about (`AppWeb.SheetPerson`) and how the row compares with the
  app — planned like a one-row import (`App.People.SheetSync.plan/4`).

  - **Write to the sheet** puts the form's values into the row's cells;
  - **Check** plans the row as edited in the form; **Carry out** saves it
    and writes the row again from the database, with its Status;
  - **New** (`new: true`, from the top row's icon): an empty form — **Add
    to the sheet** appends it as a row for a later check, **Save in the
    app** saves it now and appends the saved row.
  """
  use AppWeb, :live_component

  require Ash.Query

  alias App.Google.{LaidOutTab, Sheets}
  alias App.People.{AssignmentSync, Person, PersonId, SheetSync}
  alias AppWeb.{JsonSchemaForm, SheetLayout, SheetPerson, SheetPlan, SheetTabs}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       row: nil,
       cells: nil,
       values: %{},
       code: "",
       summary: nil,
       finding: nil,
       plan: nil,
       read: nil,
       result: nil,
       message: nil,
       new?: false,
       new_seq: nil
     )}
  end

  # `selected`: the sheet row to show; `new`: an empty form instead;
  # `reload`: a counter — read the row again (a Carry out of the whole tab
  # changed it).
  @impl true
  def update(assigns, socket) do
    {selected, assigns} = Map.pop(assigns, :selected)
    {new, assigns} = Map.pop(assigns, :new)
    {reload, assigns} = Map.pop(assigns, :reload)
    reload? = reload != socket.assigns[:reload] and socket.assigns[:reload] != nil
    socket = assign(socket, assigns) |> assign(reload: reload)

    {:ok, next(socket, selected, new, reload?)}
  end

  defp next(%{assigns: %{row: row, new?: false}} = socket, _selected, _new, true)
       when row != nil,
       do: load_row(socket, row)

  # A new person gets a PersonID generated now, shown with ↻.
  defp next(socket, _selected, new, _reload?) when new != nil and new != socket.assigns.new_seq,
    do:
      assign(socket,
        new_seq: new,
        new?: true,
        row: nil,
        cells: nil,
        values: %{},
        code: if(socket.assigns.dataset == "people", do: fresh_id(), else: ""),
        summary: nil,
        finding: nil,
        plan: nil,
        result: nil,
        message: nil
      )

  defp next(socket, selected, _new, _reload?)
       when selected != nil and (selected != socket.assigns.row or socket.assigns.new?),
       do: load_row(socket, selected)

  defp next(socket, _selected, _new, _reload?), do: socket

  defp load_row(socket, n) do
    %{token: token, spreadsheet_id: ssid, tab: tab, keys: keys, dataset: dataset} = socket.assigns

    case LaidOutTab.read_row(token, ssid, tab, n) do
      {:ok, cells} when cells == [] ->
        assign(socket,
          new?: false,
          row: n,
          cells: [],
          values: %{},
          code: "",
          summary: nil,
          finding: :empty,
          plan: nil,
          result: nil,
          message: nil
        )

      {:ok, cells} ->
        [_, row] = SheetLayout.unlabel(dataset, [keys, cells])
        code = cell(keys, cells, "PersonID")

        assign(socket,
          new?: false,
          row: n,
          cells: cells,
          values: form_values(dataset, keys, row),
          code: code,
          summary: summary(code, socket.assigns.actor),
          finding: finding(socket, [keys, cells], n),
          plan: nil,
          result: nil,
          message: nil
        )

      {:error, reason} ->
        assign(socket, row: n, summary: nil, message: {:error, sheets_error(reason)})
    end
  end

  # How the row compares with the app: the one-row plan. Nothing at all
  # (not even unchanged): an empty row — below the data an unticked
  # checkbox still reads FALSE, so its cells aren't empty.
  defp finding(socket, rows, n) do
    case SheetTabs.plan(socket.assigns.actor, socket.assigns.dataset, rows, n) do
      %{changes: [change]} -> {:change, change}
      %{errors: [{_row, error}]} -> {:error, error}
      %{stale: [_]} -> :stale
      %{unchanged: 0} -> :empty
      _ -> :same
    end
  end

  defp summary("", _actor), do: nil

  defp summary(code, actor) do
    case Person
         |> Ash.Query.filter(person_id == ^PersonId.unformat(code))
         |> Ash.read_one(actor: actor) do
      {:ok, %Person{} = person} -> SheetPerson.load(person, actor)
      _ -> nil
    end
  end

  # Cells as the form's inputs want them: ISO dates, "true"/"false".
  defp form_values(dataset, keys, row) do
    Map.new(SheetSync.fields(dataset), fn field ->
      value = cell(keys, row, field.key)

      {field.key,
       case field.schema do
         %{"format" => "date"} ->
           case AssignmentSync.parse_date(value) do
             {:ok, %Date{} = date} -> Date.to_iso8601(date)
             _ -> value
           end

         %{"type" => "boolean"} ->
           String.downcase(value)

         _ ->
           value
       end}
    end)
  end

  defp fresh_id, do: PersonId.format(PersonId.generate_unique())

  # Another PersonID for a new person (the first may look unsightly): in
  # the New form, or written into a new row's PersonID cell.
  @impl true
  def handle_event("regenerate_id", _params, %{assigns: %{new?: true}} = socket),
    do: {:noreply, assign(socket, code: fresh_id())}

  def handle_event("regenerate_id", _params, socket) do
    %{token: token, spreadsheet_id: ssid, tab: tab, keys: keys, row: n} = socket.assigns

    case Enum.find_index(keys, &(&1 == "PersonID")) do
      nil ->
        {:noreply, socket}

      i ->
        case LaidOutTab.write_row(token, ssid, tab, n, Sheets.column_letter(i), [fresh_id()]) do
          :ok -> {:noreply, load_row(socket, n)}
          {:error, reason} -> {:noreply, assign(socket, message: {:error, sheets_error(reason)})}
        end
    end
  end

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

  def handle_event("change", params, socket) do
    {:noreply,
     assign(socket,
       values: Map.get(params, "row", socket.assigns.values),
       code: String.trim(Map.get(params, "person_code", socket.assigns.code))
     )}
  end

  # The form's values into the row's cells, one request.
  def handle_event("write_cells", _params, socket) do
    %{token: token, spreadsheet_id: ssid, tab: tab, keys: keys, row: n, dataset: dataset} =
      socket.assigns

    columns = Map.new(SheetLayout.columns(dataset), &{&1.key, &1})

    data =
      for field <- SheetSync.fields(dataset),
          i = Enum.find_index(keys, &(&1 == field.key)),
          i != nil do
        value = SheetLayout.cell(columns[field.key], stored(field, socket.assigns.values))
        {LaidOutTab.range(tab, "#{Sheets.column_letter(i)}#{n}"), [[value]]}
      end

    message =
      case Sheets.batch_update_values(token, ssid, data) do
        {:ok, _} -> {:ok, gettext("Written to row %{row}. Check the sheet to save it.", row: n)}
        {:error, reason} -> {:error, sheets_error(reason)}
      end

    {:noreply, assign(socket, message: message)}
  end

  def handle_event("check", params, socket) do
    socket = assign(socket, values: Map.get(params, "row", socket.assigns.values))
    %{keys: keys, cells: cells, row: n, dataset: dataset} = socket.assigns
    edited = edited_row(dataset, keys, cells, socket.assigns.values)
    plan = SheetTabs.plan(socket.assigns.actor, dataset, [keys, edited], n)

    {:noreply,
     assign(socket,
       plan: plan,
       read: %{tab: socket.assigns.tab, keys: keys, data: [edited], first_row: n},
       result: nil,
       message: nil
     )}
  end

  def handle_event("confirm_import", _params, %{assigns: %{plan: plan}} = socket)
      when plan != nil do
    %{token: token, spreadsheet_id: ssid, actor: actor, dataset: dataset, read: read} =
      socket.assigns

    {result, written} = SheetTabs.carry_out(token, ssid, actor, dataset, plan, read)

    socket = assign(socket, plan: nil, row: nil)
    socket = if written == :ok, do: load_row(socket, read.first_row), else: socket

    {:noreply,
     assign(socket,
       result: result,
       message: if(written == :ok, do: nil, else: {:error, sheets_error(elem(written, 1))})
     )}
  end

  def handle_event("cancel_import", _params, socket), do: {:noreply, assign(socket, plan: nil)}

  def handle_event("append", params, socket) do
    socket = take(socket, params)
    %{token: token, spreadsheet_id: ssid, tab: tab, keys: keys, dataset: dataset} = socket.assigns
    row = edited_row(dataset, keys, context(keys, socket.assigns.code), socket.assigns.values)
    [_keys, cells] = sheet_cells(dataset, keys, row)

    case LaidOutTab.append_row(token, ssid, tab, cells) do
      {:ok, n} ->
        {:noreply,
         socket
         |> load_row(n)
         |> assign(
           message: {:ok, gettext("Added as row %{row}. Check the sheet to save it.", row: n)}
         )}

      {:error, reason} ->
        {:noreply, assign(socket, message: {:error, sheets_error(reason)})}
    end
  end

  def handle_event("save_new", params, socket) do
    socket = take(socket, params)

    %{token: token, spreadsheet_id: ssid, tab: tab, keys: keys, dataset: dataset, actor: actor} =
      socket.assigns

    row = edited_row(dataset, keys, context(keys, socket.assigns.code), socket.assigns.values)

    case SheetTabs.plan(actor, dataset, [keys, row], 0) do
      %{changes: [_]} = plan ->
        result = SheetSync.apply(actor, plan)
        {:noreply, saved(socket, result, result.outcomes[0], {token, ssid, tab})}

      %{errors: [{_row, error} | _]} ->
        {:noreply, assign(socket, message: {:error, SheetPlan.error_text(error)})}

      _ ->
        {:noreply, assign(socket, message: {:error, gettext("Fill in the form first.")})}
    end
  end

  # Saved in the app: the saved row appended to the tab, and shown.
  defp saved(socket, result, {:created, _id, key}, {token, ssid, tab}) do
    %{actor: actor, dataset: dataset} = socket.assigns

    socket =
      case SheetTabs.append_saved(token, ssid, actor, dataset, tab, key) do
        {:ok, n} -> load_row(socket, n)
        {:error, _} -> socket
      end

    assign(socket, result: result, message: {:ok, gettext("Saved in the app.")})
  end

  defp saved(socket, _result, {:failed, message}, _sheet),
    do: assign(socket, message: {:error, message})

  defp take(socket, params),
    do:
      assign(socket,
        values: Map.get(params, "row", socket.assigns.values),
        code: String.trim(Map.get(params, "person_code", socket.assigns.code))
      )

  # A blank row with the person's PersonID (a new record).
  defp context(keys, code),
    do: Enum.map(keys, &if(&1 == "PersonID", do: code, else: ""))

  # The row's cells with the form's values in the field columns.
  defp edited_row(dataset, keys, cells, values) do
    fields = Map.new(SheetSync.fields(dataset), &{&1.key, &1})

    keys
    |> Enum.with_index()
    |> Enum.map(fn {key, i} ->
      case fields[key] do
        nil -> Enum.at(cells || [], i, "")
        field -> stored(field, values)
      end
    end)
  end

  defp stored(field, values), do: to_string(values[field.key] || "")

  # A row of stored values as the tab's cells (dates as serials …).
  defp sheet_cells(dataset, keys, row) do
    columns = Map.new(SheetLayout.columns(dataset), &{&1.key, &1})

    [
      keys,
      keys
      |> Enum.zip(row)
      |> Enum.map(fn {key, value} ->
        case columns[key] do
          %{field: %{}} = col -> SheetLayout.cell(col, value)
          _ -> value
        end
      end)
    ]
  end

  defp new_person?({:change, %{kind: :create}}), do: true
  defp new_person?(_finding), do: false

  defp cell(keys, cells, key) do
    case Enum.find_index(keys, &(&1 == key)) do
      nil -> ""
      i -> cells |> Enum.at(i, "") |> to_string() |> String.trim()
    end
  end

  defp sheets_error(:forbidden),
    do: gettext("Google refused access to this spreadsheet (no edit rights?).")

  defp sheets_error(reason), do: gettext("Sheets error: %{reason}", reason: inspect(reason))

  @impl true
  def render(assigns) do
    {schema, ui} = SheetLayout.form(assigns.dataset)
    labels = SheetPlan.labels(assigns.dataset)
    assigns = assign(assigns, schema: schema, ui: ui, labels: labels)

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@new?} class="text-xs font-medium">
        {gettext("New row: %{data}", data: SheetLayout.label(@dataset))}
      </p>

      <SheetPerson.summary :if={@summary} id={"#{@id}-summary"} summary={@summary} target={@myself} />

      <div
        :if={@dataset == "people" and (@new? or new_person?(@finding))}
        id={"#{@id}-new-id"}
        class="flex items-center gap-2 text-xs"
      >
        <span class="opacity-70">{gettext("PersonID")}</span>
        <span :if={@code != ""} class="font-mono font-medium">{@code}</span>
        <button
          type="button"
          id={"#{@id}-regenerate"}
          phx-click="regenerate_id"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
          aria-label={gettext("Generate another PersonID")}
          data-float-tip={gettext("Generate another PersonID")}
        >
          <.icon name="hero-arrow-path" class="size-4" />
          <span :if={@code == ""}>{gettext("Generate")}</span>
        </button>
      </div>

      <div :if={@row && !@new?} id={"#{@id}-finding"} class="text-xs">
        <p :if={@finding == :empty} class="opacity-70">
          {gettext("An empty row: type a new one in the sheet, or use New at the top.")}
        </p>
        <p :if={@finding == :same} class="flex items-center gap-1 text-success">
          <.icon name="hero-check" class="size-3.5" /> {gettext("Same as in the app.")}
        </p>
        <p :if={@finding == :stale} class="flex items-start gap-1 text-warning">
          <.icon name="hero-arrow-path" class="size-3.5 shrink-0" />
          {gettext(
            "Changed in the app after the export: this row is out of date. Export again to edit it."
          )}
        </p>
        <p :if={match?({:change, _}, @finding)} class="flex items-start gap-1 text-warning">
          <.icon name="hero-pencil" class="size-3.5 shrink-0" />
          {gettext("Differs from the app: %{fields}",
            fields: Enum.map_join(elem(@finding, 1).changed, ", ", &(@labels[&1] || &1))
          )}
        </p>
        <p :if={match?({:error, _}, @finding)} class="flex items-start gap-1 text-error">
          <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />
          {SheetPlan.error_text(elem(@finding, 1))}
        </p>
      </div>

      <.form
        :if={((@row && @finding != :empty) || @new?) && @can_write}
        for={%{}}
        id={"#{@id}-form"}
        phx-change="change"
        phx-submit={if @new?, do: "save_new", else: "check"}
        phx-target={@myself}
        class="flex flex-col gap-2"
      >
        <label :if={@new? and @dataset != "people"} class="flex flex-col gap-1 text-xs">
          <span>{gettext("PersonID")}</span>
          <input
            type="text"
            name="person_code"
            value={@code}
            class="input input-sm"
            placeholder="XXXX-XXXX-XXXX"
          />
        </label>
        <JsonSchemaForm.json_schema_form schema={@schema} ui_schema={@ui} values={@values} name="row" />
        <div class="form-actions flex flex-wrap gap-2">
          <button :if={!@new?} type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" /> {gettext("Check")}
          </button>
          <button
            :if={!@new?}
            type="button"
            id={"#{@id}-write"}
            phx-click="write_cells"
            phx-target={@myself}
            class="btn btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Write to the sheet")}
          </button>
          <button :if={@new?} type="submit" id={"#{@id}-save"} class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" /> {gettext("Save in the app")}
          </button>
          <button
            :if={@new?}
            type="button"
            id={"#{@id}-append"}
            phx-click={JS.push("append", target: @myself, value: %{})}
            class="btn btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Add to the sheet")}
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

      <SheetPlan.preview :if={@plan} id="record-row-preview" plan={@plan} target={@myself} />
      <SheetPlan.report :if={@result} result={@result} />
    </div>
    """
  end
end
