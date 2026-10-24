defmodule AppWeb.SheetLayoutTest do
  @moduledoc "SHEETS-UI (docs/design/sheets-ui.md): the layout, pure."
  use ExUnit.Case, async: false

  alias App.People.SheetSync
  alias AppWeb.{SchemaText, SheetLayout}

  test "columns take label, format and help from the app's form schema" do
    columns = SheetLayout.columns("assignments")
    since = Enum.find(columns, &(&1.key == "Since"))

    assert %{label: "Start date", type: :date, help: "The first day in the post."} = since
    assert %{type: :choice, options: "Positions"} = Enum.find(columns, &(&1.key == "Position"))
    assert %{read_only?: true} = Enum.find(columns, &(&1.key == "Name"))
    # A hidden copy is typed like its source (a date stays a date).
    assert %{hidden?: true, type: :date} = Enum.find(columns, &(&1.key == "ExportedSince"))
  end

  test "labels follow the user's language" do
    Gettext.put_locale(AppWeb.Gettext, "uk")
    on_exit(fn -> Gettext.put_locale(AppWeb.Gettext, "en") end)

    labels = Enum.map(SheetLayout.columns("assignments"), & &1.label)
    assert "Посада" in labels
    refute "Start date" in labels
  end

  test "rows: keys, labels, then data with real dates and copies" do
    export = [
      ["PersonID", "Name", "Unit", "Position", "Since", "Version"],
      ["AAAA", "Ann", "A Co", "Rifleman", "02.11.2026", "v1"],
      ["BBBB", "Bo", "", "", "", ""]
    ]

    [keys, labels, ann, bo] = SheetLayout.rows("assignments", export)
    assert List.last(keys) == "ExportedSince"
    # The Status column (filled by the app) comes before the hidden ones.
    assert Enum.at(labels, 5) == "Status"
    assert Enum.at(labels, 6) == SheetLayout.marker("assignments")
    serial = Date.diff(~D[2026-11-02], ~D[1899-12-30])
    assert ann == ["AAAA", "Ann", "A Co", "Rifleman", serial, "", "v1", "Rifleman", serial]
    assert bo == ["BBBB", "Bo", "", "", "", "", "", "", ""]
  end

  test "a record kind's tab: choices as their labels, yes/no as checkboxes, back again" do
    id = "record:family_status"
    columns = SheetLayout.columns(id)
    status = Enum.find(columns, &(&1.key == "maritalStatus"))
    assert status.type == :enum
    assert %{hidden?: true} = Enum.find(columns, &(&1.key == "RecordID"))
    assert %{read_only?: false} = Enum.find(columns, &(&1.key == "PersonID"))

    header = SheetSync.header(id)
    values = Enum.map(header, fn key -> if key == "maritalStatus", do: "married", else: "" end)
    [keys, _labels, row] = SheetLayout.rows(id, [header, values])
    label = Enum.at(row, Enum.find_index(keys, &(&1 == "maritalStatus")))
    assert label == SchemaText.choice("married", status.field["x-enum-labels"])

    # Read back: the label stands for the stored value again.
    [_keys, back] = SheetLayout.unlabel(id, [keys, row])
    assert Enum.at(back, Enum.find_index(keys, &(&1 == "maritalStatus"))) == "married"

    language = SheetLayout.columns("record:language_proficiency")
    assert %{type: :boolean} = Enum.find(language, &(&1.key == "preferred"))
    assert SheetLayout.cell(Enum.find(language, &(&1.key == "preferred")), "true") == true
    assert SheetLayout.cell(Enum.find(language, &(&1.key == "listening")), "3") == 3

    # A checkbox is "changed" only by its value: unticked = unset.
    requests =
      SheetLayout.requests("record:language_proficiency", %{"properties" => %{"sheetId" => 1}},
        rows: 1
      )

    formulas =
      for %{addConditionalFormatRule: %{rule: rule}} <- requests,
          %{userEnteredValue: v} <- rule.booleanRule.condition[:values] || [],
          do: v

    assert Enum.any?(formulas, &String.starts_with?(&1, "=N("))
  end

  test "the form's side-by-side fields become a column group, replaced on rewrite (SHEETS-UI.4)" do
    id = "record:leave"
    keys = Enum.map(SheetLayout.columns(id), & &1.key)
    [group] = SheetLayout.groups(id)
    assert Enum.slice(keys, group.from..group.to) == ["startDate", "endDate"]

    sheet = %{
      "properties" => %{"sheetId" => 5},
      "columnGroups" => [%{"range" => %{"sheetId" => 5, "dimension" => "COLUMNS"}, "depth" => 1}]
    }

    requests = SheetLayout.requests(id, sheet, rows: 1)
    assert Enum.any?(requests, &Map.has_key?(&1, :deleteDimensionGroup))

    assert %{addDimensionGroup: %{range: %{startIndex: from, endIndex: to}}} =
             Enum.find(requests, &Map.has_key?(&1, :addDimensionGroup))

    assert {from, to} == {group.from, group.to + 1}
    assert SheetLayout.groups("people") == []
  end

  test "every column's visibility is set, so an older layout's hidden column comes back" do
    requests = SheetLayout.requests("assignments", %{"properties" => %{"sheetId" => 1}}, rows: 1)

    shown =
      for %{
            updateDimensionProperties: %{
              range: %{dimension: "COLUMNS", startIndex: i},
              properties: %{hiddenByUser: false}
            }
          } <- requests,
          do: i

    status = Enum.find_index(SheetLayout.columns("assignments"), &(&1.key == "Status"))
    assert status in shown
  end

  test "column letters" do
    assert Enum.map([0, 7, 25, 26, 27, 51, 52], &SheetLayout.letter/1) ==
             ~w(A H Z AA AB AZ BA)
  end
end
