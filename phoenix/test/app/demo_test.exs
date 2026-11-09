defmodule App.DemoTest do
  @moduledoc "Synthetic data generator (docs/design/access-control-phase1.md)."
  use App.DataCase, async: false

  require Ash.Query

  alias App.Accounts.User
  alias App.Demo.Export
  alias App.People.{Organization, Person, PersonIdentifier, PersonRecord, PersonRecordSchema}

  defp synthetic_people do
    Person |> Ash.Query.filter(synthetic == true) |> Ash.read!(authorize?: false)
  end

  # Row count of every table, to catch anything a seed adds twice or a
  # purge leaves behind.
  defp table_counts do
    %{rows: tables} =
      App.Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' " <>
          "AND tablename <> 'schema_migrations'"
      )

    for [table] <- tables, into: %{} do
      %{rows: [[count]]} = App.Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
      {table, count}
    end
  end

  test "every kind's sample data is valid" do
    for kind <- PersonRecordSchema.kinds() do
      assert :ok ==
               PersonRecordSchema.validate(kind, App.Demo.sample_record_data(kind))
    end
  end

  test "seed builds a marked brigade with people, records and one demo user per role and profile" do
    assert {:ok, counts} = App.Demo.seed(people: 12, seed: 5)
    assert counts.people == 12
    assert counts.organizations == 15

    people = synthetic_people()
    assert length(people) == 12
    assert Enum.all?(people, &String.ends_with?(&1.email, "@demo.test"))

    assert Organization
           |> Ash.read!(authorize?: false)
           |> Enum.filter(& &1.synthetic)
           |> length() == 15

    assert PersonIdentifier
           |> Ash.read!(authorize?: false, load: [:value])
           |> Enum.all?(&String.starts_with?(&1.value, "TEST-"))

    kinds = PersonRecord |> Ash.read!(authorize?: false) |> Enum.map(& &1.kind) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([:rank_history, :fitness_for_duty, :security_clearance]),
             kinds
           )

    demo_users =
      User
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&String.ends_with?(to_string(&1.email), "@demo.test"))

    assert length(demo_users) == length(App.Access.roles()) + length(App.Access.profiles())

    assert Enum.sort(Enum.flat_map(demo_users, & &1.profiles)) ==
             Enum.sort(App.Access.profiles())
  end

  test "demo accounts are linked to people in fitting posts, with a valid clearance" do
    {:ok, _} = App.Demo.seed(people: 40, seed: 7)

    user =
      User
      |> Ash.Query.filter(email == "clinician@demo.test")
      |> Ash.read_one!(authorize?: false)
      |> Ash.load!([person: [assignments: :position]], authorize?: false)

    assert [%{position: %{title: "Battalion Medical Officer"}}] =
             Enum.filter(user.person.assignments, &is_nil(&1.ends_on))

    [clearance | _] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^user.person_id and kind == :security_clearance)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.read!(authorize?: false)

    assert clearance.data["status"] == "granted"
  end

  test "the same seed gives the same people" do
    names = fn ->
      synthetic_people()
      |> Enum.map(&{&1.given_name, &1.family_name, &1.patronymic})
      |> Enum.sort()
    end

    {:ok, _} = App.Demo.seed(people: 8, seed: 42)
    first = names.()
    {:ok, _} = App.Demo.seed(people: 8, seed: 42)
    assert names.() == first

    {:ok, _} = App.Demo.seed(people: 8, seed: 43)
    refute names.() == first
  end

  test "seeding again replaces the set, and purge leaves only the file plan" do
    before = table_counts()
    {:ok, _} = App.Demo.seed(people: 12, seed: 5)
    first = table_counts()
    {:ok, _} = App.Demo.seed(people: 12, seed: 5)

    assert table_counts() == first

    {:ok, _} = App.Demo.purge()
    after_purge = table_counts()

    # This year's file plan is configuration, not demo data: it stays.
    assert Map.delete(after_purge, "file_plan_cases") == Map.delete(before, "file_plan_cases")
  end

  test "a fresh seed numbers demo documents from 1 again" do
    numbers = fn ->
      App.Repo.query!(
        "SELECT register, max(register_seq) FROM documents " <>
          "WHERE register LIKE 'TEST-%' GROUP BY register ORDER BY register"
      ).rows
    end

    {:ok, _} = App.Demo.seed(people: 12, seed: 5)
    first = numbers.()
    {:ok, _} = App.Demo.seed(people: 12, seed: 5)

    assert numbers.() == first
  end

  @tag :tmp_dir
  test "export writes the synthetic set to JSON, decrypted, with entry times", %{tmp_dir: dir} do
    {:ok, counts} = App.Demo.seed(people: 12, seed: 5)
    assert {:ok, written} = Export.write(dir)
    assert written["people"] == 12
    assert written["users"] == counts.users

    [identifier | _] =
      dir |> Path.join("person_identifiers.json") |> File.read!() |> Jason.decode!()

    assert String.starts_with?(identifier["value"], "TEST-")
    assert identifier["inserted_at"] && identifier["person_id"]
    refute Map.has_key?(identifier, "encrypted_value")

    assert File.exists?(Path.join(dir, "reference.json"))

    assert %{"counts" => %{"people" => 12}} =
             dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  test "purge removes synthetic data and demo users but nothing real" do
    real_person = person_fixture(%{given_name: "Real"})
    real_user = user_fixture(:hr)
    {:ok, _} = App.Demo.seed(people: 6, seed: 1)

    assert {:ok, counts} = App.Demo.purge()
    assert counts.people == 6

    assert synthetic_people() == []
    assert Ash.get!(Person, real_person.id, authorize?: false)
    assert Ash.get!(User, real_user.id, authorize?: false)

    refute User
           |> Ash.read!(authorize?: false)
           |> Enum.any?(&String.ends_with?(to_string(&1.email), "@demo.test"))
  end
end
