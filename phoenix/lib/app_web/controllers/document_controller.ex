defmodule AppWeb.DocumentController do
  @moduledoc """
  `GET /documents/:id/pdf` — a signed document's PDF
  (docs/design/documents-core.md): read through the document's policy,
  logged when its type is sensitive (fails closed), then a short-lived
  signed link to the stored file, as for other files.

  `GET /documents/:id/files/:file_id` — one of its files (a letter's
  scan), the same way (`App.Documents.Files.link/4`; `?inline=1` shows
  raster images and PDF in the browser).
  """
  use AppWeb, :controller

  alias App.Audit.AccessLogger
  alias App.Documents.{Document, Files}

  def pdf(conn, %{"id" => id}) do
    actor = conn.assigns[:current_user]

    with {:ok, %{state: :signed, pdf_key: key} = document} when is_binary(key) <-
           Ash.get(Document, id, actor: actor),
         :ok <- AccessLogger.log_document_pdf(actor, document) do
      redirect(conn,
        external:
          App.Storage.link(key, "#{document.number}.pdf",
            inline: true,
            content_type: "application/pdf"
          )
      )
    else
      _ -> conn |> put_status(:not_found) |> text(gettext("Not found."))
    end
  end

  def file(conn, %{"id" => id, "file_id" => file_id} = params) do
    case Files.link(conn.assigns[:current_user], id, file_id, inline: params["inline"] == "1") do
      {:ok, url} ->
        conn |> put_resp_header("cache-control", "no-store") |> redirect(external: url)

      _ ->
        conn |> put_status(:not_found) |> text(gettext("Not found."))
    end
  end
end
