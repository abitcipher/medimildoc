defmodule App.Accounts do
  @moduledoc """
  Ash domain for authentication  — who can sign into the
  standalone forms UI. See `App.Accounts.User`'s moduledoc for how this
  relates to (and is deliberately separate from) `App.SheetsToken`'s
  embedded-`/sheets`-session auth .
  """
  use Ash.Domain,
    otp_app: :app

  resources do
    resource App.Accounts.AccessRequest
    resource App.Accounts.Token
    resource App.Accounts.User
    resource App.Accounts.UserIdentity
  end
end
