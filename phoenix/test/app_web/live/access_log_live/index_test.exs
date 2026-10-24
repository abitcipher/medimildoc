defmodule AppWeb.AccessLogLive.IndexTest do
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.Fixtures

  test "the CISO sees who read what", %{conn: conn} do
    unit = org_fixture("Unit")
    person = person_fixture() |> assign_fixture(unit)
    record = record_fixture(person, :medical_condition)
    clinician = unit_user_fixture(:viewer, [:clinician], unit)
    Ash.get!(App.People.PersonRecord, record.id, actor: clinician)

    {:ok, view, _html} =
      live(authenticated_conn(conn, user_fixture(:viewer, [:ciso])), ~p"/access-log")

    html = render_async(view, 2_000)

    assert html =~ to_string(clinician.email)
    assert html =~ "medical_condition"
  end

  test "the CISO reviews emergency accesses", %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    patient = person_fixture() |> assign_fixture(org_fixture("Their unit"))
    clinician = unit_user_fixture(:viewer, [:clinician], org_fixture("My unit"))

    grant =
      App.Audit.EmergencyAccess
      |> Ash.Changeset.for_create(
        :invoke,
        %{person_id: patient.id, reason: "Casualty at Role 2, allergy check"},
        actor: clinician
      )
      |> Ash.create!()

    {:ok, view, _html} =
      live(authenticated_conn(conn, user_fixture(:viewer, [:ciso])), ~p"/access-log")

    assert has_element?(view, "#emergency-#{grant.id}", "Casualty at Role 2")
    assert has_element?(view, "h2", "1 to review")

    view
    |> element(~s(#emergency-#{grant.id} button[phx-click="review_emergency"]))
    |> render_click()

    assert has_element?(view, "#emergency-#{grant.id}", "Reviewed by")
    refute has_element?(view, "h2", "to review")
  end

  test "HR is sent away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(authenticated_conn(conn, user_fixture(:hr)), ~p"/access-log")
  end
end
