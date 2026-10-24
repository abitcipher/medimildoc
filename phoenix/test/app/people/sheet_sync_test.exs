defmodule App.People.SheetSyncTest do
  @moduledoc "SHEETS-UI stage 2 (docs/design/sheets-ui.md): people and records as rows."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Access.RecordAccess
  alias App.People.{Person, PersonId, PersonRecord, SheetSync}

  @language "record:language_proficiency"

  setup do
    App.Access.put_admin_full_data_access_override(false)
    ann = person_fixture(%{given_name: "Ann", family_name: "Able", email: "ann@example.test"})
    bob = person_fixture(%{given_name: "Bob", family_name: "Baker"})
    record = record_fixture(ann, :language_proficiency)
    %{hr: user_fixture(:hr), ann: ann, bob: bob, record: record}
  end

  # The sheet as SHEETS-UI writes it: the exported values kept in copies.
  defp with_copies(dataset, [header | rows]) do
    keys = Enum.map(SheetSync.fields(dataset), & &1.key)
    col = fn name -> Enum.find_index(header, &(&1 == name)) end

    [
      header ++ Enum.map(keys, &("Exported" <> &1))
      | Enum.map(rows, fn row -> row ++ Enum.map(keys, &Enum.at(row, col.(&1))) end)
    ]
  end

  defp edit([header | rows], match, changes) do
    col = fn name -> Enum.find_index(header, &(&1 == name)) end

    [
      header
      | Enum.map(rows, fn row ->
          if Enum.at(row, col.(elem(match, 0))) == elem(match, 1),
            do: Enum.reduce(changes, row, fn {k, v}, acc -> List.replace_at(acc, col.(k), v) end),
            else: row
        end)
    ]
  end

  test "which record kinds fit a sheet, and which datasets a user may open", %{hr: hr} do
    kinds = SheetSync.sheet_kinds()
    assert :language_proficiency in kinds
    # Kept inside an encounter, or needing nested values: not a sheet.
    refute :vital_signs in kinds
    refute :medication_statement in kinds

    datasets = SheetSync.datasets(hr)
    assert "people" in datasets and @language in datasets

    # Only what the user may read.
    readable = RecordAccess.readable_kinds(hr)
    for "record:" <> kind <- datasets, do: assert(String.to_existing_atom(kind) in readable)
  end

  test "people: export, an edit, a new row, an invalid row, then carry out",
       %{hr: hr, ann: ann} do
    [header | _] = rows = SheetSync.export(hr, "people")
    assert header == SheetSync.header("people")
    code = PersonId.format(ann.person_id)

    sheet =
      "people"
      |> with_copies(rows)
      |> edit({"PersonID", code}, %{"given_name" => "Anna", "date_of_birth" => "02.03.1990"})

    blank = Enum.map(hd(sheet), fn _ -> "" end)
    col = fn name -> Enum.find_index(hd(sheet), &(&1 == name)) end

    new_row =
      blank
      |> List.replace_at(col.("given_name"), "Cid")
      |> List.replace_at(col.("family_name"), "Cole")

    invalid = List.replace_at(blank, col.("given_name"), "Nameless")

    plan = SheetSync.plan(hr, "people", sheet ++ [new_row, invalid], first_row: 3)

    assert [%{kind: :update, changed: changed, person: %{id: ann_id}}, %{kind: :create}] =
             plan.changes

    assert ann_id == ann.id
    assert Enum.sort(changed) == ["date_of_birth", "given_name"]
    assert [{_row, {:invalid, _message}}] = plan.errors
    # Bob's row wasn't edited.
    assert plan.unchanged == 1

    result = SheetSync.apply(hr, plan)
    assert %{created: 1, updated: 1, failed: []} = result
    assert Enum.any?(Map.values(result.outcomes), &match?({:updated, ^code}, &1))

    ann = Ash.get!(Person, ann.id, authorize?: false)
    assert ann.given_name == "Anna" and ann.date_of_birth == ~D[1990-03-02]
    assert [_] = Person |> Ash.Query.filter(family_name == "Cole") |> Ash.read!(authorize?: false)
  end

  test "a new person gets a PersonID: proposed in the row, or generated at the check",
       %{hr: hr} do
    [header | _] = rows = with_copies("people", SheetSync.export(hr, "people"))
    blank = Enum.map(header, fn _ -> "" end)
    col = fn name -> Enum.find_index(header, &(&1 == name)) end
    proposed = PersonId.generate_unique()

    with_id =
      blank
      |> List.replace_at(col.("PersonID"), PersonId.format(proposed))
      |> List.replace_at(col.("given_name"), "Dana")
      |> List.replace_at(col.("family_name"), "Doe")

    without_id =
      blank
      |> List.replace_at(col.("given_name"), "Eve")
      |> List.replace_at(col.("family_name"), "Eads")

    plan = SheetSync.plan(hr, "people", rows ++ [with_id, without_id], first_row: 3)
    assert [%{kind: :create, new_id: shown}, %{kind: :create, new_id: generated}] = plan.changes
    assert shown == PersonId.format(proposed)
    assert PersonId.valid?(PersonId.unformat(generated))

    assert %{created: 2} = SheetSync.apply(hr, plan)

    assert [dana] =
             Person |> Ash.Query.filter(family_name == "Doe") |> Ash.read!(authorize?: false)

    assert dana.person_id == proposed

    assert [eve] =
             Person |> Ash.Query.filter(family_name == "Eads") |> Ash.read!(authorize?: false)

    assert PersonId.format(eve.person_id) == generated

    # A proposed PersonID is checked: shape, and that nobody holds it.
    for bad <- ["AAAA-AAAA-AAAA", PersonId.format(dana.person_id)] do
      assert {:error, _} =
               Person
               |> Ash.Changeset.for_create(
                 :create,
                 %{given_name: "X", family_name: "Y", proposed_person_id: bad},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end
  end

  test "an unedited row the app changed after the export is stale", %{hr: hr, ann: ann} do
    sheet = with_copies("people", SheetSync.export(hr, "people"))
    Process.sleep(2)

    ann
    |> Ash.Changeset.for_update(:update, %{patronymic: "Ivanivna"}, authorize?: false)
    |> Ash.update!(authorize?: false)

    plan = SheetSync.plan(hr, "people", sheet, first_row: 3)
    assert plan.changes == [] and length(plan.stale) == 1
  end

  test "records: an edit keeps the rest of the data, a new row needs a known PersonID",
       %{hr: hr, ann: ann, bob: bob, record: record} do
    rows = SheetSync.export(hr, @language)
    assert [_header, [code, "Ann Able", id | _]] = rows
    assert code == PersonId.format(ann.person_id) and id == record.id

    sheet = @language |> with_copies(rows) |> edit({"RecordID", record.id}, %{"listening" => "5"})
    blank = Enum.map(hd(sheet), fn _ -> "" end)
    col = fn name -> Enum.find_index(hd(sheet), &(&1 == name)) end

    new_row =
      Enum.reduce(
        [
          {"PersonID", PersonId.format(bob.person_id)},
          {"language", "fr"},
          {"listening", "2"},
          {"speaking", "2"},
          {"reading", "2"},
          {"writing", "1"},
          {"preferred", "TRUE"}
        ],
        blank,
        fn {k, v}, acc -> List.replace_at(acc, col.(k), v) end
      )

    unknown = List.replace_at(new_row, col.("PersonID"), "ZZZZ-ZZZZ-ZZZZ")
    plan = SheetSync.plan(hr, @language, sheet ++ [new_row, unknown], first_row: 3)

    assert [%{kind: :update, changed: ["listening"]}, %{kind: :create}] = plan.changes
    assert [{_row, :unknown_person}] = plan.errors

    assert %{created: 1, updated: 1} = SheetSync.apply(hr, plan)
    assert Ash.get!(PersonRecord, record.id, authorize?: false).data["listening"] == 5

    [new] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^bob.id and kind == :language_proficiency)
      |> Ash.read!(authorize?: false)

    assert new.data["preferred"] == true and new.data["writing"] == 1
  end

  test "an unticked checkbox reads FALSE: unset, not a change", %{hr: hr, record: record} do
    rows = @language |> with_copies(SheetSync.export(hr, @language))
    [header | _] = rows
    col = Enum.find_index(header, &(&1 == "preferred"))

    # The sheet shows FALSE in an empty checkbox cell (the copy stays empty).
    rows = [header | Enum.map(tl(rows), &List.replace_at(&1, col, "FALSE"))]
    plan = SheetSync.plan(hr, @language, rows, first_row: 3)
    assert plan.changes == [] and plan.unchanged == 1

    # Rows below the data hold only FALSE in the checkbox: not rows.
    below = Enum.map(header, &if(&1 == "preferred", do: "FALSE", else: ""))
    plan = SheetSync.plan(hr, @language, rows ++ [below, below], first_row: 3)
    assert plan.errors == [] and plan.changes == []

    # An edit elsewhere doesn't store "preferred: false".
    edited = edit(rows, {"RecordID", record.id}, %{"writing" => "4"})
    assert [%{changed: ["writing"]}] = SheetSync.plan(hr, @language, edited, first_row: 3).changes
  end

  test "a user who may not write the kind: the check passes, Carry out fails, nothing changes",
       %{hr: hr, record: record} do
    viewer = user_fixture(:viewer)
    sheet = @language |> with_copies(SheetSync.export(hr, @language))
    sheet = edit(sheet, {"RecordID", record.id}, %{"listening" => "1"})

    if RecordAccess.can_read_kind?(viewer, :language_proficiency) do
      plan = SheetSync.plan(viewer, @language, sheet, first_row: 3)
      assert %{updated: 0, failed: [_]} = SheetSync.apply(viewer, plan)
    else
      assert SheetSync.export(viewer, @language) == [SheetSync.header(@language)]
    end

    assert Ash.get!(PersonRecord, record.id, authorize?: false).data["listening"] == 3
  end
end
