defmodule AppWeb.LeaveUiTest do
  @moduledoc "docs/design/leave.md: a person files their own leave request from Tasks."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)

    %{
      conn: conn,
      requester: unit_user_fixture(:viewer, [], company, nil),
      commander: unit_user_fixture(:viewer, [:commander], brigade),
      hr: user_fixture(:hr)
    }
  end

  defp as(conn, user), do: authenticated_conn(conn, user)

  test "the person opens a request in Tasks, sees the days and balance, and sends it",
       %{conn: conn, requester: requester, commander: commander, hr: hr} do
    record_fixture(%{id: requester.person_id}, :leave, %{
      "leaveType" => "annual",
      "startDate" => "2026-03-01",
      "endDate" => "2026-03-10",
      "days" => 10
    })

    {:ok, view, _html} = live(as(conn, requester), ~p"/tasks")

    assert {:error, {:live_redirect, %{to: "/documents/" <> id}}} =
             view
             |> form("#new-request-form", %{"type" => "leave_request"})
             |> render_submit()

    {:ok, view, html} = live(as(conn, requester), "/documents/#{id}")
    assert html =~ "Leave request"

    data = %{
      "leaveType" => "annual",
      "startDate" => "2026-03-09",
      "endDate" => "2026-03-22",
      "destination" => "Lviv"
    }

    html = view |> form("#document-form", %{"data" => data}) |> render_change()
    assert html =~ "14 days requested"
    assert html =~ "20 days of this leave left this year before it"
    assert html =~ "Overlaps another leave"

    view |> form("#document-form", %{"data" => data}) |> render_submit()

    html =
      view
      |> form("#submit-form", %{"step_0" => commander.id, "step_1" => hr.id})
      |> render_submit()

    assert html =~ "In approval"

    {:ok, view, _html} = live(as(conn, requester), ~p"/tasks")
    assert view |> element("#mine") |> render() =~ "Leave request"

    {:ok, view, _html} = live(as(conn, commander), ~p"/tasks")
    assert view |> element("#to-decide") |> render() =~ "Leave request"
  end

  test "an account without a person has no request menu", %{conn: conn, hr: hr} do
    {:ok, view, _html} = live(as(conn, hr), ~p"/tasks")
    refute has_element?(view, "#new-request-form")
    refute has_element?(view, "#mine")
  end
end
