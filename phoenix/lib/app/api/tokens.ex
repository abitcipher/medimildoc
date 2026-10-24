defmodule App.Api.Tokens do
  @moduledoc """
  Turns a bearer token presented to the FHIR API into an actor
  (docs/design/fhir-api.md).
  """

  require Ash.Query

  alias App.Api.{AccessToken, Client, Smart}

  @doc """
  The actor for a bearer token, or `:error` for an unknown, revoked or
  expired one. A service client acts with its profiles (role viewer, no
  unit); a personal token acts as its owner, limited to their own person
  (`own_person_id`); an access token of an external system acts for its
  care provider with the resource types granted (`App.Api.Smart`).
  """
  @spec actor_for_token(String.t()) :: {:ok, map()} | :error
  def actor_for_token("hrda_at_" <> _ = token), do: external_actor(token)

  def actor_for_token(token) when is_binary(token) do
    now = DateTime.utc_now()

    Client
    |> Ash.Query.filter(
      kind in [:service, :personal] and token_digest == ^Client.digest(token) and active == true
    )
    |> Ash.Query.load(:user)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Client{} = client} ->
        if client.expires_at && DateTime.compare(client.expires_at, now) != :gt,
          do: :error,
          else: {:ok, client |> touch(now) |> actor()}

      _ ->
        :error
    end
  end

  def actor_for_token(_token), do: :error

  defp external_actor(token) do
    now = DateTime.utc_now()

    AccessToken
    |> Ash.Query.filter(token_digest == ^Client.digest(token) and expires_at > ^now)
    |> Ash.Query.load(client: [:provider])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %AccessToken{client: %Client{active: true} = client} = access} ->
        if Smart.agreement_valid?(client.provider) do
          {:ok,
           %{
             id: client.id,
             email: "api:" <> client.name,
             name: client.name,
             role: :viewer,
             profiles: [],
             person_id: nil,
             api: :external,
             provider_id: client.provider_id,
             scopes: access.scopes
           }}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp actor(%Client{kind: :service} = client) do
    %{
      id: client.id,
      email: "api:" <> client.name,
      name: client.name,
      role: :viewer,
      profiles: client.profiles,
      person_id: nil,
      api: :service
    }
  end

  defp actor(%Client{kind: :personal, user: user}) do
    %{
      id: user.id,
      email: to_string(user.email),
      name: user.name,
      role: :viewer,
      profiles: [],
      person_id: user.person_id,
      api: :personal,
      own_person_id: user.person_id
    }
  end

  # At most once a minute: the last use is for the admin page, not an audit.
  defp touch(client, now) do
    if is_nil(client.last_used_at) or DateTime.diff(now, client.last_used_at) > 60 do
      client
      |> Ash.Changeset.for_update(:touch, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)
    else
      client
    end
  end
end
