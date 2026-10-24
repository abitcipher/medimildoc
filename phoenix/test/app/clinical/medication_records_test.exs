defmodule App.Clinical.MedicationRecordsTest do
  @moduledoc "docs/design/clinical-medications.md: given medications and procedures."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.PersonRecord

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Patient"}) |> assign_fixture(unit)
    medic = unit_user_fixture(:viewer, [:combat_medic], unit)
    %{patient: patient, medic: medic, encounter: record_fixture(patient, :encounter)}
  end

  defp give(actor, patient, encounter, drug) do
    data =
      Map.put(App.Demo.sample_record_data(:medication_administration), "medication", %{
        "text" => drug
      })

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: patient.id,
        kind: :medication_administration,
        data: data,
        part_of_id: encounter.id
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  test "a medic records a drug: coded from the list, warned about the allergy, not blocked",
       %{patient: patient, medic: medic, encounter: encounter} do
    record_fixture(patient, :allergy_intolerance)

    assert {:ok, record} = give(medic, patient, encounter, "Amoxicillin")
    record = Ash.get!(PersonRecord, record.id, actor: medic)

    assert %{
             "medication" => %{
               "text" => "Amoxicillin",
               "coding" => [%{"system" => "urn:hrda:drug", "code" => "amoxicillin"}]
             },
             "allergyWarning" => "Penicillin"
           } = record.data

    # Changed to an unlisted drug with no allergy: code and warning go.
    {:ok, record} =
      record
      |> Ash.Changeset.for_update(
        :update,
        %{data: Map.put(record.data, "medication", %{"text" => "Novamab"})},
        actor: medic
      )
      |> Ash.update(actor: medic)

    data = Ash.get!(PersonRecord, record.id, actor: medic).data
    refute Map.has_key?(data, "allergyWarning")
    assert data["medication"] == %{"text" => "Novamab"}
  end

  test "the warning can't be written from the form", %{
    patient: patient,
    medic: medic,
    encounter: encounter
  } do
    data =
      App.Demo.sample_record_data(:medication_administration)
      |> Map.put("allergyWarning", "made up")

    {:ok, record} =
      PersonRecord
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: patient.id,
          kind: :medication_administration,
          data: data,
          part_of_id: encounter.id
        },
        actor: medic
      )
      |> Ash.create(actor: medic)

    refute Map.has_key?(Ash.get!(PersonRecord, record.id, actor: medic).data, "allergyWarning")
  end

  test "a procedure within the encounter", %{patient: patient, medic: medic, encounter: encounter} do
    assert {:ok, _} =
             PersonRecord
             |> Ash.Changeset.for_create(
               :create,
               %{
                 person_id: patient.id,
                 kind: :procedure,
                 data: App.Demo.sample_record_data(:procedure),
                 part_of_id: encounter.id
               },
               actor: medic
             )
             |> Ash.create(actor: medic)
  end

  test "a current medication: coded, checked against allergies, readable by the medic",
       %{patient: patient, medic: medic} do
    record_fixture(patient, :allergy_intolerance)

    data =
      App.Demo.sample_record_data(:medication_statement)
      |> Map.put("medication", %{"text" => "Amoxicillin"})

    {:ok, record} =
      PersonRecord
      |> Ash.Changeset.for_create(
        :create,
        %{person_id: patient.id, kind: :medication_statement, data: data},
        actor: medic
      )
      |> Ash.create(actor: medic)

    data = Ash.get!(PersonRecord, record.id, actor: medic).data
    assert [%{"code" => "amoxicillin"}] = data["medication"]["coding"]
    assert data["allergyWarning"] == "Penicillin"
  end

  test "outside the medic's unit nothing can be recorded", %{
    patient: patient,
    encounter: encounter
  } do
    outsider = unit_user_fixture(:viewer, [:combat_medic], org_fixture("Elsewhere"))
    assert {:error, %Ash.Error.Forbidden{}} = give(outsider, patient, encounter, "Ketamine")
  end

  test "a drug meeting what the person takes or was just given gets an interaction warning",
       %{patient: patient, medic: medic, encounter: encounter} do
    # On the medication list: warfarin, taken.
    record_fixture(patient, :medication_statement, %{
      "medication" => %{
        "text" => "Warfarin",
        "coding" => [%{"system" => "urn:hrda:drug", "code" => "warfarin"}]
      },
      "adherence" => "taking"
    })

    assert {:ok, record} = give(medic, patient, encounter, "Ibuprofen")
    record = Ash.get!(PersonRecord, record.id, actor: medic)
    assert record.data["interactionWarning"] == "Warfarin — bleeding risk (major)"

    # Paracetamol meets nothing listed.
    assert {:ok, plain} = give(medic, patient, encounter, "Paracetamol")
    refute Map.has_key?(Ash.get!(PersonRecord, plain.id, actor: medic).data, "interactionWarning")

    # Given an hour ago counts; a stopped medicine doesn't.
    zone = Application.get_env(:app, :app_time_zone, "Etc/UTC")

    hour_ago =
      DateTime.now!(zone, Tz.TimeZoneDatabase) |> DateTime.add(-1, :hour, Tz.TimeZoneDatabase)

    data =
      App.Demo.sample_record_data(:medication_administration)
      |> Map.put("medication", %{"text" => "Morphine"})
      |> Map.put("occurrence", Calendar.strftime(hour_ago, "%Y-%m-%dT%H:%M"))
      |> Map.put("status", "completed")

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: patient.id,
        kind: :medication_administration,
        data: data,
        part_of_id: encounter.id
      },
      actor: medic
    )
    |> Ash.create!(actor: medic)

    assert {:ok, sedative} = give(medic, patient, encounter, "Midazolam")

    assert Ash.get!(PersonRecord, sedative.id, actor: medic).data["interactionWarning"] =~
             "Morphine — respiratory depression (major)"
  end
end
