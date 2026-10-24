defmodule AppWeb.LiveSessionExtras do
  @moduledoc """
  Session values the signed-in LiveViews need besides the user
  (`ash_authentication_live_session` passes only its own): when this
  session signed in, which tells a fresh sign-in for confirming an action
  (docs/design/events-and-person-login.md, `AppWeb.MyDataLive`).
  """

  @doc false
  @spec session(Plug.Conn.t()) :: map()
  def session(conn), do: %{"signed_in_at" => Plug.Conn.get_session(conn, :signed_in_at)}
end
