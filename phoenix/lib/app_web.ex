defmodule AppWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use AppWeb, :controller
      use AppWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images flags favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: AppWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: AppWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import AppWeb.CoreComponents
      import AppWeb.ReferenceComponents, only: [country: 1]

      # daisy_ui_components — the pieces daisyUI itself
      # doesn't give us as ready-made function components (Badge, Alert,
      # Dropdown, Modal, Tabs, ...). `core_components: false` skips its
      # Button/Flash/Form/Icon/Header/Input/List/Table modules, which
      # would otherwise redefine names AppWeb.CoreComponents already owns
      # above (button/1, flash/1, input/1, table/1, icon/1) — ours stay
      # authoritative for those, this only adds genuinely new ones.
      use DaisyUIComponents, core_components: false

      # Common modules used in templates
      alias AppWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AppWeb.Endpoint,
        router: AppWeb.Router,
        statics: AppWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
