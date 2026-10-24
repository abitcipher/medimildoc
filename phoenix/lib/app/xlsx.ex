defmodule App.Xlsx do
  @moduledoc """
  Offline workbooks (.xlsx) for assignments (docs/design/assignments-sheets.md),
  with UmyaSpreadsheet (MIT, Rust NIF, precompiled).

  UmyaSpreadsheet 0.7 can't do two things the workbook needs, so after it
  writes the file, the Assignments sheet's XML is patched (a documented,
  narrow rewrite of what it wrote):

  - **The Position dropdown refers to the Positions sheet's range.**
    UmyaSpreadsheet only writes inline lists (`"a,b,c"`), which Excel caps
    at 255 characters — a few dozen post labels already exceed it and Excel
    reports the file as damaged. A placeholder list is written and its
    formula replaced with `Positions!$A$2:$A$n`.
  - **The Version column is hidden** (`hidden="1"` on its `<col>`).

  Values are written as text; UmyaSpreadsheet stores a value starting with
  `=` as a string, never a formula (checked), so exported names can't turn
  into formulas. It does store digit-only text as a number; nothing
  exported is digit-only.
  """

  @assignments "Assignments"
  @positions "Positions"
  @history "History"
  @placeholder "__POSITIONS__"
  @blank_rows_to_stop 20

  @doc """
  The workbook for `App.People.AssignmentSync.export/1` output, as a binary.
  """
  @spec assignments_workbook(%{assignments: list(), positions: list(), history: list()}) ::
          {:ok, binary()} | {:error, term()}
  def assignments_workbook(%{assignments: assignments, positions: positions, history: history}) do
    path = Path.join(System.tmp_dir!(), "assignments-#{System.unique_integer([:positive])}.xlsx")

    try do
      {:ok, book} = UmyaSpreadsheet.new()
      :ok = UmyaSpreadsheet.rename_sheet(book, "Sheet1", @assignments)
      :ok = UmyaSpreadsheet.add_sheet(book, @positions)
      :ok = UmyaSpreadsheet.add_sheet(book, @history)

      # Version (F) gets its own width: columns of equal width are written
      # as one <col> range, and the patch below hides F's own element.
      write_rows(book, @assignments, assignments, [14, 28, 24, 34, 12, 10])
      write_rows(book, @positions, positions, [34, 24, 24, 8, 9])
      write_rows(book, @history, history, [14, 28, 34, 24, 12, 12])

      rows = max(length(assignments), 2) + 200

      :ok =
        UmyaSpreadsheet.add_list_validation(
          book,
          @assignments,
          "D2:D#{rows}",
          [@placeholder],
          true,
          "Unknown position",
          "Choose a position from the list (sheet Positions).",
          nil,
          nil
        )

      :ok = UmyaSpreadsheet.write(book, path)
      patch(File.read!(path), length(positions))
    after
      File.rm(path)
    end
  end

  @doc """
  A one-sheet workbook of `rows` (the first is the header, bold), as a
  binary — e.g. a register for a year (docs/design/registers-file-plan.md).
  """
  @spec table_workbook(String.t(), [[term()]], [number()]) :: {:ok, binary()}
  def table_workbook(sheet, rows, widths) do
    path = Path.join(System.tmp_dir!(), "table-#{System.unique_integer([:positive])}.xlsx")

    try do
      {:ok, book} = UmyaSpreadsheet.new()
      :ok = UmyaSpreadsheet.rename_sheet(book, "Sheet1", sheet)
      write_rows(book, sheet, rows, widths)
      :ok = UmyaSpreadsheet.write(book, path)
      {:ok, File.read!(path)}
    after
      File.rm(path)
    end
  end

  defp write_rows(book, sheet, rows, widths) do
    for {row, r} <- Enum.with_index(rows, 1), {value, c} <- Enum.with_index(row) do
      :ok = UmyaSpreadsheet.set_cell_value(book, sheet, "#{column(c)}#{r}", to_string(value))
      if r == 1, do: UmyaSpreadsheet.set_font_bold(book, sheet, "#{column(c)}1", true)
    end

    for {width, c} <- Enum.with_index(widths),
        do: UmyaSpreadsheet.set_column_width(book, sheet, column(c), width * 1.0)

    # No frozen header: UmyaSpreadsheet 0.7 writes the pane as
    # activePane="TopRight", which the spec (and strict readers such as
    # openpyxl, likely Excel) reject — the spec's value is "topRight".
    :ok
  end

  # Rewrites the Assignments sheet (the first worksheet) as described above.
  defp patch(xlsx, position_rows) do
    {:ok, files} = :zip.unzip(xlsx, [:memory])
    last = max(position_rows, 2)

    dropdown = "<formula1>&quot;#{@placeholder}&quot;</formula1>"
    version_col = ~r/(<col min="6" max="6"[^>]*?)(\/>)/

    {sheet_name, xml} = Enum.find(files, fn {name, _} -> name == ~c"xl/worksheets/sheet1.xml" end)

    # Both edits must apply; a new UmyaSpreadsheet writing differently must
    # fail here, not produce a workbook without its dropdown.
    if not String.contains?(xml, dropdown) or not Regex.match?(version_col, xml) do
      raise "unexpected Assignments sheet XML from UmyaSpreadsheet; update App.Xlsx.patch/2"
    end

    patched =
      xml
      |> String.replace(dropdown, "<formula1>#{@positions}!$A$2:$A$#{last}</formula1>")
      |> String.replace(version_col, "\\1 hidden=\"1\"\\2")

    files = List.keystore(files, sheet_name, 0, {sheet_name, patched})

    case :zip.create(~c"assignments.xlsx", files, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      error -> error
    end
  end

  @doc """
  The rows of the Assignments sheet of an uploaded workbook (strings; the
  header row first), read until #{@blank_rows_to_stop} empty rows in a row.
  """
  @spec read_assignments(Path.t()) ::
          {:ok, [[String.t()]]} | {:error, :unreadable | :no_assignments_sheet}
  def read_assignments(path) do
    with {:ok, book} <- open(path),
         true <-
           @assignments in UmyaSpreadsheet.get_sheet_names(book) ||
             {:error, :no_assignments_sheet} do
      header =
        read_row(book, 1, 26) |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

      {:ok, [header | read_body(book, 2, length(header), [], 0)]}
    end
  end

  defp open(path) do
    case UmyaSpreadsheet.read(path) do
      {:ok, book} -> {:ok, book}
      _ -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  defp read_body(_book, _r, _width, acc, blanks) when blanks >= @blank_rows_to_stop,
    do: acc |> Enum.reverse() |> Enum.drop(-blanks)

  defp read_body(book, r, width, acc, blanks) do
    row = read_row(book, r, width)
    blank? = Enum.all?(row, &(&1 == ""))
    read_body(book, r + 1, width, [row | acc], if(blank?, do: blanks + 1, else: 0))
  end

  defp read_row(book, r, width) do
    for c <- 0..(width - 1)//1 do
      case UmyaSpreadsheet.get_cell_value(book, @assignments, "#{column(c)}#{r}") do
        {:ok, value} -> value
        _ -> ""
      end
    end
  end

  # 0 -> "A" … 25 -> "Z" (the sheets here never go past Z).
  defp column(index), do: <<?A + index>>
end
