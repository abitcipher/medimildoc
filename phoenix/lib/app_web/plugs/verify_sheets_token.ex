defmodule AppWeb.Plugs.VerifySheetsToken do
  @moduledoc """
  Verifies the token from `App.SheetsToken` for plain HTTP/JSON endpoints
  (M2+ — a webhook, a JSON API route). Reads it from an `Authorization:
  Bearer <token>` header, falling back to a `token` query/body param.

  The LiveView socket itself does NOT go through this plug — its token
  arrives via `connect_params` and is verified directly in
  `AppWeb.SheetsLive.mount/3` (see there), per ADR-3. This plug exists for
  any *non*-LiveView route that needs the same verification. Not wired into
  any pipeline yet — nothing uses it until M2 adds such a route.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, token} <- fetch_token(conn),
         {:ok, claims} <- App.SheetsToken.verify(token, shared_secret()) do
      assign(conn, :sheets_claims, claims)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp fetch_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, token}

      _ ->
        case conn.params["token"] do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> {:error, :missing_token}
        end
    end
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: to_string(reason)}))
    |> halt()
  end

  defp shared_secret, do: Application.fetch_env!(:app, :sheets_shared_secret)
end
