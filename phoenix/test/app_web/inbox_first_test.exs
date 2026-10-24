defmodule AppWeb.InboxFirstTest do
  @moduledoc "docs/design/inbox-first.md: the start page begins with what waits for the user."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias App.Documents.Document

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company)
    }
  end

  defp trip_order(ctx) do
    first = Date.add(Date.utc_today(), 10)

    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :personnel_order_business_trip,
        person_id: ctx.soldier.person_id,
        data: %{
          "destination" => "Lviv",
          "purpose" => "Course",
          "startDate" => Date.to_iso8601(first),
          "endDate" => Date.to_iso8601(Date.add(first, 2)),
          "transport" => "public_transport"
        }
      },
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)
    |> Ash.Changeset.for_update(:submit, %{assignees: [[ctx.hr.id], [ctx.commander.id]]},
      actor: ctx.hr
    )
    |> Ash.update!(actor: ctx.hr)
    |> Ash.Changeset.for_update(:approve, %{}, actor: ctx.hr)
    |> Ash.update!(actor: ctx.hr)
  end

  defp home(conn, user), do: conn |> authenticated_conn(user) |> get(~p"/") |> html_response(200)

  test "a step to sign shows first; overdue once it waited longer than the setting", ctx do
    order = trip_order(ctx)

    html = home(ctx.conn, ctx.commander)
    assert html =~ ~s(id="inbox")
    assert html =~ ~s(href="/documents/#{order.id}")
    assert html =~ "to sign"
    refute html =~ "overdue"

    # The step became the commander's five days ago; three days are allowed.
    {1, _} =
      App.Repo.update_all(
        from(s in "document_steps",
          where: s.document_id == type(^order.id, :binary_id) and s.status == "pending"
        ),
        set: [pending_since: DateTime.add(DateTime.utc_now(), -5, :day)]
      )

    html = home(ctx.conn, ctx.commander)
    assert html =~ "1 overdue"
    assert html =~ "badge-error"

    # The same mark on the Tasks page.
    {:ok, _view, tasks} = ctx.conn |> authenticated_conn(ctx.commander) |> live(~p"/tasks")
    assert tasks =~ "overdue"

    # Ten days allowed in Settings: no longer overdue.
    {:ok, view, _html} =
      ctx.conn |> authenticated_conn(user_fixture(:admin)) |> live(~p"/settings")

    view |> form("#step-days-form", %{"step_days" => "10"}) |> render_change()
    assert App.Settings.get("documents.step_days") == 10
    refute home(ctx.conn, ctx.commander) =~ "overdue"
  end

  test "nothing waiting: one line, no list", ctx do
    html = home(ctx.conn, ctx.soldier)
    assert html =~ "Nothing waits for you."
  end
end
