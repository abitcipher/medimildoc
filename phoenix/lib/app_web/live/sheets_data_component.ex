defmodule AppWeb.SheetsDataComponent do
  @moduledoc """
  The sidebar's Data tab (SHEETS-UI, docs/design/sheets-ui.md): pick a
  dataset — assignments, people, a record kind (SHEETS-UI.12) — and walk
  it through Export → Edit → Check → Carry out. The spreadsheet is a view
  nothing reaches the app until the user confirms the preview.
  Sheets API with the user's own token ; the work is in
  `AppWeb.SheetTabs`.

  - the **step guide** with the current step's action (SHEETS-UI.7);
  - the **Status column**: a check writes each row's finding, Carry out
    what was done (SHEETS-UI.8, 5);
  - for assignments, the **draft orders created** with links and "Cancel
    these drafts" (SHEETS-UI.10);
  - rows the app changed after the export are left out and marked
    (SHEETS-UI.11).

  The top row's tool icons (`AppWeb.SheetsLive`) send `export`, `import`
  and `new` here.
  """
  use AppWeb, :live_component

  alias App.Access.Unit
  alias App.Google.{LaidOutTab, Sheets}
  alias App.People.{AssignmentSync, Organization, Person, PersonId}
  alias AppWeb.{AssignmentPlan, SheetLayout, SheetPlan, SheetTabs}

  @steps [:export, :edit, :check, :carry_out]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       dataset: nil,
       datasets: [],
       plan: nil,
       read: nil,
       result: nil,
       message: nil,
       drafts: [],
       step: nil,
       tabs: nil,
       units: [],
       unit: nil,
       found: nil
     )}
  end

  @impl true
  def update(%{selected_dataset: dataset}, socket) do
    # A laid-out tab selected in the spreadsheet: follow it, unless a
    # check is waiting for its Carry out.
    if dataset in socket.assigns.datasets and socket.assigns.plan == nil and
         dataset != socket.assigns.dataset,
       do: {:ok, pick(socket, dataset)},
       else: {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.dataset do
      {:ok, socket}
    else
      actor = socket.assigns.actor
      datasets = if actor, do: SheetLayout.datasets(actor), else: []
      units = if actor, do: units(actor), else: []
      own = Unit.own_org_id(actor)

      socket
      |> assign(
        datasets: datasets,
        units: units,
        unit: if(Enum.any?(units, &(elem(&1, 0) == own)), do: own)
      )
      |> pick(List.first(datasets))
      |> load_tabs()
      |> then(&{:ok, &1})
    end
  end

  # The organizations the actor may see, as a tree: `[{id, "— name"}]`.
  defp units(actor) do
    orgs = Organization |> Ash.Query.sort(:name) |> Ash.read!(actor: actor)
    ids = MapSet.new(orgs, & &1.id)
    children = Enum.group_by(orgs, &if(MapSet.member?(ids, &1.parent_id), do: &1.parent_id))
    tree(children, nil, 0)
  end

  defp tree(children, parent, depth) do
    Enum.flat_map(children[parent] || [], fn org ->
      [{org.id, String.duplicate("— ", depth) <> org.name} | tree(children, org.id, depth + 1)]
    end)
  end

  defp pick(socket, dataset) do
    socket
    |> restore_view(dataset)
    |> assign(
      dataset: dataset,
      plan: nil,
      read: nil,
      result: nil,
      message: nil,
      drafts: [],
      step: step_for(dataset, socket.assigns.tabs)
    )
  end

  # The unit a tab was exported for (its marker): exporting it again
  # keeps it (SHEETS-UI.17).
  defp restore_view(
         %{assigns: %{token: token, spreadsheet_id: ssid, tabs: tabs}} = socket,
         dataset
       )
       when is_binary(token) and is_list(tabs) and dataset != nil do
    tab = SheetLayout.tab(dataset)

    if tab in tabs,
      do: start_async(socket, :view, fn -> LaidOutTab.view(token, ssid, tab) end),
      else: socket
  end

  defp restore_view(socket, _dataset), do: socket

  # Edit when the spreadsheet already has the dataset's tab.
  defp step_for(nil, _tabs), do: nil
  defp step_for(_dataset, nil), do: :export

  defp step_for(dataset, tabs),
    do: if(SheetLayout.tab(dataset) in tabs, do: :edit, else: :export)

  defp load_tabs(%{assigns: %{token: nil}} = socket), do: socket

  defp load_tabs(%{assigns: %{token: token, spreadsheet_id: ssid}} = socket),
    do: start_async(socket, :tabs, fn -> Sheets.sheets(token, ssid) end)

  @impl true
  def handle_async(:tabs, {:ok, {:ok, sheets}}, socket) do
    tabs = Enum.map(sheets, & &1["title"])
    socket = socket |> assign(tabs: tabs) |> restore_view(socket.assigns.dataset)

    {:noreply,
     if(socket.assigns.step == :export,
       do: assign(socket, step: step_for(socket.assigns.dataset, tabs)),
       else: socket
     )}
  end

  def handle_async(:tabs, _failed, socket), do: {:noreply, socket}

  def handle_async(:view, {:ok, {:ok, %{"unit" => unit}}}, socket) do
    if Enum.any?(socket.assigns.units, &(elem(&1, 0) == unit)),
      do: {:noreply, assign(socket, unit: unit)},
      else: {:noreply, socket}
  end

  def handle_async(:view, {:ok, {:ok, _view}}, socket), do: {:noreply, assign(socket, unit: nil)}
  def handle_async(:view, _failed, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pick", %{"dataset" => dataset} = params, socket) do
    cond do
      dataset != socket.assigns.dataset and dataset in socket.assigns.datasets ->
        {:noreply, pick(socket, dataset)}

      Map.has_key?(params, "unit") ->
        unit = params["unit"]
        known? = Enum.any?(socket.assigns.units, &(elem(&1, 0) == unit))
        {:noreply, assign(socket, unit: if(known?, do: unit))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _params, %{assigns: %{token: nil}} = socket)
      when event in ["export", "import"],
      do: {:noreply, assign(socket, message: {:error, sheets_error(:missing_access_token, nil)})}

  def handle_event(event, _params, %{assigns: %{dataset: nil}} = socket)
      when event in ["export", "import"],
      do: {:noreply, socket}

  # SHEETS-UI.18: find a person, go to their row on the open dataset's tab.
  def handle_event("find", %{"q" => q}, socket) do
    found =
      case String.trim(q) do
        text when byte_size(text) < 2 -> nil
        text -> App.Search.people(socket.assigns.actor, text)
      end

    {:noreply, assign(socket, found: found)}
  end

  def handle_event("goto", %{"code" => code}, socket) do
    %{token: token, spreadsheet_id: ssid, dataset: dataset} = socket.assigns
    tab = SheetLayout.tab(dataset)

    case token && LaidOutTab.find_row(token, ssid, tab, "PersonID", code) do
      {:ok, n} when is_integer(n) ->
        {:noreply,
         socket
         |> assign(message: nil)
         |> push_event("sheets:select", %{sheet: tab, a1: "B#{n}"})}

      _ ->
        {:noreply,
         assign(socket,
           message:
             {:error,
              gettext("%{code} isn't on the %{tab} tab. Export it (for the right unit) first.",
                code: code,
                tab: tab
              )}
         )}
    end
  end

  # The top row's New icon: an empty form in the selected-row section.
  def handle_event("new", _params, %{assigns: %{dataset: dataset}} = socket)
      when dataset not in [nil, "assignments"] do
    send_update(AppWeb.SheetsSelectionComponent, id: "sheets-selection", new: dataset)
    {:noreply, assign(socket, message: nil)}
  end

  def handle_event("new", _params, socket),
    do:
      {:noreply,
       assign(socket,
         message:
           {:error,
            gettext(
              "New rows are for people and records: pick one of them above. A new assignment is made on the person's row."
            )}
       )}

  def handle_event("export", _params, socket) do
    %{actor: actor, token: token, spreadsheet_id: ssid, dataset: dataset} = socket.assigns

    case SheetTabs.export(token, ssid, actor, dataset, unit: socket.assigns.unit) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           message: {:ok, exported(dataset)},
           plan: nil,
           result: nil,
           drafts: [],
           step: :edit,
           tabs: Enum.uniq([SheetLayout.tab(dataset) | socket.assigns.tabs || []])
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, message: {:error, sheets_error(reason, dataset)}, plan: nil, result: nil)}
    end
  end

  def handle_event("import", _params, socket) do
    %{actor: actor, token: token, spreadsheet_id: ssid, dataset: dataset} = socket.assigns

    case SheetTabs.check(token, ssid, actor, dataset) do
      {:ok, plan, read} ->
        {:noreply,
         assign(socket,
           plan: plan,
           read: read,
           message: nil,
           result: nil,
           drafts: [],
           step: :carry_out
         )}

      {:error, reason} ->
        {:noreply, assign(socket, plan: nil, message: {:error, sheets_error(reason, dataset)})}
    end
  end

  def handle_event("confirm_import", _params, %{assigns: %{plan: plan}} = socket)
      when plan != nil do
    %{actor: actor, token: token, spreadsheet_id: ssid, dataset: dataset, read: read} =
      socket.assigns

    {result, written} = SheetTabs.carry_out(token, ssid, actor, dataset, plan, read)
    send_update(AppWeb.SheetsSelectionComponent, id: "sheets-selection", reload: true)

    message =
      case written do
        :ok -> {:ok, gettext("The sheet was refreshed from the database.")}
        {:error, reason} -> {:error, sheets_error(reason, dataset)}
      end

    {:noreply,
     assign(socket,
       plan: nil,
       result: result,
       drafts: if(dataset == "assignments", do: AssignmentPlan.drafts(plan, result), else: []),
       message: message,
       step: :done
     )}
  end

  def handle_event("cancel_import", _params, socket),
    do: {:noreply, assign(socket, plan: nil, message: nil, step: :edit)}

  def handle_event("cancel_drafts", _params, socket) do
    %{cancelled: cancelled, kept: kept} =
      AssignmentSync.cancel_drafts(socket.assigns.actor, Enum.map(socket.assigns.drafts, & &1.id))

    message =
      if kept == 0,
        do: ngettext("%{count} draft cancelled.", "%{count} drafts cancelled.", cancelled),
        else:
          gettext(
            "%{cancelled} cancelled; %{kept} already sent for approval or signed, left as they are.",
            cancelled: cancelled,
            kept: kept
          )

    {:noreply, assign(socket, drafts: [], result: nil, message: {:ok, message}, step: :edit)}
  end

  defp exported("assignments"),
    do: gettext("Written to the tabs Assignments, Positions and History.")

  defp exported(dataset), do: gettext("Written to the tab %{tab}.", tab: SheetLayout.tab(dataset))

  defp sheets_error(:missing_access_token, _dataset),
    do: gettext("No Google access token from the sidebar; reopen it.")

  defp sheets_error(:empty, dataset),
    do: gettext("The %{tab} tab is empty. Export first.", tab: SheetLayout.tab(dataset))

  defp sheets_error({:other_dataset, found}, dataset),
    do:
      gettext("The %{tab} tab holds %{found}, not %{dataset}. Export again to replace it.",
        tab: SheetLayout.tab(dataset),
        found: SheetLayout.label(found),
        dataset: SheetLayout.label(dataset)
      )

  # Reading a tab that doesn't exist: "Unable to parse range" (400).
  defp sheets_error({:unexpected_status, 400, _}, dataset),
    do:
      gettext("There is no %{tab} tab in this spreadsheet. Export first.",
        tab: SheetLayout.tab(dataset)
      )

  defp sheets_error(:forbidden, _dataset),
    do: gettext("Google refused access to this spreadsheet (no edit rights?).")

  defp sheets_error(reason, _dataset),
    do: gettext("Sheets error: %{reason}", reason: inspect(reason))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, steps: @steps)

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <form
        :if={@datasets != []}
        id="dataset-form"
        phx-change="pick"
        phx-target={@myself}
        class="grid grid-cols-[auto_1fr] items-center gap-x-2 gap-y-1 text-xs"
      >
        <label for="dataset-select" class="opacity-70">{gettext("Data")}</label>
        <select
          name="dataset"
          id="dataset-select"
          class="select select-sm min-w-0 w-full"
          disabled={@plan != nil}
        >
          <option :for={dataset <- @datasets} value={dataset} selected={dataset == @dataset}>
            {SheetLayout.label(dataset)}
          </option>
        </select>
        <label for="unit-select" class="opacity-70">{gettext("Unit")}</label>
        <select
          name="unit"
          id="unit-select"
          class="select select-sm min-w-0 w-full"
          disabled={@plan != nil}
          title={gettext("Export only the people posted in this unit and below")}
        >
          <option value="" selected={is_nil(@unit)}>{gettext("Everyone you may see")}</option>
          <option :for={{id, name} <- @units} value={id} selected={id == @unit}>{name}</option>
        </select>
      </form>

      <%!-- Shown by the top row's Find icon (a JS toggle, kept across
      re-renders). --%>
      <div id="find-box" class="hidden flex-col gap-1 [&:not(.hidden)]:flex">
        <form id="find-form" phx-change="find" phx-submit="find" phx-target={@myself}>
          <input
            id="find-input"
            type="search"
            name="q"
            phx-debounce="300"
            autocomplete="off"
            placeholder={gettext("Name, e-mail or PersonID")}
            class="input input-sm w-full"
          />
        </form>
        <p :if={@found == []} class="text-xs opacity-70">{gettext("No one found.")}</p>
        <ul :if={@found not in [nil, []]} class="flex flex-col divide-y divide-base-200 text-xs">
          <li :for={person <- @found} class="flex items-center gap-1 py-1">
            <button
              type="button"
              phx-click="goto"
              phx-value-code={PersonId.format(person.person_id)}
              phx-target={@myself}
              class="flex min-w-0 grow flex-col items-start text-left hover:underline"
              data-float-tip={
                gettext("Go to the row on the %{tab} tab", tab: @dataset && SheetLayout.tab(@dataset))
              }
            >
              <span class="truncate font-medium">{Person.full_name(person)}</span>
              <span class="font-mono opacity-60">{PersonId.format(person.person_id)}</span>
            </button>
            <a
              href={~p"/people/#{person.id}"}
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-xs btn-square"
              aria-label={gettext("Open in the app")}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
          </li>
        </ul>
      </div>

      <p :if={@datasets == []} class="text-xs opacity-70">
        {gettext("No data you may open as a sheet.")}
      </p>

      <div :if={@steps? and @step} id="data-steps" class="flex flex-col gap-2">
        <ul class="steps steps-horizontal w-full text-[0.7rem]">
          <li
            :for={step <- @steps}
            data-step={step}
            data-current={step == @step}
            class={["step", reached?(step, @step) && "step-primary"]}
          >
            {step_label(step)}
          </li>
        </ul>
        <div class="flex items-center gap-2 text-xs">
          <p class="flex-1 opacity-80">{step_hint(@step, @dataset)}</p>
          <button
            :if={@step == :export}
            type="button"
            id="step-export"
            phx-click="export"
            phx-target={@myself}
            class="btn btn-primary btn-xs"
          >
            {gettext("Export")}
          </button>
          <button
            :if={@step in [:edit, :done] and @can_write}
            type="button"
            id="step-check"
            phx-click="import"
            phx-target={@myself}
            class="btn btn-primary btn-xs"
          >
            {gettext("Check")}
          </button>
        </div>
      </div>

      <div
        :if={@message}
        role={if elem(@message, 0) == :ok, do: "status", else: "alert"}
        class={[
          "alert alert-soft text-xs",
          if(elem(@message, 0) == :ok, do: "alert-success", else: "alert-error")
        ]}
      >
        <.icon
          name={if elem(@message, 0) == :ok, do: "hero-check-circle", else: "hero-exclamation-circle"}
          class="size-4"
        />
        {elem(@message, 1)}
      </div>

      <%= if @dataset == "assignments" do %>
        <AssignmentPlan.preview :if={@plan} plan={@plan} target={@myself} compact />
        <AssignmentPlan.report :if={@result} result={@result} drafts={@drafts} target={@myself} />
      <% else %>
        <SheetPlan.preview :if={@plan} plan={@plan} target={@myself} />
        <SheetPlan.report :if={@result} result={@result} />
      <% end %>
    </div>
    """
  end

  defp reached?(_step, :done), do: true

  defp reached?(step, current),
    do: Enum.find_index(@steps, &(&1 == step)) <= Enum.find_index(@steps, &(&1 == current))

  defp step_label(:export), do: gettext("Export")
  defp step_label(:edit), do: gettext("Edit")
  defp step_label(:check), do: gettext("Check")
  defp step_label(:carry_out), do: gettext("Carry out")

  defp step_hint(:export, dataset),
    do: gettext("Write %{data} into this spreadsheet.", data: SheetLayout.label(dataset))

  defp step_hint(:edit, "assignments"),
    do:
      gettext(
        "Change posts or start dates on the Assignments tab (or select a row to use the form below), then check."
      )

  defp step_hint(:edit, dataset),
    do:
      gettext(
        "Change cells or add rows on the %{tab} tab (or select a row to use the form below), then check.",
        tab: SheetLayout.tab(dataset)
      )

  defp step_hint(:carry_out, _dataset),
    do: gettext("The Status column shows each row's change. Carry them out below, or cancel.")

  defp step_hint(:done, _dataset),
    do: gettext("Done: the Status column shows what happened to each row.")
end
