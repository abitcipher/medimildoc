defmodule AppWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use AppWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {AppWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  # Permission gate (docs/design/access-control-phase1.md), stacked
  # after :live_user_required in the router so `current_user` is already
  # loaded. Fails closed to a flash + redirect home rather than rendering a
  # page whose every action would be refused — UX only; the real
  # enforcement is always the resource's own Ash policies.
  def on_mount({:require, permission}, _params, _session, socket) do
    if App.Access.can?(socket.assigns.current_user, permission) do
      {:cont, socket}
    else
      {:halt, redirect_not_authorized(socket)}
    end
  end

  # Any one of several permissions (a page whose content each of them
  # explains, e.g. the Registers page for records officers and HR).
  def on_mount({:require_any, permissions}, _params, _session, socket) do
    if Enum.any?(permissions, &App.Access.can?(socket.assigns.current_user, &1)) do
      {:cont, socket}
    else
      {:halt, redirect_not_authorized(socket)}
    end
  end

  defp redirect_not_authorized(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "You don't have access to that page.")
    |> Phoenix.LiveView.redirect(to: ~p"/")
  end
end
