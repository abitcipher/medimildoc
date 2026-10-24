defmodule AppWeb.SheetsRowFormTest do
  @moduledoc "SHEETS-UI (docs/design/sheets-ui.md): the selected row as the app's form."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import App.SheetsTokenFixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  alias App.Google.Sheets
  alias App.People.{AssignmentSync, PersonId}
  alias AppWeb.SheetLayout

  @medic "Combat Medic A.Co¦1Bn¦OR-4"

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company, 1 Bn")

    ann =
      person_fixture(%{given_name: "Ann", family_name: "Able"})
      |> assign_fixture(unit, title: "Rifleman", grade: "OR-3")

    person_fixture(%{given_name: "Mo", family_name: "Medic"})
    |> assign_fixture(unit, title: "Combat Medic", grade: "OR-4")

    hr = Ash.Seed.seed!(App.Accounts.User, %{email: "hr@example.com", role: :hr})

    conn =
      put_connect_params(conn, %{
        "sheets_token" => sheets_token(sub: "hr@example.com", ssid: "ss-1"),
        "google_access_token" => "google-token",
        "sheet_name" => "Assignments"
      })

    # Ann's row as the laid-out tab has it, on sheet row 3.
    [keys, labels | data] =
      SheetLayout.rows("assignments", AssignmentSync.export(hr).assignments)

    code = PersonId.format(ann.person_id)
    row = Enum.find(data, &(hd(&1) == code)) |> Enum.map(&to_string/1)
    # As read back: the date formatted.
    since = Calendar.strftime(Date.add(Date.utc_today(), -30), "%d.%m.%Y")
    row = List.replace_at(row, 4, since)

    stub(keys, labels, row)
    %{conn: conn, ann: ann, since: since, keys: keys, labels: labels, row: row}
  end

  # The Sheets API with `row` on sheet row 3.
  defp stub(keys, labels, row) do
    test = self()

    Req.Test.stub(Sheets, fn conn ->
      body = Req.Test.raw_body(conn)
      send(test, {:sheets, conn.method, conn.request_path, body})

      case {conn.method, conn.request_path} do
        {"GET", "/v4/spreadsheets/ss-1/values/Assignments%21A1%3AZZ2"} ->
          Req.Test.json(conn, %{"values" => [keys, labels]})

        {"GET", "/v4/spreadsheets/ss-1/values/Assignments%21A3%3AZZ3"} ->
          Req.Test.json(conn, %{"values" => [row]})

        _ ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp select(view, a1),
    do:
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "Assignments", "a1" => a1})

  test "the selected row opens as the app's form; checked and carried out", %{
    conn: conn,
    ann: ann
  } do
    {:ok, view, _html} = live(conn, ~p"/sheets")

    html = select(view, "D3")
    assert html =~ "Ann Able"
    assert html =~ "Now: Rifleman"
    assert html =~ "Same as in the app."
    assert has_element?(view, "#sheets-row-form a[href='/people/#{ann.id}']")
    # The form from the app's assignment form schema, filled from the row.
    assert has_element?(view, "#sheets-row-form-form select[name='row[position_id]']")
    assert has_element?(view, "#sheets-row-form-form input[type='date'][name='row[starts_on]']")

    html =
      view
      |> form("#sheets-row-form-form", row: %{position_id: @medic})
      |> render_submit()

    assert html =~ "Transfer order"

    html = view |> element("#row-preview button", "Carry out") |> render_click()
    assert html =~ "1 draft order created"

    assert [%{type: :personnel_order_transfer, state: :draft}] =
             App.Documents.Document
             |> Ash.Query.filter(person_id == ^ann.id)
             |> Ash.read!(authorize?: false)

    # The row is written again from the database.
    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21A3", body}
    assert [[_code, "Ann Able", _, "Rifleman" <> _ | _]] = Jason.decode!(body)["values"]
  end

  test "write to the sheet puts the form's values into the row's cells", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sheets")
    select(view, "B3")

    view
    |> form("#sheets-row-form-form", row: %{position_id: @medic, starts_on: "2026-11-02"})
    |> render_change()

    html = view |> element("#sheets-row-form-write") |> render_click()
    assert html =~ "Written to row 3"

    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21D3", position}
    assert Jason.decode!(position)["values"] == [[@medic]]

    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21E3", since}
    assert Jason.decode!(since)["values"] == [[Date.diff(~D[2026-11-02], ~D[1899-12-30])]]
  end

  test "the row is compared with the app as soon as it is selected (SHEETS-UI.9)", %{
    conn: conn,
    ann: ann,
    keys: keys,
    labels: labels,
    row: row
  } do
    # Edited in the sheet: the post differs from the app.
    stub(keys, labels, List.replace_at(row, 3, @medic))
    {:ok, view, _html} = live(conn, ~p"/sheets")
    html = select(view, "D3")
    assert html =~ "Post in the sheet: #{@medic} (in the app: Rifleman"

    # Not edited, but the app changed Ann after the export: out of date.
    Process.sleep(2)

    App.People.Assignment
    |> Ash.Query.filter(person_id == ^ann.id and is_nil(ends_on))
    |> Ash.read_one!(authorize?: false)
    |> Ash.Changeset.for_update(:update, %{starts_on: ~D[2026-01-05]}, authorize?: false)
    |> Ash.update!(authorize?: false)

    stub(keys, labels, row)
    {:ok, view, _html} = live(conn, ~p"/sheets")
    html = select(view, "D3")
    assert html =~ "this row is out of date"
  end

  test "header rows and other tabs are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sheets")

    select(view, "A2")
    refute has_element?(view, "#sheets-row-form-person")

    html =
      view
      |> element("#sheets-selection")
      |> render_hook("selection", %{"sheet" => "Positions", "a1" => "A5"})

    assert html =~ "Select a row on a tab the app wrote"
  end
end
