defmodule App.Audit.AccessLogTest do
  @moduledoc "Sensitive-read logging (docs/design/access-control-phase1.md)."
  use App.DataCase, async: false

  alias App.Audit.AccessLog
  alias App.People.{PersonIdentifier, PersonRecord}

  defp log_entries, do: Ash.read!(AccessLog, authorize?: false)

  setup do
    unit = org_fixture("Unit")
    person = person_fixture() |> assign_fixture(unit)
    %{person: person, unit: unit}
  end

  test "a clinician reading a diagnosis leaves one row naming them, the record and the person",
       %{person: person, unit: unit} do
    record = record_fixture(person, :medical_condition)
    clinician = unit_user_fixture(:viewer, [:clinician], unit)

    assert %PersonRecord{} = Ash.get!(PersonRecord, record.id, actor: clinician)

    assert [entry] = log_entries()
    assert entry.actor_id == clinician.id
    assert entry.actor_email == to_string(clinician.email)
    assert entry.record_id == record.id
    assert entry.person_id == person.id
    assert entry.kind == "medical_condition"
    assert entry.resource == "App.People.PersonRecord"
  end

  test "ordinary personnel records are not logged", %{person: person} do
    record_fixture(person, :contact_info)
    Ash.read!(PersonRecord, actor: user_fixture(:viewer))

    assert log_entries() == []
  end

  test "national ID numbers are logged with their ID type", %{person: person} do
    PersonIdentifier
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, id_type: :rnokpp, country: "UA", value: "TEST-1", is_current: true},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    Ash.read!(PersonIdentifier, actor: user_fixture(:hr), load: [:value])

    assert [%{kind: "rnokpp"}] = log_entries()
  end

  test "national ID numbers are only decrypted, and logged, when loaded", %{person: person} do
    PersonIdentifier
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, id_type: :rnokpp, country: "UA", value: "TEST-2", is_current: true},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    [identifier] = Ash.read!(PersonIdentifier, actor: user_fixture(:hr))
    refute is_binary(identifier.value)
    assert log_entries() == []
  end

  test "reads without an actor are not logged", %{person: person} do
    record_fixture(person, :medical_condition)
    Ash.read!(PersonRecord, authorize?: false)

    assert log_entries() == []
  end

  test "fails closed: if the log row can't be written, the value isn't returned", %{
    person: person,
    unit: unit
  } do
    record = record_fixture(person, :medical_condition)
    # An actor whose log row is invalid (actor_email can't be blank).
    broken_actor = %{unit_user_fixture(:viewer, [:clinician], unit) | email: nil}

    assert {:error, error} = Ash.get(PersonRecord, record.id, actor: broken_actor)
    assert inspect(error) =~ "access_log_failed"
    assert log_entries() == []
  end
end
