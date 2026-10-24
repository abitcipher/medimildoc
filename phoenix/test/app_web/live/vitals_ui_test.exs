defmodule AppWeb.VitalsUiTest do
  @moduledoc "docs/design/clinical-module.md: vital signs on the person page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.People.PersonRecord

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Patient"}) |> assign_fixture(unit)
    medic = unit_user_fixture(:viewer, [:combat_medic], unit)
    %{conn: authenticated_conn(conn, medic), patient: patient}
  end

  defp vitals(patient, changes) do
    data = Map.merge(App.Demo.sample_record_data(:vital_signs), changes)
    record_fixture(patient, :vital_signs, data)
  end

  test "latest vitals with trends, flags and NEWS2 in the header and panel",
       %{conn: conn, patient: patient} do
    vitals(patient, %{"measuredAt" => "2026-09-27T08:00", "heartRate" => 88})
    # RR 26 (3) + SBP 95 (2) + HR 112 (2) = NEWS2 7, high risk
    vitals(patient, %{
      "measuredAt" => "2026-09-27T12:00",
      "respiratoryRate" => 26,
      "systolic" => 95,
      "heartRate" => 112
    })

    {:ok, view, html} = live(conn, ~p"/people/#{patient.id}")

    assert html =~ "NEWS2 7"
    panel = view |> element("#vitals-panel") |> render()
    assert panel =~ "27.09.2026 12:00"
    assert panel =~ "2 sets"
    assert panel =~ ~r/text-error[^>]*>\s*112/
    assert panel =~ "<svg"
    assert panel =~ "(above normal)"
  end

  test "a set is saved within an encounter from the form", %{conn: conn, patient: patient} do
    encounter = record_fixture(patient, :encounter)
    {:ok, view, _html} = live(conn, ~p"/people/#{patient.id}")

    view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

    view
    |> element(~s(#record-kind-picker button[phx-value-kind="vital_signs"]))
    |> render_click()

    assert has_element?(view, ~s(select[name="record_part_of"] option[value="#{encounter.id}"]))

    # Choose the encounter first, then keep typing: the choice must survive
    # the re-renders of later changes.
    view |> form("#record-form", %{"record_part_of" => encounter.id}) |> render_change()
    view |> form("#record-form", %{"record_data" => %{"heartRate" => "140"}}) |> render_change()

    view
    |> form("#record-form", %{"record_data" => %{"heartRate" => "140", "spo2" => "90"}})
    |> render_submit(%{"record_data" => %{"measuredAt" => "2026-09-27T14:05"}})

    saved = PersonRecord |> Ash.read!(authorize?: false) |> Enum.find(&(&1.kind == :vital_signs))
    assert saved.part_of_id == encounter.id
    assert %{"heartRate" => 140, "spo2" => 90, "measuredAt" => "2026-09-27T14:05"} = saved.data
  end
end
