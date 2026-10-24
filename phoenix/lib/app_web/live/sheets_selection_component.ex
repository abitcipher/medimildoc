defmodule AppWeb.SheetsSelectionComponent do
  @moduledoc """
  SHEETS-UI.13 (docs/design/sheets-ui.md): the selected row of any
  laid-out tab, as the app's form for its dataset. The hook
  `SheetSelection` reports the selected cell; the tab's own label row
  says which dataset it holds (`App.Google.LaidOutTab.head/3`, read once
  per tab), so a renamed tab still works. Assignments open in
  `AppWeb.SheetsRowFormComponent`, people and records in
  `AppWeb.SheetsRecordRowComponent`; the Data tab follows the dataset
  (`AppWeb.SheetsDataComponent`).

  `send_update(…, new: dataset)` (the top row's New icon, SHEETS-UI.15)
  opens an empty form for `dataset` instead.
  """
  use AppWeb, :live_component

  alias App.Google.LaidOutTab
  alias AppWeb.SheetLayout

  # Rows 1-2 are the keys and the labels (AppWeb.SheetLayout).
  @first_row 3

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       heads: %{},
       sheet: nil,
       dataset: nil,
       keys: nil,
       row: nil,
       new: nil,
       new_seq: 0,
       reload: 0,
       outside?: false,
       message: nil
     )}
  end

  @impl true
  def update(%{new: dataset}, socket) do
    tab = SheetLayout.tab(dataset)

    case head(socket, tab) do
      {socket, {:ok, keys, ^dataset}} ->
        {:ok,
         assign(socket,
           new: dataset,
           new_seq: socket.assigns.new_seq + 1,
           sheet: tab,
           dataset: dataset,
           keys: keys,
           row: nil,
           message: nil
         )}

      {socket, _} ->
        {:ok,
         assign(socket,
           new: nil,
           message: gettext("There is no %{tab} tab in this spreadsheet. Export first.", tab: tab)
         )}
    end
  end

  # The Data tab carried out a check: the shown row may have changed.
  def update(%{reload: true}, socket),
    do: {:ok, update(socket, :reload, &(&1 + 1))}

  # An edit in the sheet (the shim's onEdit, SHEETS-UI.20): read the shown
  # row again if the edit touched it.
  def update(
        %{edited: %{sheet_name: sheet, a1: a1}},
        %{assigns: %{sheet: sheet, row: row}} = socket
      )
      when is_integer(row) do
    if row in edited_rows(a1),
      do: {:ok, update(socket, :reload, &(&1 + 1))},
      else: {:ok, socket}
  end

  def update(%{edited: _attrs}, socket), do: {:ok, socket}

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("selection", %{"sheet" => sheet, "a1" => a1}, socket) do
    case {row_number(a1), head(socket, sheet)} do
      {n, {socket, {:ok, keys, dataset}}}
      when is_integer(n) and n >= @first_row and dataset != nil ->
        send_update(AppWeb.SheetsDataComponent, id: "sheets-data", selected_dataset: dataset)

        {:noreply,
         assign(socket,
           sheet: sheet,
           dataset: dataset,
           keys: keys,
           row: n,
           new: nil,
           outside?: false,
           message: nil
         )}

      {_n, {socket, {:ok, _keys, dataset}}} when dataset != nil ->
        # A header row of a laid-out tab: keep what is shown.
        {:noreply, socket}

      {_n, {socket, _}} ->
        {:noreply,
         assign(socket, outside?: socket.assigns.row == nil and socket.assigns.new == nil)}
    end
  end

  def handle_event("selection", _params, socket), do: {:noreply, socket}

  # The key row and dataset of `sheet`, read once.
  defp head(socket, sheet) do
    case socket.assigns.heads[sheet] do
      nil ->
        %{token: token, spreadsheet_id: ssid} = socket.assigns

        case token && LaidOutTab.head(token, ssid, sheet) do
          {:ok, keys, dataset} = found when dataset != nil ->
            {update(socket, :heads, &Map.put(&1, sheet, {keys, dataset})), found}

          other ->
            {socket, other}
        end

      {keys, dataset} ->
        {socket, {:ok, keys, dataset}}
    end
  end

  # "D7" → 7..7, "D7:E9" → 7..9.
  defp edited_rows(a1) do
    case Regex.scan(~r/[A-Z]+(\d+)/, a1 || "") do
      [[_, a]] -> String.to_integer(a)..String.to_integer(a)
      [[_, a], [_, b] | _] -> String.to_integer(a)..String.to_integer(b)//1
      _ -> 1..0//1
    end
  end

  # "D7", "D7:E9", "Assignments!D7" → 7.
  defp row_number(a1) do
    case Regex.run(~r/[A-Z]+(\d+)/, a1 || "") do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SheetSelection"
      phx-target={@myself}
      class="flex flex-col gap-2 border-t border-base-300 pt-3"
    >
      <div class="flex items-center justify-between gap-2">
        <h3 class="flex min-w-0 items-center gap-1 text-sm font-semibold">
          <span class="whitespace-nowrap">{gettext("Selected row")}</span>
          <span :if={@row} class="tabular-nums opacity-60">{@row}</span>
          <span :if={@dataset} class="truncate text-xs font-normal opacity-60">
            {SheetLayout.label(@dataset)}
          </span>
          <.field_description description={
            gettext(
              "Select a row on a tab the app wrote: it opens here as the app's form. Write to the sheet to change the row for a later check, or Check to save this one row now."
            )
          } />
        </h3>
        <button
          type="button"
          data-selection-refresh
          class="btn btn-ghost btn-xs btn-square"
          aria-label={gettext("Use the selected row")}
          data-float-tip={gettext("Use the selected row")}
        >
          <.icon name="hero-cursor-arrow-rays" class="size-4" />
        </button>
      </div>

      <p :if={@outside?} class="text-xs opacity-70">
        {gettext("Select a row on a tab the app wrote (Export first).")}
      </p>
      <p :if={@message} role="alert" class="text-xs text-error">{@message}</p>

      <.live_component
        :if={@dataset == "assignments" and @row}
        module={AppWeb.SheetsRowFormComponent}
        id="sheets-row-form"
        actor={@actor}
        can_write={@can_write}
        token={@token}
        spreadsheet_id={@spreadsheet_id}
        selected={@row}
        reload={@reload}
      />

      <.live_component
        :if={@dataset not in [nil, "assignments"] and (@row || @new)}
        module={AppWeb.SheetsRecordRowComponent}
        id="sheets-record-row"
        actor={@actor}
        can_write={@can_write}
        token={@token}
        spreadsheet_id={@spreadsheet_id}
        dataset={@dataset}
        tab={@sheet}
        keys={@keys}
        selected={@row}
        reload={@reload}
        new={if @new && is_nil(@row), do: @new_seq}
      />
    </div>
    """
  end
end
