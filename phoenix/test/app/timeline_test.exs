defmodule App.TimelineTest do
  @moduledoc "docs/design/search-timeline-notifications.md §Timeline."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.{Assignment, Position}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    person = person_fixture(%{given_name: "Olena"}) |> assign_fixture(unit)

    %{
      unit: unit,
      person: person,
      viewer: user_fixture(:viewer),
      clinician: unit_user_fixture(:viewer, [:clinician], unit)
    }
  end

  defp kinds(entries), do: Enum.map(entries, &{&1.date, &1.kind})

  test "records are dated by their data, and each viewer sees only what they may read", ctx do
    rank =
      record_fixture(ctx.person, :rank_history, %{
        "grade" => "OR-4",
        "effectiveDate" => "2024-05-01"
      })

    condition =
      record_fixture(ctx.person, :medical_condition, %{
        "code" => %{"text" => "Asthma"},
        "clinicalStatus" => "active",
        "verificationStatus" => "confirmed",
        "onsetDate" => "2025-02-10"
      })

    assert rank.effective_on == ~D[2024-05-01]
    assert condition.effective_on == ~D[2025-02-10]

    for_clinician = App.Timeline.for_person(ctx.person.id, ctx.clinician)
    for_viewer = App.Timeline.for_person(ctx.person.id, ctx.viewer)

    assert {~D[2025-02-10], :record} in kinds(for_clinician)
    refute {~D[2025-02-10], :record} in kinds(for_viewer)
    assert {~D[2024-05-01], :record} in kinds(for_viewer)

    # Newest first.
    dates = Enum.map(for_clinician, & &1.date)
    assert dates == Enum.sort(dates, {:desc, Date})
  end

  test "an assignment appears when it starts and when it ends", ctx do
    position =
      Position
      |> Ash.Changeset.for_create(:create, %{title: "Medic", organization_id: ctx.unit.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: ctx.person.id,
        position_id: position.id,
        starts_on: ~D[2023-01-10],
        ends_on: ~D[2023-12-31]
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    entries = kinds(App.Timeline.for_person(ctx.person.id, ctx.viewer))
    assert {~D[2023-12-31], :assignment_end} in entries
    assert {~D[2023-01-10], :assignment_start} in entries
  end
end
