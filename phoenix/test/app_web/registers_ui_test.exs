defmodule AppWeb.RegistersUiTest do
  @moduledoc "docs/design/registers-file-plan.md: the File plan and Registers pages, the export."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Documents.Document
  alias App.Records.FilePlan

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company),
      records: user_fixture(:viewer, [:records_officer]),
      year: Date.utc_today().year
    }
  end

  defp signed_order(ctx) do
    run = fn document, action, actor, args ->
      document
      |> Ash.Changeset.for_update(action, args, actor: actor)
      |> Ash.update!(actor: actor)
    end

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
    |> run.(:submit, ctx.hr, %{assignees: [[ctx.hr.id], [ctx.commander.id]]})
    |> run.(:approve, ctx.hr, %{})
    |> run.(:sign, ctx.commander, %{})
  end

  test "the records officer starts the plan, adds a case; documents are filed and listed", ctx do
    order = signed_order(ctx)
    conn = authenticated_conn(ctx.conn, ctx.records)

    {:ok, view, html} = live(conn, ~p"/file-plan")
    assert html =~ "No cases for this year."
    view |> element("#fill-template") |> render_click()
    assert has_element?(view, "#cases-list", "03-01")

    # The order signed before the plan existed was filed with it.
    [kase] =
      FilePlan.cases(ctx.year, ctx.records) |> Enum.filter(&(&1.index == "03-01"))

    assert has_element?(view, "[data-case-count='#{kase.id}']", "1")

    # A new case through the form.
    view |> element("#cases-header-actions-toolbar button") |> render_click()

    view
    |> form("#case-new-form", %{
      "form" => %{
        "index" => "09-01",
        "title" => "Різне",
        "retention" => "1 р.",
        "document_types" => []
      }
    })
    |> render_submit()

    assert has_element?(view, "#cases-list", "09-01")

    # The case's contents on the Registers page; the order links to itself.
    {:ok, registers, _} = live(conn, ~p"/registers?case=#{kase.id}")
    assert has_element?(registers, "#case-heading", "03-01")
    assert has_element?(registers, "#register-list", order.number)

    # The register for the year, and its export.
    {:ok, registers, _} = live(conn, ~p"/registers?code=#{order.register}&year=#{ctx.year}")
    assert has_element?(registers, "#register-list", order.number)

    response = get(conn, ~p"/exports/register.xlsx?code=#{order.register}&year=#{ctx.year}")
    assert response.status == 200
    assert <<"PK", _::binary>> = response.resp_body

    # Close the year: the inventory of long-term cases lists 03-01.
    view |> element("#close-year") |> render_click()
    assert has_element?(view, "#cases-list", "closed")
    assert has_element?(view, "#plan-summary")

    inventory = get(conn, ~p"/exports/case-inventory.xlsx?year=#{ctx.year}&kind=long")
    assert inventory.status == 200
    assert <<"PK", _::binary>> = inventory.resp_body

    # The document page names its case.
    {:ok, page, _} = live(authenticated_conn(build_conn(), ctx.hr), ~p"/documents/#{order.id}")
    assert has_element?(page, "#document-case", "03-01")
  end

  test "HR reads the plan without changing it; others are turned away", ctx do
    {:ok, view, _} = live(authenticated_conn(ctx.conn, ctx.hr), ~p"/file-plan")
    refute has_element?(view, "#fill-template")

    assert {:error, {:redirect, _}} =
             live(authenticated_conn(build_conn(), ctx.soldier), ~p"/registers")

    assert get(
             authenticated_conn(build_conn(), ctx.soldier),
             ~p"/exports/register.xlsx?code=ос&year=2026"
           ).status ==
             403
  end
end
