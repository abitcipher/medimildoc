defmodule App.Documents.PersonnelOrdersTest do
  @moduledoc "docs/design/documents-core.md: personnel orders and their effects."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Access, Document, Types}
  alias App.People.{Assignment, Position}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)
    elsewhere = org_fixture("Elsewhere")
    person = person_fixture(%{given_name: "Newcomer"})

    %{
      person: person,
      company: company,
      rifleman: position_fixture("Rifleman", company),
      medic: position_fixture("Combat Medic", company),
      hr: user_fixture(:hr),
      hr_head: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], brigade),
      other_commander: unit_user_fixture(:viewer, [:commander], elsewhere)
    }
  end

  defp position_fixture(title, org) do
    Position
    |> Ash.Changeset.for_create(:create, %{title: title, organization_id: org.id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp order(ctx, type, data) do
    Document
    |> Ash.Changeset.for_create(:create, %{type: type, person_id: ctx.person.id, data: data},
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  # HR sends, the head of HR approves, the commander signs.
  defp through(document, ctx) do
    {:ok, document} =
      run(document, :submit, ctx.hr, %{assignees: [[ctx.hr_head.id], [ctx.commander.id]]})

    {:ok, document} = run(document, :approve, ctx.hr_head)
    run(document, :sign, ctx.commander)
  end

  defp assignments(person) do
    Assignment
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.Query.sort(starts_on: :asc)
    |> Ash.read!(authorize?: false)
  end

  test "appointment, transfer, release: the assignments follow the signed orders", ctx do
    # A newcomer is in no unit yet: the commander of the unit of the post
    # they are appointed to signs.
    appointment =
      order(ctx, :personnel_order_appointment, %{
        "position" => ctx.rifleman.id,
        "effectiveDate" => "2026-10-01"
      })

    assert {:ok, appointment} = through(appointment, ctx)
    assert appointment.number == "1-ос"

    assert [%{position_id: rifleman, starts_on: ~D[2026-10-01], basis_document_id: basis}] =
             assignments(ctx.person)

    assert rifleman == ctx.rifleman.id and basis == appointment.id

    # A second appointment is refused when it is sent.
    again =
      order(ctx, :personnel_order_appointment, %{
        "position" => ctx.medic.id,
        "effectiveDate" => "2026-10-05"
      })

    assert {:error, error} =
             run(again, :submit, ctx.hr, %{assignees: [[ctx.hr_head.id], [ctx.commander.id]]})

    assert Exception.message(error) =~ "already holds a post"

    transfer =
      order(ctx, :personnel_order_transfer, %{
        "position" => ctx.medic.id,
        "effectiveDate" => "2026-10-15"
      })

    assert {:ok, transfer} = through(transfer, ctx)

    assert [old, new] = assignments(ctx.person)
    assert old.ends_on == ~D[2026-10-14] and old.end_document_id == transfer.id
    assert new.position_id == ctx.medic.id and new.basis_document_id == transfer.id

    release =
      order(ctx, :personnel_order_dismissal, %{
        "effectiveDate" => "2026-12-31",
        "reason" => "end_of_contract"
      })

    assert {:ok, release} = through(release, ctx)
    assert release.number == "3-ос"
    assert [_, %{ends_on: ~D[2026-12-31], end_document_id: end_id}] = assignments(ctx.person)
    assert end_id == release.id

    # Orders are not corrections.
    assert Ash.read!(App.Audit.Correction, authorize?: false) == []
  end

  test "a direct change is kept and logged as a correction", ctx do
    assignment =
      Assignment
      |> Ash.Changeset.for_create(
        :create,
        %{person_id: ctx.person.id, position_id: ctx.rifleman.id, starts_on: ~D[2026-09-01]},
        actor: ctx.hr
      )
      |> Ash.create!(actor: ctx.hr)

    assignment
    |> Ash.Changeset.for_update(:update, %{starts_on: ~D[2026-09-02]}, actor: ctx.hr)
    |> Ash.update!(actor: ctx.hr)

    corrections =
      App.Audit.Correction |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!(authorize?: false)

    assert [
             %{action: :create},
             %{action: :update, changes: %{"starts_on" => %{"to" => "2026-09-02"}}}
           ] = corrections

    assert Enum.all?(corrections, &(&1.actor_email == to_string(ctx.hr.email)))

    # The internal order actions are closed to actors.
    assert {:error, %Ash.Error.Forbidden{}} =
             Assignment
             |> Ash.Changeset.for_create(
               :from_order,
               %{person_id: ctx.person.id, position_id: ctx.medic.id, starts_on: ~D[2026-10-01]},
               actor: ctx.hr
             )
             |> Ash.create(actor: ctx.hr)
  end

  test "a commander of another unit is not offered and can't be chosen", ctx do
    Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: ctx.person.id, position_id: ctx.rifleman.id, starts_on: ~D[2026-09-01]},
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)

    entry = List.last(Types.route(:personnel_order_grade))
    document = %{person_id: ctx.person.id, data: %{}}
    ids = Enum.map(Access.eligible_users(entry, document), & &1.id)
    assert ctx.commander.id in ids
    refute ctx.other_commander.id in ids

    grade =
      order(ctx, :personnel_order_grade, %{
        "grade" => "OR-4",
        "gradeTitle" => "Corporal",
        "effectiveDate" => "2026-10-01"
      })

    assert {:error, _} =
             run(grade, :submit, ctx.hr, %{
               assignees: [[ctx.hr_head.id], [ctx.other_commander.id]]
             })

    assert {:ok, grade} = through(grade, ctx)

    [rank] =
      App.People.PersonRecord
      |> Ash.Query.filter(person_id == ^ctx.person.id and kind == :rank_history)
      |> Ash.read!(authorize?: false)

    assert %{"grade" => "OR-4", "gradeTitle" => "Corporal", "note" => number} = rank.data
    assert number == grade.number
  end
end
