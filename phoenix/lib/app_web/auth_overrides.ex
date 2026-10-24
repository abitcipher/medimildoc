defmodule AppWeb.AuthOverrides do
  @moduledoc """
  UI overrides for `AshAuthentication.Phoenix`'s generated sign-in page
  (installer-generated). See
  https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html.
  """
  use AshAuthentication.Phoenix.Overrides

  # No banner: it is decoration, and its default images load from
  # ash-hq.org — the app makes no requests to outside sites.
  override AshAuthentication.Phoenix.Components.SignIn do
    set :show_banner, false
  end
end
