defmodule App.Accounts.UserIdentity do
  @moduledoc """
  Stores each linked OAuth provider identity's `iss`/`sub` claims for an
  `App.Accounts.User`. Required by the Google strategy: matching a
  returning user by email (or any other claim) alone is unsafe — only the
  `iss`/`sub` combination uniquely and stably identifies an end-user per
  OpenID Connect. No attributes to declare; the `AshAuthentication.UserIdentity`
  extension generates them.
  """
  use Ash.Resource,
    otp_app: :app,
    domain: App.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.UserIdentity]

  postgres do
    table "user_identities"
    repo App.Repo
  end

  user_identity do
    user_resource App.Accounts.User
  end
end
