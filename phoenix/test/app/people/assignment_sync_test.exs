defmodule App.People.AssignmentSyncTest do
  @moduledoc "docs/design/assignments-sheets.md"
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.People.{Assignment, AssignmentSync, PersonId, Position}

  @today ~D[2026-09-28]

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company, 1 Bn")
    rifleman = position_fixture("Rifleman", unit, "OR-3", 10)
    medic = position_fixture("Combat Medic", unit, "OR-4", 1)
    ann = person_fixture(%{given_name: "Ann", family_name: "Able"})
    bob = person_fixture(%{given_name: "Bob", family_name: "Baker"})
    assign(ann, rifleman, ~D[2026-01-01])
    %{hr: user_fixture(:hr), ann: ann, bob: bob, rifleman: rifleman, medic: medic}
  end

  defp position_fixture(title, org, grade, strength) do
    Position
    |> Ash.Changeset.for_create(
      :create,
      %{title: title, organization_id: org.id, authorised_grade: grade, strength: strength},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp assign(person, position, on) do
    Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, position_id: position.id, starts_on: on},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp sheet(actor), do: AssignmentSync.export(actor).assignments

  # The exported sheet with one person's row changed.
  defp edit(sheet, person, changes) do
    [header | rows] = sheet
    col = fn name -> Enum.find_index(header, &(&1 == name)) end
    code = PersonId.format(person.person_id)

    change = fn row ->
      Enum.reduce(changes, row, fn {k, v}, acc -> List.replace_at(acc, col.(k), v) end)
    end

    [header | Enum.map(rows, &if(hd(&1) == code, do: change.(&1), else: &1))]
  end

  # Drafts about a person, with their fields.
  defp drafts(person) do
    App.Documents.Document
    |> Ash.Query.filter(person_id == ^person.id and state == :draft)
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
  end

  defp current(person) do
    Assignment
    |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
    |> Ash.read_one!(authorize?: false)
  end

  test "export: one row per person, short labels, positions and history, all strings",
       %{hr: hr, ann: ann} do
    %{assignments: [header | rows], positions: positions, history: history} =
      AssignmentSync.export(hr)

    assert header == ["PersonID", "Name", "Unit", "Position", "Since", "Version"]
    ann_row = Enum.find(rows, &(hd(&1) == PersonId.format(ann.person_id)))

    assert ["Ann Able", "A Company, 1 Bn", "Rifleman A.Co¦1Bn¦OR-3", "01.01.2026", _] =
             tl(ann_row)

    assert Enum.all?(List.flatten(rows ++ positions ++ history), &is_binary/1)

    assert ["Combat Medic A.Co¦1Bn¦OR-4", "A Company, 1 Bn", "Combat Medic", "OR-4", "0/1"] in positions

    assert history == [["PersonID", "Name", "Position", "Unit", "Started", "Ended"]]
  end

  test "unchanged sheet: nothing to do", %{hr: hr} do
    plan = AssignmentSync.plan(hr, sheet(hr), @today)
    assert plan.changes == [] and plan.errors == []
  end

  test "a move becomes a draft transfer order; the post changes only when it is signed",
       %{hr: hr, ann: ann, medic: medic, rifleman: rifleman} do
    rows =
      hr
      |> sheet()
      |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4", "Since" => "15.09.2026"})

    plan = AssignmentSync.plan(hr, rows, @today)

    assert [%{kind: :move, on: ~D[2026-09-15], conflict?: false}] = plan.changes
    assert %{drafted: 1, documents: [id], failed: []} = AssignmentSync.apply(hr, plan)

    # Nothing moved yet.
    assert current(ann).position_id == rifleman.id

    assert [%{id: ^id, type: :personnel_order_transfer, author_id: author, data: data}] =
             drafts(ann)

    assert author == hr.id
    assert data == %{"position" => medic.id, "effectiveDate" => "2026-09-15"}

    # The same sheet again drafts nothing twice.
    assert %{drafted: 0, skipped: [{_row, :order_pending}]} =
             AssignmentSync.apply(hr, AssignmentSync.plan(hr, rows, @today))
  end

  test "a move keeping the old Since starts today", %{hr: hr, ann: ann} do
    rows = hr |> sheet() |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4"})

    assert [%{kind: :move, on: @today, notes: ["starts today"]}] =
             AssignmentSync.plan(hr, rows, @today).changes
  end

  test "an old sheet imported again after a move can't overlap the history",
       %{hr: hr, ann: ann, medic: medic} do
    # Ann moved meanwhile (a signed transfer): the old post ended yesterday.
    current(ann)
    |> Ash.Changeset.for_update(:update, %{ends_on: Date.add(@today, -1)}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assign(ann, medic, @today)

    # The sheet edited before the move, imported again: the new post "since
    # 01.01.2026" would overlap the old one.
    stale =
      hr
      |> sheet()
      |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4", "Since" => "01.01.2026"})

    plan = AssignmentSync.plan(hr, stale, @today)
    assert plan.changes == []
    assert [{_row, {:overlaps_previous, ended_on}}] = plan.errors
    assert ended_on == Date.add(@today, -1)
  end

  test "start, end and a corrected start date", %{hr: hr, ann: ann, bob: bob} do
    rows =
      hr
      |> sheet()
      |> edit(bob, %{"Position" => "Rifleman A.Co¦1Bn¦OR-3", "Since" => "2026-09-20"})
      |> edit(ann, %{"Since" => "02.01.2026"})

    assert [%{kind: :redate, on: ~D[2026-01-02]}, %{kind: :start, on: ~D[2026-09-20]}] =
             hr
             |> AssignmentSync.plan(rows, @today)
             |> Map.fetch!(:changes)
             |> Enum.sort_by(& &1.kind)

    # A corrected start date is applied directly.
    redated = hr |> sheet() |> edit(ann, %{"Since" => "02.01.2026"})

    assert %{corrected: 1, drafted: 0} =
             AssignmentSync.apply(hr, AssignmentSync.plan(hr, redated, @today))

    assert current(ann).starts_on == ~D[2026-01-02]

    # A cleared post: a draft release order (its reason left for HR).
    rows = hr |> sheet() |> edit(ann, %{"Position" => ""})
    plan = AssignmentSync.plan(hr, rows, @today)
    assert [%{kind: :end, on: @today}] = plan.changes
    assert %{drafted: 1} = AssignmentSync.apply(hr, plan)
    assert current(ann) != nil

    assert [%{type: :personnel_order_dismissal, data: %{"effectiveDate" => date}}] = drafts(ann)
    assert date == Date.to_iso8601(@today)
  end

  test "errors name the row and skip it", %{hr: hr, ann: ann} do
    [header | rows] =
      hr |> sheet() |> edit(ann, %{"Position" => "Astronaut", "Since" => "31.02.2026"})

    rows = rows ++ [["ZZZZ-ZZZZ-ZZZZ", "", "", "", "", ""], hd(rows)]
    plan = AssignmentSync.plan(hr, [header | rows], @today)

    errors = Enum.map(plan.errors, &elem(&1, 1))
    assert {:unknown_position, "Astronaut"} in errors
    assert :unknown_person in errors
    assert :duplicate_person in errors
    assert plan.changes == []
  end

  test "a row changed after the export: a correction overwrites and is logged, a move is only drafted",
       %{hr: hr, ann: ann} do
    moved =
      hr
      |> sheet()
      |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4", "Since" => "15.09.2026"})

    redated = hr |> sheet() |> edit(ann, %{"Since" => "03.01.2026"})

    # Someone else edits Ann's assignment in the meantime.
    Process.sleep(2)

    current(ann)
    |> Ash.Changeset.for_update(:update, %{starts_on: ~D[2026-01-05]}, authorize?: false)
    |> Ash.update!(authorize?: false)

    plan = AssignmentSync.plan(hr, moved, @today)
    assert [%{conflict?: true}] = plan.changes
    assert %{drafted: 1, conflicts: 0} = AssignmentSync.apply(hr, plan)
    assert Ash.read!(App.Audit.ChangeConflict, authorize?: false) == []

    plan = AssignmentSync.plan(hr, redated, @today)
    assert [%{kind: :redate, conflict?: true}] = plan.changes
    assert %{corrected: 1, conflicts: 1} = AssignmentSync.apply(hr, plan)

    assert [%{resource: "App.People.Assignment"}] =
             Ash.read!(App.Audit.ChangeConflict, authorize?: false)
  end

  test "an over-strength post is a note, not an error", %{hr: hr, bob: bob, ann: ann} do
    rows =
      hr
      |> sheet()
      |> edit(bob, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4"})
      |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4", "Since" => "15.09.2026"})

    plan = AssignmentSync.plan(hr, rows, @today)
    assert Enum.all?(plan.changes, &("post over strength" in &1.notes))
  end

  test "a viewer's import changes nothing", %{ann: ann, hr: hr} do
    viewer = user_fixture(:viewer)

    rows =
      hr
      |> sheet()
      |> edit(ann, %{"Position" => "Combat Medic A.Co¦1Bn¦OR-4", "Since" => "15.09.2026"})

    plan = AssignmentSync.plan(viewer, rows, @today)
    assert %{drafted: 0, failed: [_]} = AssignmentSync.apply(viewer, plan)
  end

  # The sheet as SHEETS-UI writes it: the exported values kept in copies.
  defp with_copies([header | rows]) do
    col = fn name -> Enum.find_index(header, &(&1 == name)) end

    [
      header ++ ["ExportedPosition", "ExportedSince"]
      | Enum.map(rows, &(&1 ++ [Enum.at(&1, col.("Position")), Enum.at(&1, col.("Since"))]))
    ]
  end

  test "an unedited row the app changed after the export is stale, not undone (SHEETS-UI.11)",
       %{hr: hr, ann: ann, bob: bob, medic: medic} do
    exported = hr |> sheet() |> with_copies()

    # After the export: Ann's start date corrected, Bob appointed, in the app.
    Process.sleep(2)

    current(ann)
    |> Ash.Changeset.for_update(:update, %{starts_on: ~D[2026-01-05]}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assign(bob, medic, ~D[2026-09-01])

    plan = AssignmentSync.plan(hr, exported, @today)
    assert plan.changes == [] and plan.errors == []
    assert length(plan.stale) == 2

    # An edited row is still a change (marked as a conflict).
    edited = edit(exported, ann, %{"Since" => "03.01.2026"})
    plan = AssignmentSync.plan(hr, edited, @today)
    assert [%{kind: :redate, conflict?: true}] = plan.changes
    assert length(plan.stale) == 1
  end

  test "two open assignments (an overlap): right after the export the row is unchanged",
       %{hr: hr, ann: ann, medic: medic} do
    # Ann holds Rifleman since 01.01.2026 and, overlapping, Medic since later.
    assign(ann, medic, ~D[2026-03-01])
    exported = hr |> sheet() |> with_copies()

    plan = AssignmentSync.plan(hr, exported, @today)
    assert plan.stale == [] and plan.changes == []
  end

  test "apply reports each row's outcome; the drafts can be cancelled", %{
    hr: hr,
    ann: ann,
    bob: bob
  } do
    rows =
      hr
      |> sheet()
      |> edit(bob, %{"Position" => "Rifleman A.Co¦1Bn¦OR-3", "Since" => "2026-09-20"})
      |> edit(ann, %{"Since" => "02.01.2026"})

    plan = AssignmentSync.plan(hr, rows, @today)
    result = AssignmentSync.apply(hr, plan)
    row = fn person -> Enum.find(plan.changes, &(&1.person.id == person.id)).row end

    assert %{outcomes: outcomes, documents: [id]} = result
    assert outcomes[row.(ann)] == :corrected
    assert outcomes[row.(bob)] == {:drafted, :start, id}

    assert %{cancelled: 1, kept: 0} = AssignmentSync.cancel_drafts(hr, [id])
    assert drafts(bob) == []
  end

  test "dates: dd.mm.yyyy, ISO, spreadsheet serial numbers" do
    assert {:ok, ~D[2026-09-27]} = AssignmentSync.parse_date("27.09.2026")
    assert {:ok, ~D[2026-09-27]} = AssignmentSync.parse_date("2026-09-27")
    assert {:ok, ~D[2026-09-27]} = AssignmentSync.parse_date(46_292)
    assert {:ok, nil} = AssignmentSync.parse_date("")
    assert {:error, _} = AssignmentSync.parse_date("31.02.2026")
  end
end
