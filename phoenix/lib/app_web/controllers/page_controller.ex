defmodule AppWeb.PageController do
  use AppWeb, :controller

  def home(conn, _params) do
    {inbox, widgets} =
      case conn.assigns[:current_user] do
        nil -> {nil, []}
        user -> {AppWeb.StartPage.inbox(user), AppWeb.StartPage.widgets(user)}
      end

    render(conn, :home, inbox: inbox, widgets: widgets)
  end
end
