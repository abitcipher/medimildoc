defmodule AppWeb.MyDataController do
  @moduledoc """
  Downloads of a person's own data (docs/design/events-and-person-login.md
  only with the signed token `/me` gives after a fresh confirmation
  (five minutes, this user and format), each one the event
  `hrda.privacy.export.downloaded`. Also the way back to `/me` after
  confirming by signing in with Google again.
  """
  use AppWeb, :controller

  alias AppWeb.MyData

  @max_age 300

  def export(conn, %{"format" => format, "token" => token}) do
    user = conn.assigns[:current_user]

    with %{id: user_id} <- user,
         {:ok, {^user_id, ^format}} <-
           Phoenix.Token.verify(AppWeb.Endpoint, "my-data", token, max_age: @max_age),
         %{} = person <- MyData.person(user),
         {:ok, {filename, type, body}} <- MyData.export(format, user, person) do
      App.EventLog.emit("hrda.privacy.export.downloaded", %{format: format},
        actor: user,
        subject: "person/#{person.id}"
      )

      send_download(conn, {:binary, IO.iodata_to_binary(body)},
        filename: filename,
        content_type: type
      )
    else
      _ ->
        conn
        |> put_flash(:error, gettext("The download link has expired. Confirm again."))
        |> redirect(to: ~p"/me")
    end
  end

  def export(conn, _params), do: redirect(conn, to: ~p"/me")

  def confirm_google(conn, _params) do
    conn
    |> put_session(:return_to, ~p"/me")
    |> redirect(to: ~p"/auth/user/google")
  end
end
