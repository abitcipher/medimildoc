defmodule App.People.RecordMigrationsTest do
  use App.DataCase, async: true

  import App.Fixtures
  import Ecto.Query

  alias App.People.{PersonRecord, RecordMigrations}

  test "records behind their kind's schema version are upgraded and restamped" do
    record = record_fixture(person_fixture(), :allergy_intolerance)
    assert record.schema_version == "2"

    # As if it had been written under version 1.
    App.Repo.update_all(from(r in "person_records", where: r.id == type(^record.id, :binary_id)),
      set: [schema_version: "1"]
    )

    assert %{allergy_intolerance: 1} = RecordMigrations.migrate_all()
    assert Ash.get!(PersonRecord, record.id, authorize?: false).schema_version == "2"
    assert RecordMigrations.migrate_all() == %{}
  end

  test "allergy category: a single value becomes a list, lists stay" do
    assert %{"category" => ["food"]} =
             RecordMigrations.upgrade(:allergy_intolerance, 1, %{"category" => "food"})

    assert %{"category" => ["food"]} =
             RecordMigrations.upgrade(:allergy_intolerance, 1, %{"category" => ["food"]})

    assert RecordMigrations.upgrade(:allergy_intolerance, 1, %{}) == %{}
  end
end
