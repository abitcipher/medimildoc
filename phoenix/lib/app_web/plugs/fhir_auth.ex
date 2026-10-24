defmodule AppWeb.Plugs.FhirAuth do
  @moduledoc """
  FHIR API authentication (docs/design/fhir-api.md): `Authorization:
  Bearer <token>` of an active API client (`App.Api.Tokens.actor_for_token/1`);
  the actor goes to `conn.assigns.fhir_actor`. Anything else is 401 with
  an OperationOutcome.
  """
  import Plug.Conn

  alias App.Api.Tokens

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, actor} <- Tokens.actor_for_token(String.trim(token)) do
      assign(conn, :fhir_actor, actor)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="fhir"))
        |> AppWeb.FhirController.send_fhir(
          401,
          App.Fhir.Map.outcome("login", "A valid bearer token is required.")
        )
        |> halt()
    end
  end
end
