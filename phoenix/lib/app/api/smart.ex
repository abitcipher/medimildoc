defmodule App.Api.Smart do
  @moduledoc """
  SMART on FHIR backend services (docs/design/fhir-api.md): the
  token endpoint for external systems.

  The request is `grant_type=client_credentials` with a client assertion:
  a JWT the system signs with its private key (RS384 or ES384), whose
  `iss` and `sub` are its client id, `aud` is our token endpoint, `exp` at
  most five minutes ahead, and `jti` never used before. It is verified
  with the public keys registered for the client; the provider's
  data-sharing agreement must still be valid. The answer is an access
  token for five minutes, for the requested resource types the client is
  allowed (`system/<Type>.rs`, `.read`, `*`).
  """

  require Ash.Query

  alias App.Api.{AccessToken, Client, UsedJti}

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @algorithms ["RS384", "ES384"]
  @lifetime 300
  @max_assertion_lifetime 300
  @skew 30

  @doc "Signing algorithms accepted for client assertions."
  @spec algorithms() :: [String.t()]
  def algorithms, do: @algorithms

  @doc "Whether a provider's data-sharing agreement is on file and has not ended."
  @spec agreement_valid?(map()) :: boolean()
  def agreement_valid?(provider) do
    provider.agreement_ref not in [nil, ""] and provider.active and
      (is_nil(provider.agreement_until) or
         Date.compare(provider.agreement_until, Date.utc_today()) != :lt)
  end

  @type result ::
          {:ok, map()} | {:error, String.t(), String.t()}

  @doc "Handles a token request (form params) addressed to `token_url`."
  @spec token(map(), String.t()) :: result()
  def token(params, token_url) do
    now = System.system_time(:second)

    with :ok <- grant(params),
         {:ok, claims, client} <- verify(params["client_assertion"], token_url, now),
         :ok <- fresh_jti(client, claims, now),
         {:ok, types} <- granted(client, params["scope"]) do
      issue(client, types)
    end
  end

  defp grant(%{"grant_type" => "client_credentials", "client_assertion_type" => @assertion_type}),
    do: :ok

  defp grant(%{"grant_type" => "client_credentials"}),
    do: {:error, "invalid_client", "client_assertion_type must be #{@assertion_type}"}

  defp grant(_params), do: {:error, "unsupported_grant_type", "only client_credentials"}

  defp verify(assertion, token_url, now) when is_binary(assertion) do
    with {:ok, header, unverified} <- peek(assertion),
         {:ok, client} <- client(unverified["iss"]),
         {:ok, claims} <- signature(assertion, header, client),
         :ok <- claims(claims, client, token_url, now) do
      {:ok, claims, client}
    end
  end

  defp verify(_assertion, _url, _now),
    do: {:error, "invalid_client", "client_assertion is required"}

  defp peek(assertion) do
    # The raw protected header: JOSE keeps "alg" outside its parsed fields.
    header = assertion |> JOSE.JWS.peek_protected() |> Jason.decode!()
    %JOSE.JWT{fields: claims} = JOSE.JWT.peek_payload(assertion)
    {:ok, header, claims}
  rescue
    _ -> {:error, "invalid_client", "client_assertion is not a JWT"}
  end

  defp client(id) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Client{kind: :external, active: true} = client} <-
           Ash.get(Client, id, authorize?: false, load: [:provider]),
         true <-
           is_nil(client.expires_at) or DateTime.after?(client.expires_at, DateTime.utc_now()),
         true <- agreement_valid?(client.provider) do
      {:ok, client}
    else
      _ -> {:error, "invalid_client", "unknown, revoked or expired client, or no valid agreement"}
    end
  end

  defp client(_id), do: {:error, "invalid_client", "iss must be the client id"}

  defp signature(assertion, %{"alg" => alg} = header, client) when alg in @algorithms do
    client.jwks["keys"]
    |> Enum.filter(&(is_nil(header["kid"]) or &1["kid"] == header["kid"]))
    |> Enum.find_value(fn key ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), [alg], assertion) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> nil
      end
    end)
    |> Kernel.||({:error, "invalid_client", "signature does not verify with the registered keys"})
  rescue
    _ -> {:error, "invalid_client", "signature does not verify with the registered keys"}
  end

  defp signature(_assertion, _header, _client),
    do: {:error, "invalid_client", "alg must be one of #{Enum.join(@algorithms, ", ")}"}

  # Each check with what to say when it fails, in order.
  defp claims(c, client, token_url, now) do
    [
      {c["iss"] == client.id and c["sub"] == client.id, "iss and sub must be the client id"},
      {token_url in List.wrap(c["aud"]), "aud must be #{token_url}"},
      {is_integer(c["exp"]) and c["exp"] + @skew >= now, "the assertion has expired"},
      {is_integer(c["exp"]) and c["exp"] <= now + @max_assertion_lifetime + @skew,
       "exp must be at most five minutes ahead"},
      {is_binary(c["jti"]) and c["jti"] != "", "jti is required"}
    ]
    |> Enum.find_value(:ok, fn {ok?, message} ->
      if !ok?, do: {:error, "invalid_client", message}
    end)
  end

  # Each assertion id once; forgotten after it expires.
  defp fresh_jti(client, claims, now) do
    expired = DateTime.from_unix!(now)

    UsedJti
    |> Ash.Query.filter(expires_at < ^expired)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: [:atomic, :stream])

    UsedJti
    |> Ash.Changeset.for_create(
      :create,
      %{
        client_id: client.id,
        jti: claims["jti"],
        expires_at: DateTime.from_unix!(claims["exp"] + @skew)
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "invalid_client", "this assertion (jti) was already used"}
    end
  end

  # Requested `system/<Type>.rs|.read|.r|.s` (or `system/*.…`) within what
  # the client is allowed.
  defp granted(client, scope) do
    requested =
      (scope || "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(fn s ->
        case Regex.run(~r{^system/([A-Za-z]+|\*)\.(rs|read|r|s)$}, s) do
          [_, type, _] -> [type]
          _ -> []
        end
      end)

    allowed = if "*" in client.scopes, do: App.Fhir.external_types(), else: client.scopes

    types =
      if "*" in requested,
        do: allowed,
        else: Enum.filter(requested, &(&1 in allowed))

    case Enum.uniq(types) do
      [] -> {:error, "invalid_scope", "no requested scope is allowed for this client"}
      types -> {:ok, types}
    end
  end

  defp issue(client, types) do
    token = "hrda_at_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    AccessToken
    |> Ash.Changeset.for_create(
      :create,
      %{
        client_id: client.id,
        token_digest: Client.digest(token),
        scopes: types,
        expires_at: DateTime.add(DateTime.utc_now(), @lifetime, :second)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    {:ok,
     %{
       "access_token" => token,
       "token_type" => "bearer",
       "expires_in" => @lifetime,
       "scope" => Enum.map_join(types, " ", &"system/#{&1}.rs")
     }}
  end
end
