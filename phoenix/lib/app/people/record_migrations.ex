defmodule App.People.RecordMigrations do
  @moduledoc """
  Upgrades stored `PersonRecord.data` when a kind's JSON Schema changes in
  a way old data doesn't fit (raise `x-version` and migrate the
  rows). Each step is an explicit `upgrade/3` clause from one version to
  the next; `migrate_all/0` applies the missing steps to every record whose
  `schema_version` is older than its kind's current one and saves it
  through the normal `:update` action, so the result is validated against
  the new schema and stamped with the new version.

  Runs after every release migration (`App.Release.migrate/0`); locally
  `mix app.migrate_records`. Reads run without an actor, so they are not
  in the access log (maintenance, not a person reading the data).
  """
  require Ash.Query
  require Logger

  alias App.People.{PersonRecord, PersonRecordSchema}

  @doc """
  One step: `data` of `kind` at `version` → data at `version + 1`.

  - `allergy_intolerance` 1 → 2: `category` becomes a list (FHIR
    AllergyIntolerance.category is 0..*).
  """
  @spec upgrade(atom(), pos_integer(), map()) :: map()
  def upgrade(:allergy_intolerance, 1, %{"category" => category} = data) when is_binary(category),
    do: %{data | "category" => [category]}

  def upgrade(_kind, _version, data), do: data

  @doc "Brings `data` of `kind` from version `from` to the current version."
  @spec upgrade_to_current(atom(), pos_integer(), map()) :: map()
  def upgrade_to_current(kind, from, data) do
    current = kind |> PersonRecordSchema.version() |> String.to_integer()
    Enum.reduce(from..(current - 1)//1, data, &upgrade(kind, &1, &2))
  end

  @doc """
  Upgrades every record behind its kind's current schema version. Returns
  `%{kind => records upgraded}`; a record that still doesn't validate is
  logged and left as it was.
  """
  @spec migrate_all() :: %{atom() => non_neg_integer()}
  def migrate_all do
    for kind <- PersonRecordSchema.kinds(), into: %{} do
      current = PersonRecordSchema.version(kind)

      upgraded =
        PersonRecord
        |> Ash.Query.filter(kind == ^kind and schema_version != ^current)
        |> Ash.Query.load(:data)
        |> Ash.read!(authorize?: false)
        |> Enum.count(&migrate(&1, kind))

      {kind, upgraded}
    end
    |> Map.reject(fn {_kind, n} -> n == 0 end)
  end

  defp migrate(record, kind) do
    data = upgrade_to_current(kind, String.to_integer(record.schema_version), record.data || %{})

    case record
         |> Ash.Changeset.for_update(:update, %{data: data}, authorize?: false)
         |> Ash.update(authorize?: false) do
      {:ok, _} ->
        true

      {:error, error} ->
        Logger.warning("record #{record.id} (#{kind}) not upgraded: #{Exception.message(error)}")

        false
    end
  end
end
