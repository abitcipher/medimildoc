defmodule AppWeb.DutyRosterUiTest do
  @moduledoc "docs/design/duty-roster.md: planning on the roster; the leave request warns."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      commander: unit_user_fixture(:viewer, [:commander], company)
    }
  end

  test "a commander assigns and removes a duty; a duty on a day of leave is red", ctx do
    today = Date.utc_today()
    month = Calendar.strftime(today, "%Y-%m")

    record_fixture(%{id: ctx.soldier.person_id}, :leave, %{
      "leaveType" => "annual",
      "startDate" => Date.to_iso8601(today),
      "endDate" => Date.to_iso8601(today),
      "days" => 1
    })

    conn = authenticated_conn(ctx.conn, ctx.commander)
    {:ok, view, _} = live(conn, ~p"/duty-roster?unit=#{ctx.company.id}&month=#{month}")

    view
    |> element(
      "button[phx-value-person='#{ctx.soldier.person_id}'][phx-value-date='#{Date.to_iso8601(today)}']"
    )
    |> render_click()

    assert has_element?(view, "#duty-pick")

    view
    |> form("#duty-shift-form", %{"form" => %{"duty_type" => "duty_officer"}})
    |> render_submit()

    assert has_element?(view, "#roster-summary", "On duty while away: 1")
    assert [shift] = Ash.read!(App.Duty.Shift, authorize?: false)
    assert shift.organization_id == ctx.company.id

    view
    |> element(
      "button[phx-value-person='#{ctx.soldier.person_id}'][phx-value-date='#{Date.to_iso8601(today)}']"
    )
    |> render_click()

    view |> element("#duty-pick button", "Remove the duty") |> render_click()
    assert Ash.read!(App.Duty.Shift, authorize?: false) == []
  end

  test "a leave request over a planned duty says so", ctx do
    first = Date.add(Date.utc_today(), 20)

    App.Duty.Shift
    |> Ash.Changeset.for_create(
      :create,
      %{
        date: Date.add(first, 1),
        duty_type: "orderly",
        person_id: ctx.soldier.person_id,
        organization_id: ctx.company.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    request =
      App.Documents.Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :leave_request,
          person_id: ctx.soldier.person_id,
          data: %{
            "leaveType" => "annual",
            "startDate" => Date.to_iso8601(first),
            "endDate" => Date.to_iso8601(Date.add(first, 4))
          }
        },
        actor: ctx.soldier
      )
      |> Ash.create!(actor: ctx.soldier)

    {:ok, page, _} = live(authenticated_conn(ctx.conn, ctx.soldier), ~p"/documents/#{request.id}")
    assert has_element?(page, "#leave-duties", "1 duty planned")
  end

  test "a large unit shows the first rows and loads more as the grid is scrolled", ctx do
    for n <- 1..30, do: assign_fixture(person_fixture(%{family_name: "Member#{n}"}), ctx.company)

    conn = authenticated_conn(ctx.conn, ctx.commander)
    {:ok, view, _} = live(conn, ~p"/duty-roster?unit=#{ctx.company.id}")

    rows = fn view -> length(Regex.scan(~r/<tr id="rows-/, render(view))) end
    assert rows.(view) == 25

    render_hook(view, "more_rows", %{})
    assert rows.(view) == 32

    {:ok, leave, _} = live(conn, ~p"/leave-calendar?unit=#{ctx.company.id}")
    assert rows.(leave) == 25
    render_hook(leave, "more_rows", %{})
    assert rows.(leave) == 32
  end
end
