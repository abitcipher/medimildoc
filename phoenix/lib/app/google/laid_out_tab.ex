defmodule App.Google.LaidOutTab do
  @moduledoc """
  One spreadsheet tab laid out by SHEETS-UI (docs/design/sheets-ui.md),
  through the Sheets API with the user's own token : row 1 holds
  the column keys (hidden), row 2 the labels, marked by `#labels <dataset>`
  in a hidden column, so the tab itself says what it holds — whatever the
  user renamed it to. Data starts on row 3.

  Values are written RAW (never formulas or locale-parsed dates). A tab
  written before the label row (one header row) still reads: data from
  row 2, no dataset.
  """
  alias App.Google.Sheets

  @marker "#labels"

  @doc "What marks the label row; followed by a space and the dataset id."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "A range on `tab`, the title quoted when it isn't a plain word."
  @spec range(String.t(), String.t()) :: String.t()
  def range(tab, a1) do
    if tab =~ ~r/^[A-Za-z0-9_]+$/,
      do: "#{tab}!#{a1}",
      else: "'#{String.replace(tab, "'", "''")}'!#{a1}"
  end

  @doc """
  Writes `rows` into `tab` (created when missing, cleared first), then the
  formatting `requests.(tab_details)` (`Sheets.sheet_details/2`'s entry
  for the tab). Returns the tab's sheet id.
  """
  @spec write(String.t(), String.t(), String.t(), [[term()]], (map() -> [map()])) ::
          {:ok, integer()} | {:error, term()}
  def write(token, ssid, tab, rows, requests) do
    with {:ok, id} <- ensure(token, ssid, tab),
         {:ok, _} <- Sheets.clear_values(token, ssid, range(tab, "A:ZZ")),
         {:ok, _} <- Sheets.update_values(token, ssid, range(tab, "A1"), rows, raw: true),
         {:ok, details} <- Sheets.sheet_details(token, ssid),
         sheet = Enum.find(details, &(&1["properties"]["sheetId"] == id)),
         {:ok, _} <- Sheets.batch_update(token, ssid, requests.(sheet)) do
      {:ok, id}
    end
  end

  @doc "The sheet id of `tab`, adding the tab when missing."
  @spec ensure(String.t(), String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def ensure(token, ssid, tab) do
    with {:ok, sheets} <- Sheets.sheets(token, ssid) do
      case Enum.find(sheets, &(&1["title"] == tab)) do
        %{"sheetId" => id} -> {:ok, id}
        nil -> add(token, ssid, tab)
      end
    end
  end

  defp add(token, ssid, tab) do
    with {:ok, %{"replies" => [reply]}} <-
           Sheets.batch_update(token, ssid, [%{addSheet: %{properties: %{title: tab}}}]) do
      {:ok, reply["addSheet"]["properties"]["sheetId"]}
    end
  end

  @doc """
  The tab's rows: the key row first and the data (without the label
  row), the sheet row the data starts on, and the dataset the label row
  names (nil without one).
  """
  @spec read(String.t(), String.t(), String.t()) ::
          {:ok, [[String.t()]], pos_integer(), String.t() | nil} | {:error, term()}
  def read(token, ssid, tab) do
    with {:ok, rows} <- Sheets.get_values(token, ssid, range(tab, "A1:ZZ")) do
      split(rows)
    end
  end

  # Without its label row: the data from row 3; otherwise from row 2.
  defp split([keys, labels | data] = rows) do
    case dataset(labels) do
      {:ok, dataset} -> {:ok, [keys | data], 3, dataset}
      :none -> {:ok, rows, 2, nil}
    end
  end

  defp split(rows), do: {:ok, rows, 2, nil}

  @doc "The key row and the dataset of `tab` (rows 1 and 2 only)."
  @spec head(String.t(), String.t(), String.t()) ::
          {:ok, [String.t()], String.t() | nil} | {:error, term()}
  def head(token, ssid, tab) do
    with {:ok, rows} <- Sheets.get_values(token, ssid, range(tab, "A1:ZZ2")) do
      case split(rows) do
        {:ok, [keys | _], _first_row, dataset} -> {:ok, keys, dataset}
        {:ok, [], _first_row, nil} -> {:ok, [], nil}
      end
    end
  end

  @doc """
  The options the tab was written with (`"#labels people unit=<id>"` →
  `%{"unit" => id}`, SHEETS-UI.17): exporting the tab again keeps them.
  `%{}` without a marker or a tab.
  """
  @spec view(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def view(token, ssid, tab) do
    with {:ok, rows} <- Sheets.get_values(token, ssid, range(tab, "A2:ZZ2")) do
      {:ok, rows |> List.first([]) |> marker_options()}
    end
  end

  # "#labels people unit=…" → "people"; "#labels" alone (the first
  # Assignments tabs) → "assignments".
  defp dataset(labels) do
    Enum.find_value(labels, :none, fn
      @marker -> {:ok, "assignments"}
      @marker <> " " <> rest -> {:ok, rest |> String.split(" ") |> hd()}
      _ -> nil
    end)
  end

  defp marker_options(labels) do
    Enum.find_value(labels, %{}, fn
      @marker <> " " <> rest ->
        rest
        |> String.split(" ")
        |> tl()
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.filter(&match?([_, _], &1))
        |> Map.new(fn [key, value] -> {key, value} end)

      _ ->
        nil
    end)
  end

  @doc """
  The first sheet row of `tab` whose `key` column holds `value` (after
  the two header rows), or nil.
  """
  @spec find_row(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def find_row(token, ssid, tab, key, value) do
    with {:ok, keys, _dataset} <- head(token, ssid, tab) do
      case Enum.find_index(keys, &(&1 == key)) do
        nil -> {:ok, nil}
        i -> find_in_column(token, ssid, tab, Sheets.column_letter(i), value)
      end
    end
  end

  defp find_in_column(token, ssid, tab, col, value) do
    with {:ok, rows} <- Sheets.get_values(token, ssid, range(tab, "#{col}3:#{col}")) do
      {:ok,
       Enum.find_value(Enum.with_index(rows, 3), fn {row, n} ->
         if List.first(row) == value, do: n
       end)}
    end
  end

  @doc "Sheet row `n` of `tab`."
  @spec read_row(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def read_row(token, ssid, tab, n) do
    with {:ok, rows} <- Sheets.get_values(token, ssid, range(tab, "A#{n}:ZZ#{n}")) do
      {:ok, List.first(rows) || []}
    end
  end

  @doc "Writes `values` (RAW) into sheet row `n` of `tab` from column `from` (a letter)."
  @spec write_row(String.t(), String.t(), String.t(), pos_integer(), String.t(), [term()]) ::
          :ok | {:error, term()}
  def write_row(token, ssid, tab, n, from, values) do
    case Sheets.update_values(token, ssid, range(tab, "#{from}#{n}"), [values], raw: true) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Writes `values` as a new row after the last one of `tab`; returns its row number."
  @spec append_row(String.t(), String.t(), String.t(), [term()]) ::
          {:ok, pos_integer()} | {:error, term()}
  def append_row(token, ssid, tab, values) do
    with {:ok, column} <- Sheets.get_values(token, ssid, range(tab, "A:A")),
         n = max(length(column) + 1, 3),
         :ok <- write_row(token, ssid, tab, n, "A", values) do
      {:ok, n}
    end
  end

  @doc """
  Writes the Status column of rows `first..last`: `statuses` is `%{row =>
  text}`, other rows are cleared. A tab without a Status key is left as
  it is.
  """
  @spec write_statuses(
          String.t(),
          String.t(),
          String.t(),
          [String.t()],
          Range.t(),
          %{pos_integer() => String.t()}
        ) :: :ok | {:error, term()}
  def write_statuses(token, ssid, tab, keys, first..last//_, statuses) do
    case Enum.find_index(keys, &(&1 == "Status")) do
      i when is_integer(i) and last >= first ->
        col = Sheets.column_letter(i)
        values = for n <- first..last, do: [Map.get(statuses, n, "")]

        case Sheets.update_values(token, ssid, range(tab, "#{col}#{first}:#{col}#{last}"), values,
               raw: true
             ) do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end
end
