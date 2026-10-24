defmodule App.Repo.Migrations.DropPlaintextColumns do
  @moduledoc """
  Encryption at rest, contract step (docs/design/access-control-phase1.md
  the expand step is `EncryptSensitiveFields`): drops the emptied
  plaintext columns `person_records.data`, `person_identifiers.value`,
  `identity_documents.number` and makes the `encrypted_*` columns NOT NULL,
  as the resource snapshots already describe.

  Refuses to run (and changes nothing) while any row still holds plaintext
  or lacks ciphertext — dropping such a column would lose data.
  """

  use Ecto.Migration

  @targets [
    {"person_records", "data"},
    {"person_identifiers", "value"},
    {"identity_documents", "number"}
  ]

  def up do
    for {table, column} <- @targets do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM #{table}
                   WHERE #{column} IS NOT NULL OR encrypted_#{column} IS NULL) THEN
          RAISE EXCEPTION '#{table}: rows with plaintext or without ciphertext, nothing dropped';
        END IF;
      END $$;
      """)
    end

    alter table(:person_records) do
      remove :data
      modify :encrypted_data, :binary, null: false
    end

    alter table(:person_identifiers) do
      remove :value
      modify :encrypted_value, :binary, null: false
    end

    alter table(:identity_documents) do
      remove :number
      modify :encrypted_number, :binary, null: false
    end
  end

  # Restores the columns only; the values stay encrypted (they were never
  # kept in plaintext after the expand step).
  def down do
    alter table(:identity_documents) do
      add :number, :text
      modify :encrypted_number, :binary, null: true
    end

    alter table(:person_identifiers) do
      add :value, :text
      modify :encrypted_value, :binary, null: true
    end

    alter table(:person_records) do
      add :data, :map
      modify :encrypted_data, :binary, null: true
    end
  end
end
