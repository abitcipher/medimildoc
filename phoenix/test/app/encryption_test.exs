defmodule App.EncryptionTest do
  @moduledoc "Encryption at rest (docs/design/access-control-phase1.md)."
  use App.DataCase, async: false

  alias App.People.{PersonIdentifier, PersonRecord}

  defp raw(table, column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end

  defp identifier_fixture(person, value) do
    PersonIdentifier
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, id_type: :rnokpp, country: "UA", value: value, is_current: true},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  test "the database holds only ciphertext; reads decrypt" do
    person = person_fixture()
    record = record_fixture(person, :medical_condition)
    identifier = identifier_fixture(person, "TEST-1234567890")

    refute raw("person_records", "encrypted_data", record.id) =~ "Asthma"
    refute raw("person_identifiers", "encrypted_value", identifier.id) =~ "TEST-1234567890"

    assert Ash.get!(PersonRecord, record.id, authorize?: false).data["code"]["text"] == "Asthma"

    assert Ash.get!(PersonIdentifier, identifier.id, authorize?: false, load: [:value]).value ==
             "TEST-1234567890"
  end

  test "the plaintext columns are gone and the encrypted ones are required" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name, column_name, is_nullable FROM information_schema.columns
      WHERE (table_name, column_name) IN (('person_records', 'data'),
        ('person_identifiers', 'value'), ('identity_documents', 'number'),
        ('person_records', 'encrypted_data'), ('person_identifiers', 'encrypted_value'),
        ('identity_documents', 'encrypted_number'))
      ORDER BY 1, 2
      """)

    assert rows == [
             ["identity_documents", "encrypted_number", "NO"],
             ["person_identifiers", "encrypted_value", "NO"],
             ["person_records", "encrypted_data", "NO"]
           ]
  end

  test "after a key rotation, re-encryption moves every value to the new key" do
    person = person_fixture()
    record = record_fixture(person, :medical_condition)
    old_config = Application.get_env(:app, App.Vault)
    [default: {cipher, old_opts}] = Keyword.fetch!(old_config, :ciphers)

    new_opts = Keyword.merge(old_opts, tag: "AES.GCM.V2", key: :crypto.strong_rand_bytes(32))
    rotated = [ciphers: [default: {cipher, new_opts}, retired: {cipher, old_opts}]]

    restart_vault(rotated)

    try do
      App.Encryption.reencrypt_all()
      assert Base.decode64!(raw("person_records", "encrypted_data", record.id)) =~ "AES.GCM.V2"

      # Readable with the new key alone: the old one can now be removed.
      restart_vault(ciphers: [default: {cipher, new_opts}])
      assert Ash.get!(PersonRecord, record.id, authorize?: false).data["code"]["text"] == "Asthma"
    after
      restart_vault(old_config)
    end
  end

  test "no actor may call the internal rewrite action, not even an admin" do
    person = person_fixture()
    record = record_fixture(person, :medical_condition)

    refute Ash.can?({record, :rewrite_encrypted}, user_fixture(:admin), maybe_is: false)
  end

  defp restart_vault(config) do
    Application.put_env(:app, App.Vault, config)
    :ok = Supervisor.terminate_child(App.Supervisor, App.Vault)
    {:ok, _} = Supervisor.restart_child(App.Supervisor, App.Vault)
  end
end
