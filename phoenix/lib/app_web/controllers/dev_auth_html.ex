if Application.compile_env(:app, :dev_routes) do
  defmodule AppWeb.DevAuthHTML do
    @moduledoc """
    Templates for `AppWeb.DevAuthController` — dev-only,
    see that module's moduledoc for why the whole thing only compiles
    when `dev_routes` is enabled.
    """
    use AppWeb, :html

    embed_templates "dev_auth_html/*"
  end
end
