defmodule App.Secrets do
  @moduledoc """
  Resolves `App.Accounts.User`'s authentication secrets (JWT signing key,
  Google OAuth client credentials) from application env at runtime — see
  `config/runtime.exs` for where those env vars are required in prod, and
  `config/dev.exs`/`test.exs` for their dev/test placeholder values.
  """
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], App.Accounts.User, _opts, _context) do
    Application.fetch_env(:app, :token_signing_secret)
  end

  def secret_for(
        [:authentication, :strategies, :google, :client_id],
        App.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:app, :google_client_id)
  end

  def secret_for(
        [:authentication, :strategies, :google, :client_secret],
        App.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:app, :google_client_secret)
  end

  def secret_for(
        [:authentication, :strategies, :google, :redirect_uri],
        App.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:app, :google_redirect_uri)
  end
end
