defmodule AppWeb.SheetsAssignmentsTest do
  @moduledoc "docs/design/assignments-sheets.md: the sidebar's Assignments tab."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import App.SheetsTokenFixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  alias App.Google.Sheets
  alias App.People.{Assignment, AssignmentSync, PersonId}

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
        "sheet_name" => "Sheet1"
      })

    %{conn: conn, hr: hr, ann: ann}
  end

  # Stubs the Sheets API: every request is reported to the test process;
  # `values` answers reads of the Assignments tab.
  defp stub_sheets(values) do
    test = self()

    Req.Test.stub(Sheets, fn conn ->
      body = Req.Test.raw_body(conn)
      send(test, {:sheets, conn.method, conn.request_path, conn.query_string, body})

      cond do
        conn.method == "GET" and conn.request_path == "/v4/spreadsheets/ss-1" ->
          Req.Test.json(conn, %{
            "sheets" => [%{"properties" => %{"sheetId" => 0, "title" => "Assignments"}}]
          })

        String.ends_with?(conn.request_path, ":batchUpdate") ->
          Req.Test.json(conn, %{"replies" => added_tabs(body)})

        conn.method == "GET" and String.contains?(conn.request_path, "Assignments") ->
          Req.Test.json(conn, %{"values" => values})

        true ->
          Req.Test.json(conn, %{"values" => []})
      end
    end)
  end

  # batchUpdate replies for addSheet requests.
  defp added_tabs(body) do
    for %{"addSheet" => %{"properties" => %{"title" => title}}} <- Jason.decode!(body)["requests"],
        do: %{"addSheet" => %{"properties" => %{"title" => title, "sheetId" => 7}}}
  end

  test "export writes the three tabs as RAW values with the dropdown and hidden Version",
       %{conn: conn} do
    stub_sheets([])
    {:ok, view, _html} = live(conn, ~p"/sheets")

    html = view |> element("button[id='tool-data.export']") |> render_click()
    assert html =~ "Written to the tabs Assignments, Positions and History"

    # The missing tabs are added; existing Assignments is reused.
    assert_received {:sheets, "POST", "/v4/spreadsheets/ss-1:batchUpdate", _, add}
    assert %{"requests" => [%{"addSheet" => _}, %{"addSheet" => _}]} = Jason.decode!(add)

    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21A1", query, put}

    assert query =~ "valueInputOption=RAW"
    assert [["PersonID" | _] | _] = Jason.decode!(put)["values"]

    assert_received {:sheets, "POST", "/v4/spreadsheets/ss-1:batchUpdate", _, format}
    requests = Jason.decode!(format)["requests"]

    assert Enum.any?(requests, fn r ->
             get_in(r, ["setDataValidation", "rule", "condition", "values"]) ==
               [%{"userEnteredValue" => "=Positions!$A$2:$A$3"}]
           end)

    assert Enum.any?(
             requests,
             &get_in(&1, ["updateDimensionProperties", "properties", "hiddenByUser"])
           )
  end

  test "import previews, then drafts orders only after confirming", %{
    conn: conn,
    hr: hr,
    ann: ann
  } do
    code = PersonId.format(ann.person_id)

    rows =
      Enum.map(AssignmentSync.export(hr).assignments, fn
        [^code, name, unit, _position, _since, version] ->
          [code, name, unit, "Combat Medic A.Co¦1Bn¦OR-4", "", version]

        row ->
          row
      end)

    stub_sheets(rows)
    {:ok, view, _html} = live(conn, ~p"/sheets")

    html = view |> element("button[id='tool-data.check']") |> render_click()
    assert html =~ "Transfer order"
    assert html =~ "Ann Able"

    current = fn ->
      Assignment
      |> Ash.Query.filter(person_id == ^ann.id and is_nil(ends_on))
      |> Ash.Query.load(:position)
      |> Ash.read_one!(authorize?: false)
    end

    assert current.().position.title == "Rifleman"

    html = view |> element("#import-preview button", "Carry out") |> render_click()
    assert html =~ "1 draft order created"

    # The post changes when the order is signed.
    assert current.().position.title == "Rifleman"

    assert [%{type: :personnel_order_transfer, state: :draft}] =
             App.Documents.Document
             |> Ash.Query.filter(person_id == ^ann.id)
             |> Ash.read!(authorize?: false)

    # The sheet is written again from the database right away.
    assert html =~ "The sheet was refreshed from the database."

    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21A1", _, put}

    assert Enum.any?(
             Jason.decode!(put)["values"],
             &match?([^code, _, _, "Rifleman" <> _ | _], &1)
           )
  end

  test "export lays the tab out like the app's form (SHEETS-UI)", %{conn: conn, ann: ann} do
    stub_sheets([])
    {:ok, view, _html} = live(conn, ~p"/sheets")
    view |> element("button[id='tool-data.export']") |> render_click()

    assert_received {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21A1", _, put}
    [keys, labels | data] = Jason.decode!(put)["values"]

    assert keys ==
             ~w(PersonID Name Unit Position Since Status Version ExportedPosition ExportedSince)

    # Labels from the form's UI Schema; the first hidden column marks the row.
    assert ["PersonID", "Name", "Unit", "Position", "Start date", "Status", marker, _, _] =
             labels

    assert marker == AppWeb.SheetLayout.marker("assignments")

    code = PersonId.format(ann.person_id)
    [^code, _, _, position, since, "", _, position, since] = Enum.find(data, &(hd(&1) == code))
    # A real date (a serial number, shown as dd.mm.yyyy).
    assert since == Date.diff(Date.add(Date.utc_today(), -30), ~D[1899-12-30])

    requests =
      for {:sheets, "POST", "/v4/spreadsheets/ss-1:batchUpdate", _, body} <- drain(),
          request <- Jason.decode!(body)["requests"],
          do: request

    kinds = requests |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

    for kind <- ~w(addBanding addConditionalFormatRule addProtectedRange repeatCell updateCells) do
      assert kind in kinds, kind
    end

    assert Enum.any?(
             requests,
             &(get_in(&1, ["setDataValidation", "rule", "condition", "type"]) == "DATE_IS_VALID")
           )

    # The form's help as a note on the label.
    notes =
      for %{"updateCells" => %{"rows" => [%{"values" => values}]}} <- requests,
          v <- values,
          do: v["note"]

    assert "The first day in the post." in notes

    # A changed cell is compared with its hidden exported copy.
    formulas =
      for %{"addConditionalFormatRule" => %{"rule" => rule}} <- requests,
          do:
            get_in(rule, ["booleanRule", "condition", "values"])
            |> hd()
            |> Map.get("userEnteredValue")

    assert "=$D3<>$H3" in formulas and "=$E3<>$I3" in formulas

    # The Status column is coloured by its first sign.
    signs =
      for %{"addConditionalFormatRule" => %{"rule" => rule}} <- requests,
          get_in(rule, ["booleanRule", "condition", "type"]) == "TEXT_STARTS_WITH",
          do:
            rule
            |> get_in(["booleanRule", "condition", "values"])
            |> hd()
            |> Map.get("userEnteredValue")

    assert Enum.sort(signs) == Enum.sort(~w(✓ → ! ↻ ✗))
  end

  test "writing the tab again replaces its formatting instead of stacking it", %{conn: conn} do
    test = self()

    Req.Test.stub(Sheets, fn conn ->
      body = Req.Test.raw_body(conn)
      send(test, {:sheets, conn.method, conn.request_path, conn.query_string, body})

      if conn.method == "GET" and conn.request_path == "/v4/spreadsheets/ss-1" do
        Req.Test.json(conn, %{
          "sheets" => [
            %{
              "properties" => %{"sheetId" => 0, "title" => "Assignments"},
              "bandedRanges" => [%{"bandedRangeId" => 11}],
              "conditionalFormats" => [%{}, %{}],
              "protectedRanges" => [
                %{"protectedRangeId" => 21, "description" => "SHEETS-UI"},
                %{"protectedRangeId" => 22, "description" => "someone else's"}
              ]
            },
            %{"properties" => %{"sheetId" => 1, "title" => "Positions"}},
            %{"properties" => %{"sheetId" => 2, "title" => "History"}}
          ]
        })
      else
        Req.Test.json(conn, %{"replies" => []})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/sheets")
    view |> element("button[id='tool-data.export']") |> render_click()

    [requests] =
      for {:sheets, "POST", "/v4/spreadsheets/ss-1:batchUpdate", _, body} <- drain(),
          do: Jason.decode!(body)["requests"]

    assert %{"deleteBanding" => %{"bandedRangeId" => 11}} in requests
    assert %{"deleteConditionalFormatRule" => %{"sheetId" => 0, "index" => 1}} in requests
    assert %{"deleteConditionalFormatRule" => %{"sheetId" => 0, "index" => 0}} in requests
    assert %{"deleteProtectedRange" => %{"protectedRangeId" => 21}} in requests
    refute %{"deleteProtectedRange" => %{"protectedRangeId" => 22}} in requests
  end

  test "an import under a label row skips it and counts rows as the sheet does", %{
    conn: conn,
    hr: hr
  } do
    [keys | data] = AssignmentSync.export(hr).assignments
    labels = ["PersonID", "Name", "Unit", "Position", "Start date", "#labels"]
    stub_sheets([keys, labels | data] ++ [["XXXX-XXXX", "Nobody", "", "", "", ""]])

    {:ok, view, _html} = live(conn, ~p"/sheets")
    html = view |> element("button[id='tool-data.check']") |> render_click()

    # Two data rows from row 3, then the unknown person on row 5.
    assert html =~ ">row 5<"
    refute html =~ ">row 2<"
  end

  test "stage 1: the step guide, the Status column, the drafts created and cancelled",
       %{conn: conn, hr: hr, ann: ann} do
    code = PersonId.format(ann.person_id)
    [header | data] = AssignmentSync.export(hr).assignments

    # The tab as SHEETS-UI writes it, then Ann's post changed in the sheet.
    [keys, labels | rows] =
      AppWeb.SheetLayout.rows("assignments", [
        header ++ ["Status"] | Enum.map(data, &(&1 ++ [""]))
      ])

    position = Enum.find_index(keys, &(&1 == "Position"))

    rows =
      Enum.map(rows, fn
        [^code | _] = row -> List.replace_at(row, position, "Combat Medic A.Co¦1Bn¦OR-4")
        row -> row
      end)

    stub_sheets([keys, labels | rows])
    {:ok, view, _html} = live(conn, ~p"/sheets")

    # The spreadsheet already has the tab: the guide starts at Edit.
    render_async(view)
    assert has_element?(view, "#data-steps li[data-current][data-step='edit']")

    view |> element("#step-check") |> render_click()
    assert has_element?(view, "#data-steps li[data-current][data-step='carry_out']")

    # The check's findings in the Status column (F), rows 3 and 4.
    statuses =
      for {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21F3%3AF4", _, body} <-
            drain(),
          do: Jason.decode!(body)["values"]

    ann_row = Enum.find_index(rows, &(hd(&1) == code))
    assert [values] = statuses
    assert ["→ Transfer order from " <> _] = Enum.at(values, ann_row)
    assert [""] = Enum.at(values, 1 - ann_row)

    html = view |> element("#import-preview button", "Carry out") |> render_click()
    assert html =~ "1 draft order created"

    assert has_element?(view, "#data-steps li[data-current][data-step='carry_out']") ==
             false

    # The tab is written again; Ann's row says what was done.
    [written] =
      for {:sheets, "PUT", "/v4/spreadsheets/ss-1/values/Assignments%21A1", _, body} <- drain(),
          do: Jason.decode!(body)["values"]

    status = Enum.find_index(hd(written), &(&1 == "Status"))
    ann_written = Enum.find(written, &(hd(&1) == code))
    assert "✓ Draft transfer order created" <> _ = Enum.at(ann_written, status)

    # The draft is listed with a link, and can be cancelled.
    [document] =
      App.Documents.Document
      |> Ash.Query.filter(person_id == ^ann.id)
      |> Ash.read!(authorize?: false)

    assert has_element?(view, "#import-drafts a[href='/documents/#{document.id}']", "Ann Able")

    html = view |> element("#cancel-drafts") |> render_click()
    assert html =~ "1 draft cancelled."
    assert Ash.get!(App.Documents.Document, document.id, authorize?: false).state == :cancelled
  end

  defp drain(acc \\ []) do
    receive do
      {:sheets, _, _, _, _} = message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a missing Assignments tab is explained", %{conn: conn} do
    Req.Test.stub(Sheets, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "Unable to parse range"})
    end)

    {:ok, view, _html} = live(conn, ~p"/sheets")
    html = view |> element("button[id='tool-data.check']") |> render_click()
    assert html =~ "There is no Assignments tab"
  end

  test "the top row: the menu with the sheet format, tool icons for the open tab", %{conn: conn} do
    stub_sheets([])
    {:ok, view, html} = live(conn, ~p"/sheets")

    # No "HR Admin" title and no e-mail row; the e-mail is in the menu.
    refute html =~ "HR Admin"
    assert has_element?(view, "#sidebar-menu-menu", "hr@example.com")
    assert has_element?(view, "#menu-help-data")
    # Theme and language: last in the menu, not in the top row.
    assert has_element?(view, "#sidebar-menu-menu #theme-row button[data-phx-theme='dark']")
    assert has_element?(view, "#sidebar-menu-menu #language-row a[href='?locale=uk']")
    refute has_element?(view, "#language-menu-button")
    refute has_element?(view, "#theme-menu-button")
    assert has_element?(view, "#help-data.hidden", "laid out like the app's form")
    # Tools of every tab are rendered; only the open tab's group is shown.
    assert has_element?(view, "#tools-sheet:not(.hidden) button[id='tool-sheet.refresh']")
    assert has_element?(view, "#tools-data.hidden button[id='tool-data.check']")
  end

  test "items hidden for a role on the Sidebar layout page disappear", %{conn: conn, hr: hr} do
    admin = Ash.Seed.seed!(App.Accounts.User, %{email: "admin@example.com", role: :admin})
    :ok = AppWeb.SidebarLayout.put_hidden(%{"hr" => ["sheet", "data.check"]}, admin)

    stub_sheets([])
    {:ok, view, _html} = live(conn, ~p"/sheets")

    refute has_element?(view, "#tab-sheet")
    refute has_element?(view, "button[id='tool-data.check']")
    assert has_element?(view, "button[id='tool-data.export']")
    # The only tab left is open (no tab list).
    assert has_element?(view, "#panel-data:not(.hidden)")
    assert has_element?(view, "#tools-data:not(.hidden)")
    assert hr.role == :hr
  end
end
