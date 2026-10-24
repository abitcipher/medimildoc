defmodule AppWeb.SheetsDataTest do
  @moduledoc """
  SHEETS-UI stage 2 (docs/design/sheets-ui.md): people and record kinds
  in the sidebar's Data tab, against an in-memory spreadsheet
  (`App.FakeSheets`).
  """
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import App.SheetsTokenFixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  alias App.FakeSheets
  alias App.People.{Person, PersonId, PersonRecord}

  @language "record:language_proficiency"

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company, 1 Bn")

    ann =
      person_fixture(%{given_name: "Ann", family_name: "Able", email: "ann@example.test"})
      |> assign_fixture(unit, title: "Rifleman", grade: "OR-3")

    bob = person_fixture(%{given_name: "Bob", family_name: "Baker"})
    record = record_fixture(ann, :language_proficiency)
    Ash.Seed.seed!(App.Accounts.User, %{email: "hr@example.com", role: :hr})

    conn =
      put_connect_params(conn, %{
        "sheets_token" => sheets_token(sub: "hr@example.com", ssid: "ss-1"),
        "google_access_token" => "google-token",
        "sheet_name" => "Sheet1"
      })

    %{conn: conn, fake: FakeSheets.start("ss-1"), ann: ann, bob: bob, record: record}
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/sheets")
    render_async(view)
    view
  end

  defp pick(view, dataset),
    do: view |> form("#dataset-form", %{"dataset" => dataset}) |> render_change()

  # Sets cells of the row whose `key` column holds `value`.
  defp edit(fake, tab, {key, value}, changes) do
    [keys | _] = rows = FakeSheets.rows(fake, tab)
    col = fn name -> Enum.find_index(keys, &(&1 == name)) end

    set = fn row ->
      Enum.reduce(changes, pad(row, keys), fn {k, v}, acc -> List.replace_at(acc, col.(k), v) end)
    end

    rows = Enum.map(rows, &if(Enum.at(&1, col.(key)) == value, do: set.(&1), else: &1))

    FakeSheets.put(fake, tab, rows)
  end

  defp pad(row, keys), do: row ++ List.duplicate("", length(keys) - length(row))

  defp cell(fake, tab, {key, value}, column) do
    [keys | rows] = FakeSheets.rows(fake, tab)
    col = fn name -> Enum.find_index(keys, &(&1 == name)) end
    row = Enum.find(rows, &(Enum.at(&1, col.(key)) == value))
    row && Enum.at(row, col.(column))
  end

  test "the picker lists what the user may open; People is laid out from the person form",
       %{conn: conn, fake: fake, ann: ann} do
    view = open(conn)

    options = view |> element("#dataset-select") |> render()
    assert options =~ ~s(value="assignments")
    assert options =~ ~s(value="people")
    assert options =~ ~s(value="#{@language}")

    pick(view, "people")
    assert has_element?(view, "#data-steps li[data-current][data-step='export']")

    html = view |> element("#step-export") |> render_click()
    assert html =~ "Written to the tab People."
    assert has_element?(view, "#data-steps li[data-current][data-step='edit']")

    [keys, labels | data] = FakeSheets.rows(fake, "People")
    assert "given_name" in keys and "Exportedgiven_name" in keys
    assert "Given name" in labels and "#labels people" in labels
    code = PersonId.format(ann.person_id)
    assert Enum.any?(data, &(hd(&1) == code))

    # The schema as the sheet's rules (SHEETS-UI.14).
    conditions =
      for %{"setDataValidation" => %{"rule" => %{"condition" => c}}} <- FakeSheets.requests(fake),
          do: c["type"]

    assert "TEXT_IS_EMAIL" in conditions and "DATE_IS_VALID" in conditions

    formulas =
      for %{"addConditionalFormatRule" => %{"rule" => rule}} <- FakeSheets.requests(fake),
          v <- get_in(rule, ["booleanRule", "condition", "values"]) || [],
          do: v["userEnteredValue"]

    # A required field left empty is red.
    assert Enum.any?(formulas, &String.starts_with?(&1, "=AND(COUNTIF("))
  end

  test "people: edit in the sheet, check, carry out; the row is written back",
       %{conn: conn, fake: fake, ann: ann} do
    view = open(conn)
    pick(view, "people")
    view |> element("#step-export") |> render_click()

    code = PersonId.format(ann.person_id)
    [_keys, _labels | data] = FakeSheets.rows(fake, "People")
    n = Enum.find_index(data, &(hd(&1) == code)) + 3
    edit(fake, "People", {"PersonID", code}, %{"given_name" => "Anna"})

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "People", "a1" => "B#{n}"})

    assert html =~ "Differs from the app: Given name"

    html = view |> element("button[id='tool-data.check']") |> render_click()
    assert html =~ "Ann Able"
    assert cell(fake, "People", {"PersonID", code}, "Status") == "→ Update: Given name"

    html = view |> element("#sheet-preview button", "Carry out") |> render_click()
    assert html =~ "1 row saved"
    assert Ash.get!(Person, ann.id, authorize?: false).given_name == "Anna"

    # Written back from the app: the copy matches, the Status says so.
    assert cell(fake, "People", {"PersonID", code}, "Exportedgiven_name") == "Anna"
    assert cell(fake, "People", {"PersonID", code}, "Status") == "✓ Saved in the app"

    # The selected row is read again after the whole tab's Carry out.
    assert render(view) =~ "Same as in the app."

    # An empty row below the data (an unticked checkbox reads FALSE there
    # in a real sheet): a hint, no form.
    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "People", "a1" => "A900"})

    assert html =~ "An empty row"
    refute has_element?(view, "#sheets-record-row-form")
  end

  test "records: a new row with a PersonID becomes a record; a failing row keeps its cells",
       %{conn: conn, fake: fake, bob: bob} do
    view = open(conn)
    pick(view, @language)
    view |> element("#step-export") |> render_click()

    [keys | _] = rows = FakeSheets.rows(fake, "Language skills")
    put = fn pairs -> Enum.map(keys, &Map.get(pairs, &1, "")) end
    bob_code = PersonId.format(bob.person_id)

    new_row =
      put.(%{
        "PersonID" => bob_code,
        "language" => "fr",
        "listening" => 2,
        "speaking" => 2,
        "reading" => 2,
        "writing" => 1
      })

    unknown = put.(%{"PersonID" => "ZZZZ-ZZZZ-ZZZZ", "language" => "de", "listening" => 1})
    FakeSheets.put(fake, "Language skills", rows ++ [new_row, unknown])

    view |> element("button[id='tool-data.check']") |> render_click()
    html = view |> element("#sheet-preview button", "Carry out") |> render_click()
    assert html =~ "1 row added to the app"

    [record] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^bob.id and kind == :language_proficiency)
      |> Ash.read!(authorize?: false)

    assert record.data["language"] == "fr"

    assert cell(fake, "Language skills", {"RecordID", record.id}, "Status") ==
             "✓ Added to the app"

    # The unknown PersonID's row is still there, with why.
    assert cell(fake, "Language skills", {"PersonID", "ZZZZ-ZZZZ-ZZZZ"}, "Status") =~
             "unknown PersonID"
  end

  test "the selected row opens as its dataset's form, with who it is about",
       %{conn: conn, fake: fake, ann: ann, record: record} do
    view = open(conn)
    pick(view, @language)
    view |> element("#step-export") |> render_click()
    pick(view, "assignments")

    [keys, _labels | data] = FakeSheets.rows(fake, "Language skills")
    id_col = Enum.find_index(keys, &(&1 == "RecordID"))
    n = Enum.find_index(data, &(Enum.at(&1, id_col) == record.id)) + 3

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "Language skills", "a1" => "B#{n}"})

    # The picker follows the tab; the form is the kind's.
    assert has_element?(view, "#dataset-select option[selected][value='#{@language}']")
    assert html =~ "Ann Able"
    assert html =~ PersonId.format(ann.person_id)
    assert html =~ "Same as in the app."
    assert has_element?(view, "#sheets-record-row-form [name='row[listening]']")

    html =
      view
      |> element("#sheets-record-row-form")
      |> render_submit(%{
        "row" => %{
          "language" => "en",
          "listening" => "4",
          "speaking" => "3",
          "reading" => "3",
          "writing" => "2"
        }
      })

    assert html =~ "Update"
    view |> element("#record-row-preview button", "Carry out") |> render_click()
    assert Ash.get!(PersonRecord, record.id, authorize?: false).data["listening"] == 4

    assert cell(fake, "Language skills", {"RecordID", record.id}, "Status") ==
             "✓ Saved in the app"

    # Below the data a checkbox cell reads FALSE: still an empty row.
    [keys | _] = rows = FakeSheets.rows(fake, "Language skills")
    below = Enum.map(keys, &if(&1 == "preferred", do: "FALSE", else: ""))
    FakeSheets.put(fake, "Language skills", rows ++ [below])

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "Language skills", "a1" => "A#{length(rows) + 1}"})

    assert html =~ "An empty row"
  end

  test "New: an empty form saved in the app is added to the sheet too",
       %{conn: conn, fake: fake, bob: bob} do
    view = open(conn)
    pick(view, @language)
    view |> element("#step-export") |> render_click()

    view |> element("button[id='tool-data.new']") |> render_click()
    assert has_element?(view, "#sheets-record-row-form input[name='person_code']")

    # The language is a picker (a hidden input set by its hook).
    view
    |> element("#sheets-record-row-form")
    |> render_change(%{
      "person_code" => PersonId.format(bob.person_id),
      "row" => %{
        "language" => "pl",
        "listening" => "1",
        "speaking" => "1",
        "reading" => "1",
        "writing" => "1"
      }
    })

    html = view |> element("#sheets-record-row-form") |> render_submit()
    assert html =~ "Saved in the app."

    [record] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^bob.id and kind == :language_proficiency)
      |> Ash.read!(authorize?: false)

    assert cell(fake, "Language skills", {"RecordID", record.id}, "language") == "pl"
  end

  test "an export for one unit only; the tab remembers it (SHEETS-UI.17)",
       %{conn: conn, fake: fake, ann: ann, bob: bob} do
    [unit] =
      App.People.Organization
      |> Ash.Query.filter(name == "A Company, 1 Bn")
      |> Ash.read!(authorize?: false)

    view = open(conn)
    pick(view, "people")
    view |> form("#dataset-form", %{"dataset" => "people", "unit" => unit.id}) |> render_change()
    view |> element("#step-export") |> render_click()

    [_keys, labels | data] = FakeSheets.rows(fake, "People")
    codes = Enum.map(data, &hd/1)
    assert PersonId.format(ann.person_id) in codes
    refute PersonId.format(bob.person_id) in codes
    assert "#labels people unit=#{unit.id}" in labels

    # Opened again: the People tab's unit is chosen again.
    view = open(conn)
    pick(view, "people")
    render_async(view)
    assert has_element?(view, "#unit-select option[selected][value='#{unit.id}']")
  end

  test "New person: a PersonID generated in advance, ↻ for another, saved with it",
       %{conn: conn, fake: fake} do
    view = open(conn)
    pick(view, "people")
    view |> element("#step-export") |> render_click()
    view |> element("button[id='tool-data.new']") |> render_click()

    first = view |> element("#sheets-record-row-new-id") |> render() |> code()
    view |> element("#sheets-record-row-regenerate") |> render_click()
    second = view |> element("#sheets-record-row-new-id") |> render() |> code()
    assert first != second

    view
    |> element("#sheets-record-row-form")
    |> render_change(%{"row" => %{"given_name" => "Nora", "family_name" => "New"}})

    html = view |> element("#sheets-record-row-form") |> render_submit()
    assert html =~ "Saved in the app."

    [nora] = Person |> Ash.Query.filter(family_name == "New") |> Ash.read!(authorize?: false)
    assert PersonId.format(nora.person_id) == second
    assert cell(fake, "People", {"PersonID", second}, "given_name") == "Nora"

    # A new row typed in the sheet without a PersonID: Generate writes one.
    [keys | _] = rows = FakeSheets.rows(fake, "People")
    typed = Enum.map(keys, &Map.get(%{"given_name" => "Omar", "family_name" => "Odd"}, &1, ""))
    FakeSheets.put(fake, "People", rows ++ [typed])
    n = length(rows) + 1

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "People", "a1" => "B#{n}"})

    assert html =~ "Generate"
    view |> element("#sheets-record-row-regenerate") |> render_click()
    [_ | _] = row = Enum.at(FakeSheets.rows(fake, "People"), n - 1)
    assert PersonId.valid?(PersonId.unformat(hd(row)))
  end

  defp code(html), do: Regex.run(~r/[A-Z]{4}-[A-Z]{4}-[A-Z]{4}/, html) |> hd()

  test "Find a person: their row on the open tab is selected (SHEETS-UI.18)",
       %{conn: conn, fake: fake, ann: ann} do
    view = open(conn)
    pick(view, "people")

    html = view |> form("#find-form", q: "Able") |> render_change()
    assert html =~ "Ann Able"
    code = PersonId.format(ann.person_id)

    # No People tab yet: say so.
    html = view |> element("#find-box button[phx-value-code='#{code}']") |> render_click()
    assert html =~ "isn&#39;t on the People tab"

    view |> element("#step-export") |> render_click()
    [_keys, _labels | data] = FakeSheets.rows(fake, "People")
    n = Enum.find_index(data, &(hd(&1) == code)) + 3

    view |> element("#find-box button[phx-value-code='#{code}']") |> render_click()
    assert_push_event(view, "sheets:select", %{sheet: "People", a1: a1})
    assert a1 == "B#{n}"
  end

  test "an edit in the sheet re-reads the selected row (SHEETS-UI.20)",
       %{conn: conn, fake: fake, ann: ann} do
    view = open(conn)
    pick(view, "people")
    view |> element("#step-export") |> render_click()

    code = PersonId.format(ann.person_id)
    [_keys, _labels | data] = FakeSheets.rows(fake, "People")
    n = Enum.find_index(data, &(hd(&1) == code)) + 3

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "People", "a1" => "B#{n}"})

    assert html =~ "Same as in the app."

    edit(fake, "People", {"PersonID", code}, %{"patronymic" => "Petrivna"})
    # Elsewhere in the sheet: nothing to read.
    App.Sheets.notify_edit("ss-1", %{sheet_name: "People", a1: "C#{n + 50}"})
    assert render(view) =~ "Same as in the app."

    App.Sheets.notify_edit("ss-1", %{sheet_name: "People", a1: "C#{n}"})
    assert render(view) =~ "Differs from the app: Patronymic"
  end

  test "Record card: the selected person as a label | value tab (SHEETS-UI.3)",
       %{conn: conn, fake: fake, ann: ann} do
    view = open(conn)
    pick(view, "people")
    view |> element("#step-export") |> render_click()

    code = PersonId.format(ann.person_id)
    [_keys, _labels | data] = FakeSheets.rows(fake, "People")
    n = Enum.find_index(data, &(hd(&1) == code)) + 3

    view
    |> element("#sheets-selection")
    |> render_hook("selection", %{"sheet" => "People", "a1" => "B#{n}"})

    html = view |> element("#sheets-record-row-summary-card") |> render_click()
    assert html =~ "Written to the tab Card."
    assert_push_event(view, "sheets:select", %{sheet: "Card", a1: "A1"})

    [[name, ""], [^code, post] | rest] = FakeSheets.rows(fake, "Card") |> Enum.map(&pad2/1)
    assert name == "Ann Able"
    assert post =~ "Rifleman"
    assert ["Email", "ann@example.test"] in rest
    # Her language record, under its kind.
    assert ["Language skills", ""] in rest
    assert Enum.any?(rest, &match?(["Listening (0-5)", "3"], &1))
  end

  defp pad2(row), do: Enum.take(row ++ ["", ""], 2)

  test "New is for people and records, not assignments", %{conn: conn} do
    view = open(conn)
    html = view |> element("button[id='tool-data.new']") |> render_click()
    assert html =~ "New rows are for people and records"
  end
end
