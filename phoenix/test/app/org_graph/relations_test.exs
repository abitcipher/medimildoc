defmodule App.OrgGraph.RelationsTest do
  @moduledoc "docs/design/org-graph.md, ORG-GRAPH.4: relations between people on the graph."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Audit.AccessLog
  alias App.Care.Provider
  alias App.Documents.{Acknowledgement, Document, Step}
  alias App.Duty.Shift
  alias App.OrgGraph.Relations

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)
    hospital = org_fixture("Role 3", brigade)
    patient = person_fixture(%{given_name: "Pat"}) |> assign_fixture(company)
    buddy = person_fixture(%{given_name: "Bud"}) |> assign_fixture(company)
    clinician = unit_user_fixture(:viewer, [:clinician], company)
    head = unit_user_fixture(:viewer, [:head_of_department], hospital)

    provider =
      Provider
      |> Ash.Changeset.for_create(:create, %{name: "Role 3", organization_id: hospital.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    %{
      company: company,
      patient: patient,
      buddy: buddy,
      clinician: clinician,
      head: head,
      provider: provider
    }
  end

  defp referral(ctx) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :care_referral,
        person_id: ctx.patient.id,
        data: %{
          "provider" => ctx.provider.id,
          "service" => "hospitalization",
          "priority" => "urgent",
          "reason" => "Knee injury",
          "plannedDate" => "2026-10-01"
        }
      },
      actor: ctx.clinician
    )
    |> Ash.create!()
  end

  test "on duty together: the same day in the same unit, counted", ctx do
    for {day, people} <- [
          {2, [ctx.patient, ctx.buddy]},
          {3, [ctx.patient, ctx.buddy]},
          {4, [ctx.patient]}
        ],
        person <- people do
      Ash.Seed.seed!(Shift, %{
        date: Date.new!(2026, 11, day),
        duty_type: "duty_officer",
        person_id: person.id,
        organization_id: ctx.company.id
      })
    end

    ids = [ctx.patient.id, ctx.buddy.id]
    hr = user_fixture(:hr)
    assert %{duty: [{a, b, 2}]} = Relations.load(["duty"], ids, hr, ~D[2026-11-15])
    assert Enum.sort([a, b]) == Enum.sort(ids)
  end

  test "who approved or signed whose document; who acknowledged whose order", ctx do
    document = referral(ctx)

    Ash.Seed.seed!(Step, %{
      document_id: document.id,
      round: 1,
      position: 1,
      action: :sign,
      label: "Sign",
      status: :signed,
      decided_by_id: ctx.head.id
    })

    Ash.Seed.seed!(Acknowledgement, %{
      document_id: document.id,
      person_id: ctx.patient.id,
      acknowledged_on: ~D[2026-10-02],
      method: :self
    })

    ids = [ctx.patient.id, ctx.clinician.person_id, ctx.head.person_id]
    relations = Relations.load(~w(approvals acknowledgements), ids, ctx.clinician)

    # The head signed what the clinician wrote; the patient acknowledged it.
    assert relations.approvals == [{ctx.head.person_id, ctx.clinician.person_id, 1}]
    assert relations.acknowledgements == [{ctx.head.person_id, ctx.patient.id, 1}]
  end

  test "referrals only for who may read them, each written to the access log", ctx do
    referral(ctx)
    ids = [ctx.patient.id]

    assert %{referrals: [{patient, provider}]} = Relations.load(["referrals"], ids, ctx.clinician)
    assert {patient, provider} == {ctx.patient.id, ctx.provider.id}

    assert [%{kind: "org-graph:care_referral"}] =
             AccessLog
             |> Ash.Query.filter(
               actor_id == ^ctx.clinician.id and kind == "org-graph:care_referral"
             )
             |> Ash.read!(authorize?: false)

    assert %{referrals: []} = Relations.load(["referrals"], ids, user_fixture(:viewer))
  end

  test "family: a person's dependants, through their policy", ctx do
    record_fixture(ctx.patient, :dependent, %{"name" => "Kid", "relationship" => "child"})

    assert %{family: [%{name: "Kid", relationship: "child", person_id: person}]} =
             Relations.load(["family"], [ctx.patient.id], user_fixture(:hr))

    assert person == ctx.patient.id
    assert %{family: []} = Relations.load(["family"], [ctx.patient.id], user_fixture(:viewer))
  end
end
