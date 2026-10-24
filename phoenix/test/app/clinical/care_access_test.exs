defmodule App.Clinical.CareAccessTest do
  @moduledoc "docs/design/clinical-module.md: point-of-care access and records."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.{PersonRecord, PersonRecordSchema}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Patient"}) |> assign_fixture(unit)
    %{unit: unit, patient: patient}
  end

  defp sample(kind, changes), do: Map.merge(App.Demo.sample_record_data(kind), changes)

  defp create(actor, person, kind, data, extra \\ %{}) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{person_id: person.id, kind: kind, data: data}, extra),
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp kinds(actor),
    do: PersonRecord |> Ash.read!(actor: actor) |> Enum.map(& &1.kind) |> Enum.sort()

  test "a combat medic records encounters and vitals but never sees the clinical history",
       %{unit: unit, patient: patient} do
    medic = unit_user_fixture(:viewer, [:combat_medic], unit)
    record_fixture(patient, :medical_condition)
    record_fixture(patient, :allergy_intolerance)

    assert {:ok, encounter} = create(medic, patient, :encounter, sample(:encounter, %{}))

    assert {:ok, _vitals} =
             create(medic, patient, :vital_signs, sample(:vital_signs, %{}), %{
               part_of_id: encounter.id
             })

    assert {:error, %Ash.Error.Forbidden{}} =
             create(
               medic,
               patient,
               :medical_condition,
               App.Demo.sample_record_data(:medical_condition)
             )

    # Only the patient's records (the medic's own person has records too).
    readable =
      PersonRecord
      |> Ash.read!(actor: medic)
      |> Enum.filter(&(&1.person_id == patient.id))
      |> Enum.map(& &1.kind)
      |> Enum.sort()

    assert readable == [:allergy_intolerance, :encounter, :vital_signs]
  end

  test "a nurse reads the clinical history but can't change it", %{unit: unit, patient: patient} do
    nurse = unit_user_fixture(:viewer, [:nurse], unit)
    record_fixture(patient, :medical_condition)

    assert :medical_condition in kinds(nurse)

    assert {:error, %Ash.Error.Forbidden{}} =
             create(
               nurse,
               patient,
               :medical_condition,
               App.Demo.sample_record_data(:medical_condition)
             )

    assert {:ok, _} = create(nurse, patient, :vital_signs, sample(:vital_signs, %{}))
  end

  test "outside their unit a medic sees nothing", %{patient: patient} do
    medic = unit_user_fixture(:viewer, [:combat_medic], org_fixture("Elsewhere"))
    record_fixture(patient, :vital_signs)

    refute Enum.any?(Ash.read!(PersonRecord, actor: medic), &(&1.person_id == patient.id))
  end

  test "reading vital signs is in the access log", %{unit: unit, patient: patient} do
    medic = unit_user_fixture(:viewer, [:combat_medic], unit)
    vitals = record_fixture(patient, :vital_signs)

    Ash.get!(PersonRecord, vitals.id, actor: medic)

    assert Enum.any?(
             Ash.read!(App.Audit.AccessLog, authorize?: false),
             &(&1.record_id == vitals.id and &1.kind == "vital_signs")
           )
  end

  test "vital signs belong only to an encounter of the same person", %{patient: patient} do
    encounter = record_fixture(patient, :encounter)
    other_encounter = record_fixture(person_fixture(), :encounter)
    allergy = record_fixture(patient, :allergy_intolerance)
    data = App.Demo.sample_record_data(:vital_signs)

    assert {:ok, vitals} =
             PersonRecord
             |> Ash.Changeset.for_create(
               :create,
               %{person_id: patient.id, kind: :vital_signs, data: data, part_of_id: encounter.id},
               authorize?: false
             )
             |> Ash.create(authorize?: false)

    assert vitals.part_of_id == encounter.id

    for parent <- [other_encounter, allergy] do
      assert {:error, %Ash.Error.Invalid{}} =
               PersonRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: patient.id, kind: :vital_signs, data: data, part_of_id: parent.id},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end

    # Deleting the encounter keeps the vital signs, on their own.
    Ash.destroy!(encounter, authorize?: false)
    assert Ash.get!(PersonRecord, vitals.id, authorize?: false).part_of_id == nil
  end

  test "date and time fields take local yyyy-mm-ddTHH:MM only" do
    assert :ok =
             PersonRecordSchema.validate(
               :encounter,
               sample(:encounter, %{"start" => "2026-09-27T14:05"})
             )

    assert {:error, _} =
             PersonRecordSchema.validate(
               :encounter,
               sample(:encounter, %{"start" => "27.09.2026 14:05"})
             )
  end
end
