defmodule AppWeb.ImportExportLiveTest do
  @moduledoc "docs/design/assignments-sheets.md: the offline workbook page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  alias App.People.{Assignment, AssignmentSync, PersonId}

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company, 1 Bn")

    ann =
      person_fixture(%{given_name: "Ann", family_name: "Able"})
      |> assign_fixture(unit, title: "Rifleman", grade: "OR-3")

    medic =
      person_fixture(%{given_name: "Mo", family_name: "Medic"})
      |> assign_fixture(unit, title: "Combat Medic", grade: "OR-4")

    hr = user_fixture(:hr)
    %{conn: authenticated_conn(conn, hr), hr: hr, ann: ann, medic: medic}
  end

  # The exported workbook with Ann moved to the medic post.
  defp edited_workbook(hr, ann) do
    export = AssignmentSync.export(hr)
    code = PersonId.format(ann.person_id)

    rows =
      Enum.map(export.assignments, fn
        [^code, name, unit, _position, _since, version] ->
          [code, name, unit, "Combat Medic A.Co¦1Bn¦OR-4", "20.09.2026", version]

        row ->
          row
      end)

    {:ok, binary} = App.Xlsx.assignments_workbook(%{export | assignments: rows})
    binary
  end

  test "the workbook downloads as .xlsx", %{conn: conn} do
    conn = get(conn, ~p"/exports/assignments.xlsx")
    assert response_content_type(conn, :xlsx) =~ "spreadsheetml"
    assert <<"PK", _::binary>> = conn.resp_body
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "assignments-"
  end

  test "upload, preview, apply", %{conn: conn, hr: hr, ann: ann} do
    {:ok, view, _html} = live(conn, ~p"/import-export")

    workbook =
      file_input(view, "#workbook-form", :workbook, [
        %{
          name: "assignments.xlsx",
          content: edited_workbook(hr, ann),
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(workbook, "assignments.xlsx")
    html = view |> form("#workbook-form") |> render_submit()

    assert html =~ "1 change"
    assert html =~ "Ann Able"
    assert html =~ "Rifleman A.Co¦1Bn¦OR-3 → Combat Medic A.Co¦1Bn¦OR-4"
    # Nothing written before confirming.
    assert [_] =
             Assignment |> Ash.Query.filter(person_id == ^ann.id) |> Ash.read!(authorize?: false)

    html = view |> element(~s(button[phx-click="confirm_import"])) |> render_click()
    assert html =~ "1 draft order created"

    # The post changes when the order is signed; the draft waits in Tasks.
    assert [_] =
             Assignment |> Ash.Query.filter(person_id == ^ann.id) |> Ash.read!(authorize?: false)

    assert [%{type: :personnel_order_transfer, state: :draft}] =
             App.Documents.Document
             |> Ash.Query.filter(person_id == ^ann.id)
             |> Ash.read!(authorize?: false)
  end

  test "a file that isn't a workbook gets a message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import-export")

    input =
      file_input(view, "#workbook-form", :workbook, [
        %{
          name: "x.xlsx",
          content: "nope",
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(input, "x.xlsx")
    assert view |> form("#workbook-form") |> render_submit() =~ "not a readable .xlsx file"
  end

  test "viewers can't open the page or import" do
    conn = authenticated_conn(build_conn(), user_fixture(:viewer))
    assert {:error, {:redirect, _}} = live(conn, ~p"/import-export")
  end
end
