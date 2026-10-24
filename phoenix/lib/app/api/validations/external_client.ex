defmodule App.Api.Validations.ExternalClient do
  @moduledoc """
  An external system (docs/design/fhir-api.md) belongs to an
  external care provider with a data-sharing agreement that has not
  ended; its keys are public keys only (RSA or EC, no private part); its
  scopes name resource types served to external systems (or `*`).
  """
  use Ash.Resource.Validation

  alias App.Api.Smart

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- provider(Ash.Changeset.get_attribute(changeset, :provider_id)),
         :ok <- keys(Ash.Changeset.get_attribute(changeset, :jwks)) do
      scopes(Ash.Changeset.get_attribute(changeset, :scopes) || [])
    end
  end

  defp provider(nil), do: {:error, field: :provider_id, message: "choose the care provider"}

  defp provider(id) do
    case Ash.get(App.Care.Provider, id, authorize?: false) do
      {:ok, %{priority: true}} ->
        {:error, field: :provider_id, message: "our own units use service clients"}

      {:ok, provider} ->
        if Smart.agreement_valid?(provider),
          do: :ok,
          else:
            {:error,
             field: :provider_id, message: "the provider has no valid data-sharing agreement"}

      _ ->
        {:error, field: :provider_id, message: "no such care provider"}
    end
  end

  defp keys(%{"keys" => [_ | _] = keys}) do
    if Enum.all?(keys, &public_key?/1),
      do: :ok,
      else: {:error, field: :jwks, message: "only public RSA or EC keys (no private part)"}
  end

  defp keys(_jwks), do: {:error, field: :jwks, message: "a JWK Set with at least one key"}

  defp public_key?(%{"kty" => kty} = key) when kty in ["RSA", "EC"] do
    not Map.has_key?(key, "d") and
      match?(
        %JOSE.JWK{},
        try do
          JOSE.JWK.from_map(key)
        rescue
          _ -> nil
        end
      )
  end

  defp public_key?(_key), do: false

  defp scopes([]), do: {:error, field: :scopes, message: "at least one resource type"}

  defp scopes(scopes) do
    allowed = ["*" | App.Fhir.external_types()]

    case scopes -- allowed do
      [] -> :ok
      bad -> {:error, field: :scopes, message: "unknown resource types: #{Enum.join(bad, ", ")}"}
    end
  end
end
