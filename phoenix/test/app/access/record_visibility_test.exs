defmodule App.Access.RecordVisibilityTest do
  @moduledoc """
  PersonRecord reads are filtered by kind category
  (docs/design/access-control-phase1.md), and labels follow the kind
  Checked against real rows, one record of every kind.
  """
  use App.DataCase, async: true

  require Ash.Query

  alias App.Access.RecordAccess
  alias App.People.{PersonRecord, PersonRecordSchema}

  # The record owner and every actor share a unit, so unit-scoped profiles
  # see what their permissions allow; the scope tests below move them apart.
  setup do
    App.Access.put_admin_full_data_access_override(false)

    unit = org_fixture("Unit")
    person = person_fixture() |> assign_fixture(unit)
    records = Enum.map(PersonRecordSchema.kinds(), &record_fixture(person, &1))

    %{person: person, records: records, unit: unit}
  end

  defp visible_kinds(actor) do
    PersonRecord |> Ash.read!(actor: actor) |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
  end

  defp actor(role, profiles \\ []), do: user_fixture(role, profiles)

  test "each actor reads exactly the kinds its permissions allow", %{unit: unit} do
    actors =
      Enum.map(App.Access.roles(), &unit_user_fixture(&1, [], unit)) ++
        Enum.map(App.Access.profiles(), &unit_user_fixture(:viewer, [&1], unit))

    for actor <- actors do
      assert visible_kinds(actor) == Enum.sort(RecordAccess.readable_kinds(actor)),
             "role #{actor.role} profiles #{inspect(actor.profiles)}"
    end
  end

  test "a line commander sees readiness and personnel records, nothing clinical", %{
    unit: unit
  } do
    kinds = visible_kinds(unit_user_fixture(:viewer, [:line_commander], unit))

    assert :fitness_for_duty in kinds
    refute :medical_condition in kinds
    refute :allergy_intolerance in kinds
    refute :vetting_record in kinds
    refute :compensation in kinds
  end

  test "identity access doesn't open pay and family records" do
    for profile <- [:clinician, :registrar] do
      kinds = visible_kinds(actor(:viewer, [profile]))
      refute :compensation in kinds, "#{profile} reads compensation"
      refute :dependent in kinds, "#{profile} reads dependents"
    end

    assert :compensation in visible_kinds(actor(:hr))
  end

  test "a restricted record is not found by id either", %{records: records} do
    medical = Enum.find(records, &(&1.kind == :medical_condition))

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(PersonRecord, medical.id, actor: actor(:viewer))
  end

  test "labels default from the kind", %{records: records} do
    by_kind = Map.new(records, &{&1.kind, &1})

    assert by_kind.medical_condition.confidentiality == :r
    assert by_kind.medical_condition.classification == nil
    assert by_kind.vetting_record.confidentiality == :v
    assert by_kind.vetting_record.classification == :nato_restricted
    assert by_kind.status_change.confidentiality == :n
    assert by_kind.security_clearance.schema_version == "2"
  end

  test "labels can be raised but not lowered below the kind default", %{
    person: person,
    unit: unit
  } do
    clinician = unit_user_fixture(:viewer, [:clinician], unit)

    raised =
      PersonRecord
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: person.id,
          kind: :medical_condition,
          data: App.Demo.sample_record_data(:medical_condition),
          confidentiality: :v,
          classification: :nato_confidential
        },
        actor: clinician
      )
      |> Ash.create!()

    assert raised.confidentiality == :v

    assert {:error, %Ash.Error.Invalid{}} =
             raised
             |> Ash.Changeset.for_update(:update, %{confidentiality: :n}, actor: clinician)
             |> Ash.update()
  end

  test "a clinician can't write vetting records and HR can't write clinical ones", %{
    person: person
  } do
    for {actor, kind} <- [
          {actor(:viewer, [:clinician]), :vetting_record},
          {actor(:hr), :medical_condition}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               PersonRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, kind: kind, data: App.Demo.sample_record_data(kind)},
                 actor: actor
               )
               |> Ash.create()
    end
  end

  describe "unit scope (docs/design/access-control-phase2.md)" do
    test "a clinician outside the unit sees no clinical records; one above it does", %{
      unit: unit
    } do
      other_unit = org_fixture("Other unit")
      outside = unit_user_fixture(:viewer, [:clinician], other_unit)
      refute :medical_condition in visible_kinds(outside)
      assert :status_change in visible_kinds(outside)

      parent = org_fixture("Brigade")

      unit
      |> Ash.Changeset.for_update(:update, %{parent_id: parent.id}, authorize?: false)
      |> Ash.update!(authorize?: false)

      above = unit_user_fixture(:viewer, [:clinician], parent)
      assert :medical_condition in visible_kinds(above)
    end

    test "unit-scoped access without a linked person or post is empty (fails closed)" do
      refute :fitness_for_duty in visible_kinds(actor(:viewer, [:line_commander]))
      refute :medical_condition in visible_kinds(actor(:viewer, [:clinician]))
    end

    test "global permissions ignore units", %{unit: _unit} do
      hr = unit_user_fixture(:hr, [], org_fixture("HQ"))
      assert :fitness_for_duty in visible_kinds(hr)
      assert :compensation in visible_kinds(hr)
    end

    test "a clinician can't write clinical records for someone outside the unit", %{
      person: person
    } do
      outside = unit_user_fixture(:viewer, [:clinician], org_fixture("Elsewhere"))

      assert {:error, %Ash.Error.Forbidden{}} =
               PersonRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   person_id: person.id,
                   kind: :medical_condition,
                   data: App.Demo.sample_record_data(:medical_condition)
                 },
                 actor: outside
               )
               |> Ash.create()
    end

    test "national IDs follow the same scope for clinicians", %{person: person, unit: unit} do
      App.People.PersonIdentifier
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: person.id,
          id_type: :rnokpp,
          country: "UA",
          value: "TEST-9",
          is_current: true
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      inside = unit_user_fixture(:viewer, [:clinician], unit)
      outside = unit_user_fixture(:viewer, [:clinician], org_fixture("Far away"))

      assert [_] = Ash.read!(App.People.PersonIdentifier, actor: inside)
      assert [] = Ash.read!(App.People.PersonIdentifier, actor: outside)
    end
  end

  describe "clearance (docs/design/access-control-phase2.md)" do
    test "classified records need a valid clearance at least as high", %{unit: unit} do
      # vetting_record defaults to NATO RESTRICTED.
      cleared = unit_user_fixture(:viewer, [:security_officer], unit, "NATO_RESTRICTED")
      none = unit_user_fixture(:viewer, [:security_officer], unit, nil)

      assert :vetting_record in visible_kinds(cleared)
      refute :vetting_record in visible_kinds(none)
      assert :security_clearance in visible_kinds(none)
    end

    test "an expired or revoked clearance counts as none", %{unit: unit} do
      officer = unit_user_fixture(:viewer, [:security_officer], unit, nil)
      person = Ash.get!(App.People.Person, officer.person_id, authorize?: false)

      record_fixture(person, :security_clearance, %{
        "clearanceLevel" => "COSMIC_TOP_SECRET",
        "status" => "granted",
        "expiryDate" => "2020-01-01"
      })

      refute :vetting_record in visible_kinds(officer)
    end

    test "a raised classification hides a record from lower clearances", %{
      person: person,
      unit: unit
    } do
      record_fixture(person, :fitness_for_duty)
      |> Ash.Changeset.for_update(:update, %{classification: :nato_secret}, authorize?: false)
      |> Ash.update!(authorize?: false)

      low = unit_user_fixture(:viewer, [:line_commander], unit, "NATO_RESTRICTED")
      high = unit_user_fixture(:viewer, [:line_commander], unit, "NATO_SECRET")

      count = fn actor ->
        PersonRecord
        |> Ash.Query.filter(kind == :fitness_for_duty and person_id == ^person.id)
        |> Ash.read!(actor: actor)
        |> length()
      end

      assert count.(high) == 2
      assert count.(low) == 1
    end
  end
end
