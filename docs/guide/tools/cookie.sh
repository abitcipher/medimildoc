#!/usr/bin/env bash
# Prints a signed session cookie value for a demo user of the local copy (Ukrainian UI).
email="$1"
docker exec hrda-local-app-1 bin/app rpc "
require Ash.Query
user = App.Accounts.User |> Ash.Query.filter(email == ^\"$email\") |> Ash.read_one!(authorize?: false)
{:ok, token, _} = AshAuthentication.Jwt.token_for_user(user, %{}, [])
opts = Plug.Session.init(store: :cookie, key: \"_app_key\", signing_salt: \"qeN7aBX5\")
conn =
  Plug.Test.conn(:get, \"/\")
  |> Map.put(:secret_key_base, AppWeb.Endpoint.config(:secret_key_base))
  |> Plug.Session.call(opts)
  |> Plug.Conn.fetch_session()
  |> Plug.Conn.put_session(\"user_token\", token)
  |> Plug.Conn.put_session(\"locale\", \"uk\")
  |> Plug.Conn.send_resp(200, \"\")
IO.puts(\"COOKIE=\" <> conn.resp_cookies[\"_app_key\"].value)
" 2>&1 | grep '^COOKIE=' | cut -d= -f2-
