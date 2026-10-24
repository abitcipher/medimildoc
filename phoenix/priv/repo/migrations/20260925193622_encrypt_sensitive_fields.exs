defmodule App.Repo.Migrations.EncryptSensitiveFields do
  @moduledoc """
  Encryption at rest, expand step (docs/design/access-control-phase1.md).

  `mix ash_postgres.generate_migrations` proposed dropping `data`, `value`
  and `number` and adding NOT NULL encrypted columns in one go, which would
  erase every existing row. Rewritten as expand-contract:

  1. (this migration) add the `encrypted_*` columns, nullable, and make the
     plaintext columns nullable so the app, which now writes only
     ciphertext, can insert rows.
  2. `App.Release.encrypt_plaintext/0` (run automatically by
     `App.Release.migrate/0`, or `mix app.encrypt_plaintext` locally)
     encrypts every row that still has plaintext and then clears it.
  3. A later migration drops the plaintext columns and makes the encrypted
     ones NOT NULL, once production is verified.
  """

  use Ecto.Migration

  def up do
    alter table(:person_records) do
      add :encrypted_data, :binary
      modify :data, :map, null: true, default: nil
    end

    alter table(:person_identifiers) do
      add :encrypted_value, :binary
      modify :value, :text, null: true
    end

    alter table(:identity_documents) do
      add :encrypted_number, :binary
      modify :number, :text, null: true
    end
  end

  # Only safe before step 2 has run: afterwards the plaintext columns are
  # empty and the data exists only in encrypted form.
  def down do
    alter table(:identity_documents) do
      remove :encrypted_number
      modify :number, :text, null: false
    end

    alter table(:person_identifiers) do
      remove :encrypted_value
      modify :value, :text, null: false
    end

    alter table(:person_records) do
      remove :encrypted_data
      modify :data, :map, null: false, default: %{}
    end
  end
end
