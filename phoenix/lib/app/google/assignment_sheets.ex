defmodule App.Google.AssignmentSheets do
  @moduledoc """
  The assignments workbook in Google Sheets (docs/design/assignments-sheets.md):
  writes the Assignments, Positions and History tabs of the user's own
  spreadsheet through the Sheets API the user's token, and reads
  the Assignments tab back for `App.People.AssignmentSync.plan/2`.

  Values are written RAW (never as formulas or locale-parsed dates). The
  Assignments tab is laid out by the caller (SHEETS-UI,
  docs/design/sheets-ui.md, `AppWeb.SheetLayout`): its rows and the
  formatting requests come in `layout`; Positions and History get widths
  and a frozen header here. Tabs are created when missing and cleared
  before writing; earlier formatting of the Assignments tab is replaced.

  The laid-out tab has two header rows (keys, hidden; labels, marked in a
  hidden column): `read/2` drops the label row and says on which sheet row
  the data starts. A tab written before SHEETS-UI (one header row) reads
  as before.
  """
  alias App.Google.{LaidOutTab, Sheets}

  @tab "Assignments"
  @tabs ["Assignments", "Positions", "History"]

  @typedoc """
  The Assignments tab as laid out: `rows` (key row, label row, data) and
  `requests`, a function from the tab's details (`Sheets.sheet_details/2`)
  to the formatting requests.
  """
  @type layout :: %{rows: [[term()]], requests: (map() -> [map()])}

  @doc "Writes the export (`App.People.AssignmentSync.export/1`) into the spreadsheet."
  @spec write(String.t(), String.t(), map(), layout()) :: :ok | {:error, term()}
  def write(token, spreadsheet_id, export, layout) do
    with {:ok, ids} <- ensure_tabs(token, spreadsheet_id),
         :ok <- write_tab(token, spreadsheet_id, "Assignments", layout.rows),
         :ok <- write_tab(token, spreadsheet_id, "Positions", export.positions),
         :ok <- write_tab(token, spreadsheet_id, "History", export.history),
         {:ok, details} <- Sheets.sheet_details(token, spreadsheet_id),
         assignments = Enum.find(details, &(&1["properties"]["sheetId"] == ids["Assignments"])),
         {:ok, _} <-
           Sheets.batch_update(
             token,
             spreadsheet_id,
             layout.requests.(assignments) ++ formatting(ids)
           ) do
      :ok
    end
  end

  @doc """
  The Assignments tab's rows (the key row first, without the label row)
  and the sheet row the first data row is on.
  """
  @spec read(String.t(), String.t()) :: {:ok, [[String.t()]], pos_integer()} | {:error, term()}
  def read(token, spreadsheet_id) do
    with {:ok, rows, first_row, _dataset} <- LaidOutTab.read(token, spreadsheet_id, @tab) do
      {:ok, rows, first_row}
    end
  end

  @doc "The key row and sheet row `n` of the Assignments tab (for the row form)."
  @spec read_row(String.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()], [String.t()]} | {:error, term()}
  def read_row(token, spreadsheet_id, n) do
    with {:ok, keys, _dataset} <- LaidOutTab.head(token, spreadsheet_id, @tab),
         {:ok, row} <- LaidOutTab.read_row(token, spreadsheet_id, @tab, n) do
      {:ok, keys, row}
    end
  end

  @doc "Writes `values` (RAW) into sheet row `n` from column `from` (a letter)."
  @spec write_row(String.t(), String.t(), pos_integer(), String.t(), [term()]) ::
          :ok | {:error, term()}
  def write_row(token, spreadsheet_id, n, from, values),
    do: LaidOutTab.write_row(token, spreadsheet_id, @tab, n, from, values)

  @doc """
  Writes the Status column (SHEETS-UI.8, `AppWeb.SheetStatus`) of rows
  `first_row..last_row`: `statuses` is `%{row => text}`, other rows are
  cleared. `keys` is the key row; a tab without a Status column is left
  as it is.
  """
  @spec write_statuses(
          String.t(),
          String.t(),
          [String.t()],
          Range.t(),
          %{pos_integer() => String.t()}
        ) :: :ok | {:error, term()}
  def write_statuses(token, spreadsheet_id, keys, range, statuses),
    do: LaidOutTab.write_statuses(token, spreadsheet_id, @tab, keys, range, statuses)

  defp ensure_tabs(token, spreadsheet_id) do
    with {:ok, sheets} <- Sheets.sheets(token, spreadsheet_id) do
      existing = Map.new(sheets, &{&1["title"], &1["sheetId"]})

      case Enum.reject(@tabs, &Map.has_key?(existing, &1)) do
        [] -> {:ok, existing}
        missing -> add_tabs(token, spreadsheet_id, missing, existing)
      end
    end
  end

  defp add_tabs(token, spreadsheet_id, titles, existing) do
    requests = Enum.map(titles, &%{addSheet: %{properties: %{title: &1}}})

    with {:ok, %{"replies" => replies}} <- Sheets.batch_update(token, spreadsheet_id, requests) do
      added =
        Map.new(
          replies,
          &{&1["addSheet"]["properties"]["title"], &1["addSheet"]["properties"]["sheetId"]}
        )

      {:ok, Map.merge(existing, added)}
    end
  end

  defp write_tab(token, spreadsheet_id, tab, rows) do
    with {:ok, _} <- Sheets.clear_values(token, spreadsheet_id, "#{tab}!A:Z"),
         {:ok, _} <- Sheets.update_values(token, spreadsheet_id, "#{tab}!A1", rows, raw: true) do
      :ok
    end
  end

  # Column widths in pixels for the reference tabs (Google's default of
  # 100 cuts names and labels off).
  @widths %{
    "Positions" => [300, 220, 220, 70, 80],
    "History" => [140, 220, 300, 220, 100, 100]
  }

  defp formatting(ids) do
    widths =
      for {tab, widths} <- @widths, {px, col} <- Enum.with_index(widths) do
        %{
          updateDimensionProperties: %{
            range: %{sheetId: ids[tab], dimension: "COLUMNS", startIndex: col, endIndex: col + 1},
            properties: %{pixelSize: px},
            fields: "pixelSize"
          }
        }
      end

    frozen =
      for tab <- ["Positions", "History"] do
        %{
          updateSheetProperties: %{
            properties: %{sheetId: ids[tab], gridProperties: %{frozenRowCount: 1}},
            fields: "gridProperties.frozenRowCount"
          }
        }
      end

    widths ++ frozen
  end
end
