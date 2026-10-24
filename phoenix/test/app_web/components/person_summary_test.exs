defmodule AppWeb.PersonSummaryTest do
  @moduledoc "Person page status chips (docs/design/ui-plan.md item 3)."
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import App.Fixtures

  alias AppWeb.PersonSummary

  setup do
    App.Access.put_admin_full_data_access_override(false)
    :ok

    unit = org_fixture("Unit")
    person = person_fixture() |> assign_fixture(unit)

    record_fixture(person, :fitness_for_duty, %{
      "status" => "downgraded",
      "restrictions" => "No field duty"
    })

    record_fixture(person, :security_clearance, %{
      "clearanceLevel" => "NATO_SECRET",
      "status" => "granted",
      "expiryDate" => "2020-01-01"
    })

    record_fixture(person, :allergy_intolerance, %{
      "code" => %{"text" => "Penicillin"},
      "clinicalStatus" => "active",
      "criticality" => "high"
    })

    record_fixture(person, :allergy_intolerance, %{
      "code" => %{"text" => "Latex"},
      "clinicalStatus" => "resolved"
    })

    %{person: person, unit: unit}
  end

  defp chips(summary), do: render_component(&PersonSummary.status_chips/1, summary: summary)

  test "each chip appears only for what the viewer may read", %{person: person, unit: unit} do
    commander =
      PersonSummary.summary_records(person, unit_user_fixture(:viewer, [:line_commander], unit))

    assert commander.fitness
    refute commander.clearance
    assert commander.allergies == []

    clinician =
      PersonSummary.summary_records(person, unit_user_fixture(:viewer, [:clinician], unit))

    assert [%{data: %{"code" => %{"text" => "Penicillin"}}}] = clinician.allergies

    viewer = PersonSummary.summary_records(person, user_fixture(:viewer))
    assert chips(viewer) =~ ~s(aria-label="Status")
    refute chips(viewer) =~ "badge"
  end

  test "chips carry state in text and icon, not only colour", %{person: person, unit: unit} do
    html =
      chips(PersonSummary.summary_records(person, unit_user_fixture(:hr, [:clinician], unit)))

    assert html =~ "Downgraded"
    assert html =~ "No field duty"
    assert html =~ "NATO SECRET"
    assert html =~ "expired"
    assert html =~ "Penicillin"
    refute html =~ "Latex"
    assert html =~ ~s(role="alert")
  end
end
