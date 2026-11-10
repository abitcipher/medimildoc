defmodule App.Clinical.LabResultsTest do
  @moduledoc "docs/design/lab-results.md: lab results interpreted by the server, read as medical data."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.Clinical.Changes.InterpretLab
  alias App.Clinical.LabTests
  alias App.People.PersonRecord

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")

    %{
      patient: person_fixture(%{given_name: "Patient"}) |> assign_fixture(unit),
      clinician: unit_user_fixture(:viewer, [:clinician], unit),
      medic: unit_user_fixture(:viewer, [:combat_medic], unit)
    }
  end

  defp result(ctx, actor, test, value, at) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: ctx.patient.id,
        kind: :lab_result,
        data: %{"test" => test, "value" => value, "collectedAt" => at, "unit" => "forged"}
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  test "interpretation against the reference range (pure)" do
    potassium = LabTests.get("potassium")
    assert LabTests.interpret(potassium, 3.2) == "low"
    assert LabTests.interpret(potassium, 4.2) == "normal"
    assert LabTests.interpret(potassium, 5.6) == "high"
    assert LabTests.range(potassium) == "3.5–5.1"
    assert LabTests.range(LabTests.get("hemoglobin")) == "120–170"

    assert %{"unit" => "mmol/L", "interpretation" => "high"} =
             InterpretLab.interpret(%{"test" => "potassium", "value" => "5,6"})
  end

  test "numbers print without float noise" do
    assert LabTests.number(4.1 + 0.3) == "4.4"
    assert LabTests.number(4.0) == "4"
    assert LabTests.number(125) == "125"
    assert AppWeb.RecordComponents.format_value(%{unit: "mmol/L"}, 4.1 + 0.3) == "4.4 mmol/L"
    assert AppWeb.RecordComponents.format_value(%{}, 0.1 + 0.2) == "0.3"
  end

  test "the server sets unit, range, flag and the previous value; the form can't", ctx do
    {:ok, _} = result(ctx, ctx.clinician, "hemoglobin", 131, "2026-09-01T08:00")
    {:ok, later} = result(ctx, ctx.clinician, "hemoglobin", 112, "2026-10-01T08:00")
    # An earlier sample entered afterwards compares with what came before it.
    {:ok, earliest} = result(ctx, ctx.clinician, "hemoglobin", 140, "2026-08-01T08:00")

    later = Ash.get!(PersonRecord, later.id, actor: ctx.clinician)

    assert %{
             "unit" => "g/L",
             "referenceRange" => "120–170",
             "interpretation" => "low",
             "previous" => "131 (2026-09-01 08:00)"
           } = later.data

    refute Map.has_key?(
             Ash.get!(PersonRecord, earliest.id, actor: ctx.clinician).data,
             "previous"
           )
  end

  test "lab results are medical data: the combat medic neither reads nor writes them", ctx do
    {:ok, record} = result(ctx, ctx.clinician, "crp", 2, "2026-09-01T08:00")
    assert {:error, _} = Ash.get(PersonRecord, record.id, actor: ctx.medic)
    assert {:error, %Ash.Error.Forbidden{}} = result(ctx, ctx.medic, "crp", 3, "2026-09-02T08:00")
  end
end
