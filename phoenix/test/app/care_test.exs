defmodule App.CareTest do
  @moduledoc "docs/design/referral-discharge.md: providers, referral → discharge summary → sick leave."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Care.Provider
  alias App.Documents.Document
  alias App.People.PersonRecord

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    battalion = org_fixture("1st Battalion", brigade)
    hospital = org_fixture("Role 3 Field Hospital", brigade)
    elsewhere = org_fixture("Elsewhere")
    patient = person_fixture(%{given_name: "Patient"}) |> assign_fixture(battalion)

    %{
      patient: patient,
      clinician: unit_user_fixture(:viewer, [:clinician], battalion),
      head: unit_user_fixture(:viewer, [:head_of_department], hospital),
      other_head: unit_user_fixture(:viewer, [:head_of_department], elsewhere),
      role3:
        provider!(%{name: "Role 3 Field Hospital", priority: true, organization_id: hospital.id}),
      external: provider!(%{name: "Regional Hospital", agreement_ref: "AGR-1"})
    }
  end

  defp provider!(attrs) do
    Provider
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp readable?(document, actor),
    do: Document |> Ash.Query.filter(id == ^document.id) |> Ash.read!(actor: actor) != []

  test "the register: everyone who reads people sees it, providers.manage edits it", ctx do
    viewer = user_fixture(:viewer)
    registrar = user_fixture(:viewer, [:registrar])

    assert length(Ash.read!(Provider, actor: viewer)) == 2

    assert {:error, %Ash.Error.Forbidden{}} =
             Provider
             |> Ash.Changeset.for_create(:create, %{name: "Clinic"}, actor: viewer)
             |> Ash.create(actor: viewer)

    assert {:ok, _} =
             Provider
             |> Ash.Changeset.for_create(:create, %{name: "Clinic", provider_type: :clinic},
               actor: registrar
             )
             |> Ash.create(actor: registrar)

    assert ctx.role3.priority
  end

  test "referral → discharge summary in the hospital → sick leave as an absence", ctx do
    {:ok, referral} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :care_referral,
          person_id: ctx.patient.id,
          data: %{
            "provider" => ctx.role3.id,
            "service" => "hospitalization",
            "priority" => "urgent",
            "reason" => "Knee injury",
            "reasonCode" => "S83.2",
            "plannedDate" => "2026-10-01"
          }
        },
        actor: ctx.clinician
      )
      |> Ash.create(actor: ctx.clinician)

    {:ok, referral} = run(referral, :submit, ctx.clinician, %{assignees: [[ctx.clinician.id]]})
    assert {:ok, referral} = run(referral, :sign, ctx.clinician)
    assert referral.number == "1-напр"

    [summary] =
      Document
      |> Ash.Query.filter(type == :discharge_summary)
      |> Ash.read!(authorize?: false)

    assert summary.state == :draft and summary.basis_id == referral.id
    assert summary.handling_unit_id == ctx.role3.organization_id

    # The patient is not in the hospital's unit; the hospital handles the summary.
    assert readable?(summary, ctx.head)
    refute readable?(summary, ctx.other_head)

    data = %{
      "provider" => ctx.role3.id,
      "careType" => "inpatient",
      "admissionDate" => "2026-10-01",
      "dischargeDate" => "2026-10-08",
      "diagnosis" => "Tear of meniscus",
      "diagnosisCode" => "S83.2",
      "outcome" => "improved",
      "recommendations" => "Physiotherapy",
      "sickLeaveFrom" => "2026-10-09",
      "sickLeaveTo" => "2026-10-22"
    }

    {:ok, summary} = run(summary, :update_fields, ctx.head, %{data: data})

    assert {:error, _} =
             run(summary, :submit, ctx.head, %{
               assignees: [[ctx.clinician.id], [ctx.other_head.id]]
             })

    {:ok, summary} =
      run(summary, :submit, ctx.head, %{assignees: [[ctx.clinician.id], [ctx.head.id]]})

    {:ok, summary} = run(summary, :approve, ctx.clinician)
    assert {:ok, summary} = run(summary, :sign, ctx.head)
    assert summary.number == "1-вип"

    [leave] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^ctx.patient.id and kind == :leave)
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)

    # The absence, not the diagnosis.
    assert leave.data == %{
             "leaveType" => "sick",
             "startDate" => "2026-10-09",
             "endDate" => "2026-10-22",
             "days" => 14,
             "basis" => "1-вип"
           }
  end

  test "sick leave needs a whole, ordered period", ctx do
    {:ok, summary} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :discharge_summary,
          person_id: ctx.patient.id,
          data: %{
            "provider" => ctx.external.id,
            "careType" => "outpatient",
            "admissionDate" => "2026-10-01",
            "dischargeDate" => "2026-10-01",
            "diagnosis" => "Sprain",
            "outcome" => "recovered",
            "sickLeaveFrom" => "2026-10-02"
          }
        },
        actor: ctx.clinician
      )
      |> Ash.create(actor: ctx.clinician)

    assert {:error, error} =
             run(summary, :submit, ctx.clinician, %{
               assignees: [[ctx.clinician.id], [ctx.head.id]]
             })

    assert Exception.message(error) =~ "Sick leave needs both its first and last day"
  end
end
