defmodule App.Api.Changes.IssueToken do
  @moduledoc """
  Generates a client's token (`hrda_` + 32 random bytes, URL-safe base64),
  stores its SHA-256 and first characters, and returns the token once in
  the record's metadata (`:token`).
  """
  use Ash.Resource.Change

  alias App.Api.Client

  @impl true
  def change(changeset, _opts, _context) do
    token = Client.prefix() <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    changeset
    |> Ash.Changeset.force_change_attribute(:token_digest, Client.digest(token))
    |> Ash.Changeset.force_change_attribute(:token_hint, String.slice(token, 0, 10))
    |> Ash.Changeset.after_action(fn _changeset, client ->
      {:ok, Ash.Resource.put_metadata(client, :token, token)}
    end)
  end
end
