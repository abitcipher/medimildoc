defmodule AppWeb.LeaveCalendarLiveTest do
  @moduledoc "docs/design/leave-calendar.md: the calendar page and the unit load on a leave request."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    commander =
      person_fixture(%{given_name: "Cora", family_name: "Commander"})
      |> assign_fixture(company, title: "Company Commander")

    commander_post = post_of(commander)

    deputy =
      person_fixture(%{given_name: "Dan", family_name: "Deputy"})
      |> assign_fixture(company, title: "Deputy", reports_to: commander_post)

    deputy_post = post_of(deputy)

    # Someone reports to the deputy, so both commander and deputy hold key posts.
    person_fixture(%{given_name: "Rita", family_name: "Rifleman"})
    |> assign_fixture(company, title: "Rifleman", reports_to: deputy_post)

    requester = unit_user_fixture(:viewer, [], company, nil)

    %{
      conn: conn,
      company: company,
      commander: commander,
      deputy: deputy,
      requester: requester,
      hr: user_fixture(:hr)
    }
  end

  defp post_of(person) do
    App.People.Assignment
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.Query.load(:position)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:position)
  end

  defp leave(person, first, last, type \\ "annual") do
    record_fixture(person, :leave, %{
      "leaveType" => type,
      "startDate" => Date.to_iso8601(first),
      "endDate" => Date.to_iso8601(last),
      "days" => Date.diff(last, first) + 1
    })
  end

  test "the month shows who is away, and the days with too many or several leaders away",
       %{conn: conn} = ctx do
    month = Date.beginning_of_month(Date.utc_today())
    leave(ctx.commander, Date.add(month, 9), Date.add(month, 11))
    leave(ctx.deputy, Date.add(month, 10), Date.add(month, 12), "sick")

    {:ok, view, html} =
      live(
        authenticated_conn(conn, ctx.hr),
        ~p"/leave-calendar?#{[unit: ctx.company.id, month: Calendar.strftime(month, "%Y-%m")]}"
      )

    assert html =~ "Cora Commander"
    assert html =~ "Dan Deputy"

    # 4 people → limit 1; days 11–12 have both leaders away.
    conflicts = view |> element("#calendar-conflicts") |> render()
    assert conflicts =~ AppWeb.DateFormat.display(Date.add(month, 10))
    assert conflicts =~ "several leaders away"
    assert conflicts =~ "up to 2 away, limit 1"

    # Another month: no conflicts.
    next = Date.shift(month, month: 1)
    html = view |> element("a[aria-label='Next month']") |> render_click()
    assert html =~ "No day this month has too many people away."

    assert_patched(
      view,
      ~p"/leave-calendar?#{[unit: ctx.company.id, month: Calendar.strftime(next, "%Y-%m")]}"
    )
  end

  test "a leave request shows how many others of the unit are away then", %{conn: conn} = ctx do
    first = Date.add(Date.utc_today(), 20)
    leave(ctx.commander, first, Date.add(first, 4))
    leave(ctx.deputy, Date.add(first, 2), Date.add(first, 3))

    {:ok, request} =
      App.Documents.Document
      |> Ash.Changeset.for_create(
        :create,
        %{type: :leave_request, person_id: ctx.requester.person_id, data: %{}},
        actor: ctx.requester
      )
      |> Ash.create(actor: ctx.requester)

    {:ok, view, _html} = live(authenticated_conn(conn, ctx.requester), "/documents/#{request.id}")

    html =
      view
      |> form("#document-form", %{
        "data" => %{
          "leaveType" => "annual",
          "startDate" => Date.to_iso8601(first),
          "endDate" => Date.to_iso8601(Date.add(first, 3))
        }
      })
      |> render_change()

    assert html =~ "In the unit up to 2 others away then (limit 1)"
    # Counts only — nobody is named.
    refute view |> element("#leave-unit-load") |> render() =~ "Commander"
  end
end
