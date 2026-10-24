defmodule AppWeb.DeputiesUiTest do
  @moduledoc "docs/design/inbox-first.md: stand-ins on the Tasks page, the deputy's view, the task count."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Documents.{Deputy, Document}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: Ash.Seed.update!(user_fixture(:hr), %{name: "Head of HR"}),
      hr2: Ash.Seed.update!(user_fixture(:hr), %{name: "Second HR"}),
      commander: unit_user_fixture(:viewer, [:commander], company)
    }
  end

  defp order(ctx) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :personnel_order_grade,
        person_id: ctx.soldier.person_id,
        data: %{"grade" => "OR-4", "effectiveDate" => Date.to_iso8601(Date.utc_today())}
      },
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)
    |> Ash.Changeset.for_update(:submit, %{assignees: [[ctx.hr.id], [ctx.commander.id]]},
      actor: ctx.hr
    )
    |> Ash.update!(actor: ctx.hr)
  end

  test "a user names a deputy for dates; the deputy approves for them; then it is removed", ctx do
    document = order(ctx)
    conn = authenticated_conn(ctx.conn, ctx.hr)
    today = Date.to_iso8601(Date.utc_today())

    {:ok, view, html} = live(conn, ~p"/tasks")
    assert html =~ "My deputies"
    # The task count next to "Tasks".
    assert has_element?(view, "#tasks-badge", "1")

    view |> element("#deputies-header-actions-toolbar button") |> render_click()

    view
    |> form("#deputy-form", %{
      "form" => %{"deputy_id" => ctx.hr2.id, "starts_on" => today, "ends_on" => today}
    })
    |> render_submit()

    assert has_element?(view, "#deputies-list", "Second HR")
    assert render(view) =~ "active"

    # The deputy: the document in their tasks, marked, and the decision is theirs to make.
    deputy_conn = authenticated_conn(build_conn(), ctx.hr2)
    {:ok, tasks, _} = live(deputy_conn, ~p"/tasks")
    assert has_element?(tasks, "#to-decide", "for Head of HR")
    assert has_element?(tasks, "#standing-in", "Head of HR")

    {:ok, page, _} = live(deputy_conn, ~p"/documents/#{document.id}")
    assert has_element?(page, "#deputy-note", "Head of HR")
    page |> form("#decision-form") |> render_submit(%{"decision" => "approve"})
    assert render(page) =~ "decided by deputy Second HR"

    [deputy] = Ash.read!(Deputy, authorize?: false)
    # The same button is in the table and in the cards (one per width).
    render_click(view, "delete_deputy", %{"id" => deputy.id})
    refute has_element?(view, "#deputies-list", "Second HR")
  end

  test "an administrator sets a deputy for another user; one without the permissions is refused",
       ctx do
    admin = Ash.Seed.update!(user_fixture(:admin), %{name: "Admin"})
    viewer = Ash.Seed.update!(user_fixture(:viewer), %{name: "Plain viewer"})
    {:ok, view, _html} = live(authenticated_conn(ctx.conn, admin), ~p"/users")

    view |> element("#deputies-admin-add") |> render_click()

    html =
      view
      |> form("#deputies-admin-form", %{
        "form" => %{"user_id" => ctx.hr.id, "deputy_id" => viewer.id}
      })
      |> render_submit()

    assert html =~ "holds none of the permissions"

    view
    |> form("#deputies-admin-form", %{
      "form" => %{"user_id" => ctx.hr.id, "deputy_id" => ctx.hr2.id}
    })
    |> render_submit()

    assert has_element?(view, "#deputies-admin-list", "Second HR")
    assert [%{user_id: user_id}] = Ash.read!(Deputy, authorize?: false)
    assert user_id == ctx.hr.id
  end
end
