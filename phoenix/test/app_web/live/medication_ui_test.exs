defmodule AppWeb.MedicationUiTest do
  @moduledoc "docs/design/clinical-medications.md: given medications on the person page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.People.PersonRecord

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Patient"}) |> assign_fixture(unit)
    record_fixture(patient, :allergy_intolerance)
    medic = unit_user_fixture(:viewer, [:combat_medic], unit)
    %{conn: authenticated_conn(conn, medic), patient: patient}
  end

  test "current medications in the status strip, blood thinners flagged",
       %{conn: conn, patient: patient} do
    record_fixture(patient, :medication_statement)

    record_fixture(
      patient,
      :medication_statement,
      Map.merge(App.Demo.sample_record_data(:medication_statement), %{
        "medication" => %{"text" => "Cetirizine"},
        "frequency" => "once_daily"
      })
    )

    stopped =
      Map.merge(App.Demo.sample_record_data(:medication_statement), %{
        "medication" => %{"text" => "Metformin"},
        "adherence" => "stopped"
      })

    record_fixture(patient, :medication_statement, stopped)

    {:ok, _view, html} = live(conn, ~p"/people/#{patient.id}")

    assert html =~ "2 medications"
    assert html =~ "blood thinner"
    assert html =~ "Apixaban 5 mg, Twice a day"
    refute html =~ "Metformin 5 mg"
  end

  test "the form suggests drugs, warns about an allergy, and the card keeps the warning",
       %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/people/#{patient.id}")
    view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

    view
    |> element(~s(#record-kind-picker button[phx-value-kind="medication_administration"]))
    |> render_click()

    assert has_element?(view, ~s(datalist option[value="Tranexamic acid"]))
    refute has_element?(view, "#medication-allergy-warning")

    html =
      view
      |> form("#record-form", %{"record_data" => %{"medication" => %{"text" => "Amoxicillin"}}})
      |> render_change()

    assert html =~ "This drug matches a recorded allergy"
    assert html =~ "Penicillin"

    view
    |> form("#record-form", %{
      "record_data" => %{
        "medication" => %{"text" => "Amoxicillin"},
        "dose" => %{"value" => "1", "unit" => "g"},
        "route" => "po",
        "status" => "completed"
      }
    })
    |> render_submit(%{"record_data" => %{"occurrence" => "2026-09-28T09:15"}})

    saved =
      PersonRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.kind == :medication_administration))

    assert saved.data["allergyWarning"] == "Penicillin"

    render_async(view)
    card = view |> element("#record-#{saved.id}") |> render()
    assert card =~ "Allergy warning"
    assert card =~ "1 g"
    assert card =~ "By mouth (PO)"
  end
end
