defmodule App.Search.Digest do
  @moduledoc """
  Keyed hashes of encrypted identifiers for exact-match search
  (docs/design/search-timeline-notifications.md): the database can't
  compare `PersonIdentifier.value` or `IdentityDocument.number` (they are
  encrypted), so HMAC-SHA256 of the normalized value is stored beside
  each and a search hashes the query the same way.

  The key is derived from the vault's current default key, so there is no
  extra secret to keep; re-encryption after a key rotation
  (`App.Encryption.reencrypt_all/0`) rewrites the values through their
  actions and recomputes the hashes. `backfill/0` fills rows written
  before the hashes existed (runs after migrations).
  """

  require Ash.Query

  alias App.People.{IdentityDocument, PersonIdentifier}
  alias AshPostgres.DataLayer.Info

  @targets [
    {PersonIdentifier, :value, :value_digest},
    {IdentityDocument, :number, :number_digest}
  ]

  @doc "Upper case, without spaces and the usual separators (`-`, `.`, `/`)."
  @spec normalize(String.t()) :: String.t()
  def normalize(value), do: value |> String.upcase() |> String.replace(~r/[\s\-\.\/]/u, "")

  @doc "The hash of a value; nil for a blank one."
  @spec digest(String.t() | nil) :: String.t() | nil
  def digest(value) when is_binary(value) do
    case normalize(value) do
      "" ->
        nil

      normalized ->
        :hmac |> :crypto.mac(:sha256, key(), normalized) |> Base.encode16(case: :lower)
    end
  end

  def digest(_value), do: nil

  defp key do
    {_cipher, opts} = Application.fetch_env!(:app, App.Vault)[:ciphers][:default]
    :crypto.mac(:hmac, :sha256, Keyword.fetch!(opts, :key), "hrda:search-digest:v1")
  end

  @doc "Fills missing hashes; returns how many rows were updated."
  @spec backfill() :: non_neg_integer()
  def backfill do
    for {resource, field, digest_field} <- @targets, reduce: 0 do
      count ->
        resource
        |> Ash.Query.filter(is_nil(^Ash.Expr.ref(digest_field)))
        |> Ash.Query.load(field)
        |> Ash.read!(authorize?: false)
        |> Enum.reduce(count, fn row, count ->
          set_digest(resource, row, digest_field, Map.fetch!(row, field))
          count + 1
        end)
    end
  end

  defp set_digest(resource, row, digest_field, value) do
    table = Info.table(resource)

    App.Repo.query!(
      "UPDATE #{table} SET #{digest_field} = $1 WHERE id = $2",
      [digest(value), Ecto.UUID.dump!(row.id)]
    )
  end
end
