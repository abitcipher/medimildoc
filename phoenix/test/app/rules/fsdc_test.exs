defmodule App.Rules.FsdcTest do
  @moduledoc "docs/design/data-consistency.md: rules at check points, incidents, sweep, versions."
  use App.DataCase, async: false

  alias App.Rules.Library
  import App.Fixtures

  require Ash.Query

  alias App.Audit.Incident
  alias App.People.{IdentityDocument, PersonRecord}
  alias App.Rules.{Engine, RuleSet, Sweep}

  setup do
    Library.sync()
    admin = user_fixture(:admin)
    %{admin: admin, person: person_fixture(), medic: user_fixture(:admin)}
  end

  defp enable(admin), do: :ok = App.Settings.put("fsdc.enabled", true, admin)

  defp identity(person) do
    IdentityDocument
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, document_type: :passport, number: "TEST-123456"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp encounter(person, actor, start \\ "2020-01-01T10:00") do
    data = Map.put(App.Demo.sample_record_data(:encounter), "start", start)

    PersonRecord
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, kind: :encounter, data: data},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp incidents, do: Ash.read!(Incident, authorize?: false)

  test "off by default: nothing is checked", %{person: person, admin: admin} do
    assert {:ok, _} = encounter(person, admin)
    assert incidents() == []
  end

  test "flag: an examination before any identity document is saved, flagged and logged",
       %{person: person, admin: admin} do
    enable(admin)

    assert {:ok, record} = encounter(person, admin)

    assert [incident] = incidents()

    assert %{
             rule_key: "identity_before_examination",
             severity: :flag,
             outcome: :saved,
             code: "identity_missing",
             point: "record.save",
             subject: "record:encounter",
             status: :open
           } = incident

    assert incident.subject_id == record.id and incident.person_id == person.id
    assert incident.actor_email == to_string(admin.email)
    # Facts only, never the record's content.
    refute Map.has_key?(incident.facts, "data")
    assert incident.facts["event"]["at"] =~ "2020-01-01"

    # With the identity entered first, a later examination is fine.
    identity(person)
    assert {:ok, _} = encounter(person, admin, "2099-01-01T10:00")
    assert length(incidents()) == 1
  end

  test "block: the save is refused and the attempt is still an incident",
       %{person: person, admin: admin} do
    enable(admin)

    RuleSet
    |> Ash.get!("identity_before_examination", authorize?: false)
    |> Ash.Changeset.for_update(:configure, %{severity: :block}, actor: admin)
    |> Ash.update!(actor: admin)

    assert {:error, error} = encounter(person, admin)
    assert Exception.message(error) =~ "No identity document was entered before this examination"
    assert PersonRecord |> Ash.read!(authorize?: false) |> Enum.all?(&(&1.kind != :encounter))
    assert [%{outcome: :refused, severity: :block}] = incidents()
  end

  test "the sweep finds violations in existing data once, not twice", %{
    person: person,
    admin: admin
  } do
    assert {:ok, _} = encounter(person, admin)
    assert incidents() == []

    enable(admin)
    assert %{found: 1} = Sweep.run(admin)
    assert [%{outcome: :found}] = incidents()
    assert %{found: 0} = Sweep.run(admin)
  end

  test "editing a graph keeps the old version; a broken graph is refused", %{admin: admin} do
    rule = Ash.get!(RuleSet, "identity_before_examination", authorize?: false)

    assert {:error, _} =
             rule
             |> Ash.Changeset.for_update(:update_graph, %{graph: %{"nodes" => [], "edges" => []}},
               actor: admin
             )
             |> Ash.update(actor: admin)

    {:ok, updated} =
      rule
      |> Ash.Changeset.for_update(:update_graph, %{graph: rule.graph}, actor: admin)
      |> Ash.update(actor: admin)

    assert updated.version == rule.version + 1
    assert [%{version: kept}] = Ash.read!(App.Rules.RuleSetVersion, authorize?: false)
    assert kept == rule.version
  end

  test "incidents are for audit only; rules are managed with rules.manage", %{
    person: person,
    admin: admin
  } do
    enable(admin)
    {:ok, _} = encounter(person, admin)

    assert [_] = Ash.read!(Incident, actor: user_fixture(:viewer, [:ciso]))
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Incident, actor: user_fixture(:hr))

    assert {:error, _} =
             App.Settings.put("fsdc.enabled", false, user_fixture(:hr))
  end

  test "a newer shipped rule replaces one nobody edited; an edited one is kept", %{admin: admin} do
    rule = Ash.get!(RuleSet, "identity_before_examination", authorize?: false)
    shipped = rule.version

    # Pretend the database still has an older shipped version.
    rule
    |> Ash.Changeset.for_update(:ship, %{version: shipped - 1}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assert Library.sync() == 1
    assert Ash.get!(RuleSet, rule.key, authorize?: false).version == shipped

    # Once edited in the app, shipped versions no longer replace it.
    rule = Ash.get!(RuleSet, rule.key, authorize?: false)

    rule
    |> Ash.Changeset.for_update(:configure, %{severity: :observe}, actor: admin)
    |> Ash.update!(actor: admin)

    rule
    |> Ash.Changeset.for_update(:ship, %{version: 0}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assert Library.sync() == 0
    assert Ash.get!(RuleSet, rule.key, authorize?: false).severity == :observe
  end

  test "a valid result has no code or message (ZEN leaves out null outputs)" do
    rule = Ash.get!(RuleSet, "identity_before_examination", authorize?: false)

    assert {:ok, result} =
             Engine.evaluate(rule.graph, %{
               "person" => %{"identityVerifiedAt" => "2026-09-01T00:00:00Z"},
               "event" => %{"at" => "2026-09-02T00:00:00Z"}
             })

    assert result == %{"valid" => true}
  end
end
