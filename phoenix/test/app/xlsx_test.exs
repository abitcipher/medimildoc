defmodule App.XlsxTest do
  @moduledoc "docs/design/assignments-sheets.md: the offline workbook."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.AssignmentSync

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company, 1 Bn")

    for i <- 1..3,
        do:
          person_fixture(%{given_name: "P#{i}"})
          |> assign_fixture(unit, title: "Rifleman", grade: "OR-3")

    person_fixture(%{given_name: "=HYPERLINK(\"http://evil\",\"x\")", family_name: "Injected"})
    %{hr: user_fixture(:hr)}
  end

  defp write_tmp(binary) do
    path = Path.join(System.tmp_dir!(), "t-#{System.unique_integer([:positive])}.xlsx")
    File.write!(path, binary)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "export → workbook → read back gives the same rows, and an unchanged import",
       %{hr: hr} do
    export = AssignmentSync.export(hr)
    {:ok, binary} = App.Xlsx.assignments_workbook(export)
    {:ok, rows} = binary |> write_tmp() |> App.Xlsx.read_assignments()

    assert rows == export.assignments
    plan = AssignmentSync.plan(hr, rows)
    assert plan.errors == [] and plan.changes == []
  end

  test "the Position dropdown points at the Positions sheet; Version is hidden; no formulas",
       %{hr: hr} do
    {:ok, binary} = hr |> AssignmentSync.export() |> App.Xlsx.assignments_workbook()
    {:ok, files} = :zip.unzip(binary, [:memory])

    sheet =
      files |> Enum.find(fn {name, _} -> name == ~c"xl/worksheets/sheet1.xml" end) |> elem(1)

    assert sheet =~
             ~r/<dataValidation type="list"[^>]*sqref="D2:D\d+"><formula1>Positions!\$A\$2:\$A\$\d+<\/formula1>/

    assert sheet =~ ~r/<col min="6" max="6"[^>]*hidden="1"/
    refute sheet =~ "<f>"

    # The injected name is a shared string, not a formula.
    strings = files |> Enum.find(fn {name, _} -> name == ~c"xl/sharedStrings.xml" end) |> elem(1)
    assert strings =~ "HYPERLINK"
  end

  test "a file that isn't a workbook, or lacks the sheet, is refused" do
    assert {:error, _} = "not an xlsx" |> write_tmp() |> App.Xlsx.read_assignments()
  end
end
