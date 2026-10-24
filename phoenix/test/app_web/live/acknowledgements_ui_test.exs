defmodule AppWeb.AcknowledgementsUiTest do
  @moduledoc "docs/design/acknowledgements.md: Tasks, the order's page and the bulk page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Documents.{Document, Queries}

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      conn: conn,
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      second: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company)
    }
  end

  defp as(conn, user), do: authenticated_conn(conn, user)

  # A signed grade order about the user's person (head of HR approves,
  # the commander signs).
  defp signed_order(ctx, user) do
    {:ok, order} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_grade,
          person_id: user.person_id,
          data: %{"grade" => "OR-4", "effectiveDate" => Date.to_iso8601(Date.utc_today())}
        },
        actor: ctx.hr
      )
      |> Ash.create(actor: ctx.hr)

    {:ok, order} =
      order
      |> Ash.Changeset.for_update(:submit, %{assignees: [[ctx.hr.id], [ctx.commander.id]]},
        actor: ctx.hr
      )
      |> Ash.update(actor: ctx.hr)

    {:ok, order} =
      order |> Ash.Changeset.for_update(:approve, %{}, actor: ctx.hr) |> Ash.update(actor: ctx.hr)

    {:ok, order} =
      order
      |> Ash.Changeset.for_update(:sign, %{}, actor: ctx.commander)
      |> Ash.update(actor: ctx.commander)

    order
  end

  test "the person finds the order in Tasks and acknowledges it on its page",
       %{conn: conn} = ctx do
    order = signed_order(ctx, ctx.soldier)

    {:ok, view, _html} = live(as(conn, ctx.soldier), ~p"/tasks")
    assert view |> element("#to-acknowledge") |> render() =~ order.number

    {:ok, view, html} = live(as(conn, ctx.soldier), "/documents/#{order.id}")
    assert html =~ "Not acknowledged yet."
    refute has_element?(view, "#record-acknowledgement-form")

    html = view |> element("#acknowledge-button") |> render_click()
    assert html =~ "Acknowledged on"
    assert html =~ "by the person, in the app"
    refute has_element?(view, "#acknowledge-button")

    {:ok, view, _html} = live(as(conn, ctx.soldier), ~p"/tasks")
    refute has_element?(view, "#to-acknowledge")
  end

  test "HR records it on the order's page", %{conn: conn} = ctx do
    order = signed_order(ctx, ctx.soldier)

    {:ok, view, _html} = live(as(conn, ctx.hr), "/documents/#{order.id}")
    refute has_element?(view, "#acknowledge-button")

    html =
      view
      |> form("#record-acknowledgement-form", %{
        "acknowledgement" => %{"method" => "paper", "note" => "Sheet 12"}
      })
      |> render_submit()

    assert html =~ "signed on paper"
    assert html =~ "Sheet 12"

    assert Queries.acknowledgements([order.id])[order.id].recorded_by_email ==
             to_string(ctx.hr.email)
  end

  test "the commander records a formation in bulk", %{conn: conn} = ctx do
    first = signed_order(ctx, ctx.soldier)
    second = signed_order(ctx, ctx.second)

    {:ok, view, html} = live(as(conn, ctx.commander), ~p"/acknowledgements")
    assert html =~ first.number and html =~ second.number

    view |> element("#select-all") |> render_click()

    html =
      view
      |> form("#acknowledgement-record", %{"acknowledgement" => %{"method" => "in_person"}})
      |> render_submit()

    assert html =~ "2 recorded"
    assert html =~ "Nothing awaits acknowledgement."

    done = Queries.acknowledgements([first.id, second.id])
    assert Enum.all?(Map.values(done), &(&1.method == :in_person))
  end

  test "the page is in the sidebar for HR and commanders only", %{conn: conn} = ctx do
    {:ok, _view, html} = live(as(conn, ctx.commander), ~p"/tasks")
    assert html =~ ~s(href="/acknowledgements")

    {:ok, _view, html} = live(as(conn, ctx.soldier), ~p"/tasks")
    refute html =~ ~s(href="/acknowledgements")
  end
end
