defmodule AppWeb.TripReportUiTest do
  @moduledoc "docs/design/business-trips.md §Report: the report starts from the signed order."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Documents.Document

  test "the person opens their signed trip order and starts the report, pre-filled", %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))
    soldier = unit_user_fixture(:viewer, [], company, nil)
    commander = unit_user_fixture(:viewer, [:commander], company)
    hr = user_fixture(:hr)

    run = fn doc, action, actor, args ->
      doc |> Ash.Changeset.for_update(action, args, actor: actor) |> Ash.update!(actor: actor)
    end

    order =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_business_trip,
          person_id: soldier.person_id,
          data: %{
            "destination" => "Lviv",
            "purpose" => "Course",
            "startDate" => "2026-09-01",
            "endDate" => "2026-09-03",
            "transport" => "public_transport"
          }
        },
        actor: hr
      )
      |> Ash.create!(actor: hr)
      |> run.(:submit, hr, %{assignees: [[hr.id], [commander.id]]})
      |> run.(:approve, hr, %{})
      |> run.(:sign, commander, %{})

    {:ok, page, _} = live(authenticated_conn(conn, soldier), ~p"/documents/#{order.id}")

    {:error, {:live_redirect, %{to: path}}} =
      page |> element("#trip-report-button") |> render_click()

    report =
      Ash.get!(Document, path |> String.split("/") |> List.last(),
        authorize?: false,
        load: [:data]
      )

    assert report.type == :business_trip_report and report.basis_id == order.id
    assert %{"destination" => "Lviv", "startDate" => "2026-09-01"} = report.data

    # Not offered in the general "New request" list.
    {:ok, tasks, _} = live(authenticated_conn(build_conn(), soldier), ~p"/tasks")
    refute has_element?(tasks, "#new-request-type option[value='business_trip_report']")
  end
end
