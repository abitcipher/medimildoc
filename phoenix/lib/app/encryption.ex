defmodule App.Encryption do
  @moduledoc """
  Maintenance for encrypted fields (docs/design/access-control-phase1.md
  `PersonRecord.data`, `PersonIdentifier.value`,
  `IdentityDocument.number`.

  - `reencrypt_all/0` — re-stores every encrypted value under the vault's
    current default cipher, after a key rotation (`infra/README.md`).

  It uses each resource's internal `:rewrite_encrypted` action. (The
  one-off plaintext → ciphertext step is done; the plaintext columns were
  dropped by the `DropPlaintextColumns` migration.)
  """

  alias App.People.{IdentityDocument, PersonIdentifier, PersonRecord}

  # {resource, table, encrypted attribute}
  @targets [
    {PersonRecord, "person_records", :data},
    {PersonIdentifier, "person_identifiers", :value},
    {IdentityDocument, "identity_documents", :number}
  ]

  @doc "Re-encrypts every encrypted value under the current default cipher."
  @spec reencrypt_all() :: %{String.t() => non_neg_integer()}
  def reencrypt_all do
    Map.new(@targets, fn {resource, table, field} ->
      records = Ash.read!(resource, authorize?: false, load: [field])
      Enum.each(records, &rewrite(&1, field, Map.fetch!(&1, field)))
      {table, length(records)}
    end)
  end

  defp rewrite(record, field, value) do
    record
    |> Ash.Changeset.for_update(:rewrite_encrypted, %{field => value}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end
end
