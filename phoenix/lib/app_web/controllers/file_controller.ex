defmodule AppWeb.FileController do
  @moduledoc """
  `GET /files/:id` — opens a stored file: checks the signed-in user may
  read it (the attachment's policies), writes the access log for sensitive
  files, and redirects to a signed link valid for a few minutes
  (`App.People.Files.link/3`). The file itself comes from RustFS; the app
  only redirects. `?inline=1` shows images and PDF in the browser.
  """
  use AppWeb, :controller

  alias App.People.Files

  def show(conn, %{"id" => id} = params) do
    with %{} = user <- conn.assigns[:current_user] || :unauthorized,
         {:ok, url} <- Files.link(user, id, inline: params["inline"] == "1") do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> redirect(external: url)
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> text(gettext("Sign in first."))

      {:error, _} ->
        conn |> put_status(:not_found) |> text(gettext("File not found."))
    end
  end
end
