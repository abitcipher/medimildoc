defmodule AppWeb.PersonnelOrdersUiTest do
  @moduledoc "Personnel orders on screen: the post dropdown, the order behind an assignment, direct changes for audit."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.People.{Assignment, Position}

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)

    rifleman =
      Position
      |> Ash.Changeset.for_create(:create, %{title: "Rifleman", organization_id: company.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    %{
      conn: conn,
      person: person_fixture(%{given_name: "Newcomer"}),
      rifleman: rifleman,
      hr: user_fixture(:hr),
      hr_head: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], brigade)
    }
  end

  test "an appointment order made on screen creates the assignment, which shows its order",
       %{
         conn: conn,
         person: person,
         rifleman: rifleman,
         hr: hr,
         hr_head: hr_head,
         commander: commander
       } do
    {:ok, view, _html} = live(authenticated_conn(conn, hr), ~p"/people/#{person.id}")

    {:error, {:live_redirect, %{to: "/documents/" <> id}}} =
      view
      |> form("#new-document-form", %{"type" => "personnel_order_appointment"})
      |> render_submit()

    {:ok, view, html} = live(authenticated_conn(conn, hr), "/documents/#{id}")
    assert html =~ ~s(<option value="#{rifleman.id}">)

    view
    |> form("#document-form", %{
      "data" => %{"position" => rifleman.id, "effectiveDate" => "2026-10-01"}
    })
    |> render_submit()

    # The commander of the post's unit is offered as signatory.
    view
    |> form("#submit-form", %{"step_0" => hr_head.id, "step_1" => commander.id})
    |> render_submit()

    {:ok, view, _} = live(authenticated_conn(conn, hr_head), "/documents/#{id}")
    view |> form("#decision-form") |> render_submit(%{"decision" => "approve"})

    {:ok, view, _} = live(authenticated_conn(conn, commander), "/documents/#{id}")
    html = view |> form("#decision-form") |> render_submit(%{"decision" => "sign"})
    assert html =~ "1-ос"
    assert html =~ "Rifleman"

    {:ok, _view, html} = live(authenticated_conn(conn, hr), ~p"/people/#{person.id}")
    assert html =~ "№ 1-ос"
  end

  test "direct changes are listed for audit", %{
    conn: conn,
    person: person,
    rifleman: rifleman,
    hr: hr
  } do
    Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, position_id: rifleman.id, starts_on: ~D[2026-09-01]},
      actor: hr
    )
    |> Ash.create!(actor: hr)

    {:ok, view, _html} =
      live(authenticated_conn(conn, user_fixture(:viewer, [:ciso])), ~p"/change-conflicts")

    html = render_async(view)
    assert html =~ "Direct changes (without an order)"
    assert html =~ to_string(hr.email)
    assert html =~ "starts_on"
  end
end
