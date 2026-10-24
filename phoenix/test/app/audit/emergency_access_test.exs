defmodule App.Audit.EmergencyAccessTest do
  @moduledoc "Break the Glass (docs/design/access-control-phase2.md)."
  use App.DataCase, async: true

  require Ash.Query

  alias App.Audit.{AccessLog, EmergencyAccess}
  alias App.People.PersonRecord

  setup do
    App.Access.put_admin_full_data_access_override(false)

    patient =
      person_fixture(%{given_name: "Patient"}) |> assign_fixture(org_fixture("Other unit"))

    allergy = record_fixture(patient, :allergy_intolerance)
    record_fixture(patient, :medical_condition)

    bystander = person_fixture() |> assign_fixture(org_fixture("Third unit"))
    record_fixture(bystander, :allergy_intolerance)

    clinician = unit_user_fixture(:viewer, [:clinician], org_fixture("My unit"))

    %{patient: patient, allergy: allergy, clinician: clinician}
  end

  defp invoke(actor, person, reason \\ "Casualty at Role 2, allergy check") do
    EmergencyAccess
    |> Ash.Changeset.for_create(:invoke, %{person_id: person.id, reason: reason}, actor: actor)
    |> Ash.create()
  end

  defp clinical(actor) do
    PersonRecord
    |> Ash.Query.filter(kind in [:allergy_intolerance, :medical_condition])
    |> Ash.read!(actor: actor)
  end

  test "outside the unit a clinician sees nothing clinical until they break the glass", %{
    patient: patient,
    allergy: allergy,
    clinician: clinician
  } do
    assert clinical(clinician) == []

    assert {:ok, grant} = invoke(clinician, patient)
    assert grant.actor_id == clinician.id
    assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :minute) in 59..60

    # Only that person's allergies: not their diagnoses, not anyone else.
    assert [%{id: id}] = clinical(clinician)
    assert id == allergy.id

    assert [%{reason: "Emergency access: Casualty at Role 2, allergy check"}] =
             AccessLog
             |> Ash.Query.filter(record_id == ^allergy.id)
             |> Ash.read!(authorize?: false)
  end

  test "access ends when the grant expires", %{patient: patient, clinician: clinician} do
    {:ok, grant} = invoke(clinician, patient)

    App.Repo.query!(
      "UPDATE emergency_accesses SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [Ecto.UUID.dump!(grant.id)]
    )

    assert clinical(clinician) == []
  end

  test "only btg.invoke may break the glass, and only with a real reason", %{
    patient: patient,
    clinician: clinician
  } do
    assert {:error, %Ash.Error.Forbidden{}} = invoke(user_fixture(:hr), patient)
    assert {:error, %Ash.Error.Invalid{}} = invoke(clinician, patient, "urgent")
  end

  test "the CISO sees and reviews every grant; others see only their own", %{
    patient: patient,
    clinician: clinician
  } do
    {:ok, grant} = invoke(clinician, patient)
    other = unit_user_fixture(:viewer, [:clinician], org_fixture("Yet another"))
    ciso = user_fixture(:viewer, [:ciso])

    assert [_] = Ash.read!(EmergencyAccess, actor: clinician)
    assert [] = Ash.read!(EmergencyAccess, actor: other)
    assert [_] = Ash.read!(EmergencyAccess, actor: ciso)

    assert {:error, %Ash.Error.Forbidden{}} =
             grant |> Ash.Changeset.for_update(:review, %{}, actor: clinician) |> Ash.update()

    reviewed = grant |> Ash.Changeset.for_update(:review, %{}, actor: ciso) |> Ash.update!()
    assert reviewed.reviewed_by_email == to_string(ciso.email)
    assert reviewed.reviewed_at
  end
end
