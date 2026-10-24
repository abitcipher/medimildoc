defmodule AppWeb.SheetTabs do
  @moduledoc """
  SHEETS-UI (docs/design/sheets-ui.md): export, check and carry out a
  laid-out tab of any dataset — the sidebar's components call this, the
  rules are in the sync modules (`App.People.AssignmentSync` for
  assignments, `App.People.SheetSync` for people and record kinds) and the
  look in `AppWeb.SheetLayout`.

  After Carry out:

  - **assignments**: the tab is written again from the database (posts
    change only when the draft orders are signed, an old sheet left in
    place would undo or overlap what was done), each row's Status found
    again by PersonID;
  - **people and records**: only the rows carried out are written again
    from the database, every row gets its Status — rows that failed keep
    what the user typed. One request (`values:batchUpdate`).
  """
  alias App.Google.{AssignmentSheets, LaidOutTab, Sheets}
  alias App.People.{AssignmentSync, SheetSync}
  alias AppWeb.{SheetLayout, SheetStatus}

  @typedoc """
  What a check read: the key row, the data rows and where they start, and
  the unit the tab was exported for.
  """
  @type read :: %{
          required(:tab) => String.t(),
          required(:keys) => [String.t()],
          required(:data) => [[term()]],
          required(:first_row) => non_neg_integer(),
          optional(:unit) => String.t() | nil
        }

  @doc """
  Writes `dataset` into its tab. Options: `unit` — only people posted in
  that organization or below (SHEETS-UI.17, kept in the tab's marker);
  `statuses` (`%{key => text}`) fill the Status column.
  """
  @spec export(String.t(), String.t(), map(), String.t(), keyword()) :: :ok | {:error, term()}
  def export(token, ssid, actor, dataset, opts \\ [])

  def export(token, ssid, actor, "assignments", opts) do
    statuses = Keyword.get(opts, :statuses, %{})
    export = AssignmentSync.export(actor, unit: opts[:unit])
    [header | data] = export.assignments

    assignments = [
      header ++ ["Status"] | Enum.map(data, &(&1 ++ [Map.get(statuses, hd(&1), "")]))
    ]

    layout = %{
      rows: SheetLayout.rows("assignments", assignments, unit: opts[:unit]),
      requests:
        &SheetLayout.requests("assignments", &1,
          rows: length(data),
          options: %{"Positions" => length(export.positions)}
        )
    }

    AssignmentSheets.write(token, ssid, export, layout)
  end

  def export(token, ssid, actor, dataset, opts) do
    [_header | data] = rows = SheetSync.export(actor, dataset, unit: opts[:unit])

    case LaidOutTab.write(
           token,
           ssid,
           SheetLayout.tab(dataset),
           SheetLayout.rows(dataset, rows, unit: opts[:unit]),
           &SheetLayout.requests(dataset, &1, rows: length(data))
         ) do
      {:ok, _id} -> :ok
      error -> error
    end
  end

  @doc """
  Reads the dataset's tab, plans it (nothing written to the app) and
  writes each row's finding into the Status column.
  """
  @spec check(String.t(), String.t(), map(), String.t()) ::
          {:ok, map(), read()} | {:error, term()}
  def check(token, ssid, actor, dataset) do
    tab = SheetLayout.tab(dataset)

    with {:ok, [keys | data] = rows, first_row, found} <- LaidOutTab.read(token, ssid, tab),
         :ok <- same_dataset(found, dataset),
         {:ok, view} <- LaidOutTab.view(token, ssid, tab),
         plan = plan(actor, dataset, rows, first_row),
         range = first_row..(first_row + length(data) - 1)//1,
         :ok <-
           LaidOutTab.write_statuses(token, ssid, tab, keys, range, SheetStatus.for_plan(plan)) do
      {:ok, plan, %{tab: tab, keys: keys, data: data, first_row: first_row, unit: view["unit"]}}
    else
      {:ok, [], _first_row, _found} -> {:error, :empty}
      error -> error
    end
  end

  defp same_dataset(nil, _dataset), do: :ok
  defp same_dataset(dataset, dataset), do: :ok
  defp same_dataset(found, _dataset), do: {:error, {:other_dataset, found}}

  @doc """
  Plans rows of `dataset` read from a sheet (the key row first), the
  first data row being sheet row `first_row` (0 for a row not in the sheet
  yet: the sidebar's New form).
  """
  @spec plan(map(), String.t(), [[term()]], non_neg_integer()) :: map()
  def plan(actor, "assignments", rows, first_row),
    do: AssignmentSync.plan(actor, rows, Date.utc_today(), first_row: first_row)

  def plan(actor, dataset, rows, first_row),
    do: SheetSync.plan(actor, dataset, SheetLayout.unlabel(dataset, rows), first_row: first_row)

  @doc """
  Carries out a checked plan and writes the result back into the sheet
  (see the module doc). Returns the result and how the write-back went.
  """
  @spec carry_out(String.t(), String.t(), map(), String.t(), map(), read()) ::
          {map(), :ok | {:error, term()}}
  def carry_out(token, ssid, actor, "assignments", plan, read) do
    result = AssignmentSync.apply(actor, plan)

    statuses =
      plan |> SheetStatus.for_result(result) |> SheetStatus.by_person(codes(read, "PersonID"))

    {result, export(token, ssid, actor, "assignments", statuses: statuses, unit: read[:unit])}
  end

  def carry_out(token, ssid, actor, dataset, plan, read) do
    result = SheetSync.apply(actor, plan)
    {result, write_back(token, ssid, actor, dataset, plan, result, read)}
  end

  # The rows carried out, again from the database with their Status; the
  # Status of every other row the plan has a word for.
  defp write_back(token, ssid, actor, dataset, plan, result, read) do
    statuses = SheetStatus.for_result(plan, result)
    [header | rows] = SheetSync.export(actor, dataset)
    key_index = Enum.find_index(header, &(&1 == SheetSync.key_column(dataset)))
    by_key = Map.new(rows, &{Enum.at(&1, key_index), &1})
    status_col = Enum.find_index(read.keys, &(&1 == "Status"))

    data =
      for {n, text} <- statuses,
          entry = written(dataset, header, by_key, result.outcomes[n], text),
          entry != nil or status_col != nil do
        case entry do
          nil -> {LaidOutTab.range(read.tab, "#{Sheets.column_letter(status_col)}#{n}"), [[text]]}
          cells -> {LaidOutTab.range(read.tab, "A#{n}"), [cells]}
        end
      end

    case Sheets.batch_update_values(token, ssid, data) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp written(dataset, header, by_key, outcome, text) do
    key =
      case outcome do
        {:created, _id, key} -> key
        {:updated, key} -> key
        _ -> nil
      end

    case key && by_key[key] do
      nil -> nil
      values -> SheetLayout.row(dataset, header ++ ["Status"], values ++ [text])
    end
  end

  @doc """
  Appends the row saved in the app under `key` (PersonID or RecordID) to
  `tab`, as the database has it, with its Status. Returns the sheet row.
  """
  @spec append_saved(String.t(), String.t(), map(), String.t(), String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def append_saved(token, ssid, actor, dataset, tab, key) do
    [header | rows] = SheetSync.export(actor, dataset)
    i = Enum.find_index(header, &(&1 == SheetSync.key_column(dataset)))

    case Enum.find(rows, &(Enum.at(&1, i) == key)) do
      nil ->
        {:error, :not_found}

      values ->
        status = "✓ " <> Gettext.gettext(AppWeb.Gettext, "Added to the app")
        cells = SheetLayout.row(dataset, header ++ ["Status"], values ++ [status])
        LaidOutTab.append_row(token, ssid, tab, cells)
    end
  end

  @doc "`%{sheet row => value of column key}` of the rows read."
  @spec codes(read(), String.t()) :: %{pos_integer() => String.t()}
  def codes(%{keys: keys, data: data, first_row: first_row}, key) do
    case Enum.find_index(keys, &(&1 == key)) do
      nil ->
        %{}

      i ->
        data
        |> Enum.with_index(first_row)
        |> Map.new(fn {row, n} -> {n, row |> Enum.at(i, "") |> to_string() |> String.trim()} end)
    end
  end
end
