defmodule AppWeb.Authz do
  @moduledoc """
  Permission check for templates and LiveViews
  (docs/design/access-control-phase1.md) — hiding a control here is
  UX only, never the security boundary. Enforcement always lives in each
  resource's Ash policies (`App.Access.Checks.HasPermission`); this only
  keeps users from seeing controls that would be refused anyway.
  """

  @spec can?(App.Accounts.User.t() | nil, App.Access.permission()) :: boolean()
  defdelegate can?(user, permission), to: App.Access
end
