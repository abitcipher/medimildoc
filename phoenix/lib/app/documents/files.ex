defmodule App.Documents.Files do
  @moduledoc """
  Files of documents (docs/design/correspondence.md): upload while the
  document is a draft the actor may write, list for a document the actor
  has read, remove from a draft, and a short-lived signed link for a
  document the actor may read (logged like the document's PDF for
  sensitive types). Uploads pass the same checks as people's files
  (`App.People.Files.check_upload/2`).
  """
  require Ash.Query

  alias App.Audit.AccessLogger
  alias App.Documents.{Document, DocumentFile, Drafts}
  alias App.People.Files, as: PeopleFiles

  @doc "Adds the uploaded file at `path` to the draft `document`."
  @spec attach(map(), map(), Path.t(), String.t()) :: {:ok, DocumentFile.t()} | {:error, term()}
  def attach(actor, document, path, file_name) do
    with :ok <- writable(actor, document),
         {:ok, checked} <- PeopleFiles.check_upload(path, file_name),
         key = "d/" <> Ash.UUIDv7.generate(),
         :ok <- App.Storage.put_file(key, path, checked.content_type) do
      create_or_remove(checked, document, key, actor)
    end
  end

  # The row, or the stored object goes again.
  defp create_or_remove(checked, document, key, actor) do
    DocumentFile
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(checked, %{document_id: document.id, object_key: key, uploaded_by_id: actor.id}),
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, file} ->
        {:ok, file}

      error ->
        App.Storage.delete(key)
        error
    end
  end

  @doc "The files of `document`, oldest first — for a document the caller has read."
  @spec list(map()) :: [DocumentFile.t()]
  def list(%{id: document_id}) do
    DocumentFile
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Removes `file_id` from the draft `document`."
  @spec remove(map(), map(), String.t()) :: :ok | {:error, term()}
  def remove(actor, document, file_id) do
    with :ok <- writable(actor, document),
         %DocumentFile{} = file <- Enum.find(list(document), &(&1.id == file_id)),
         :ok <- Ash.destroy(file, authorize?: false) do
      App.Storage.delete(file.object_key)
      :ok
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  A signed link to `file_id` of document `document_id`, if the actor may
  read the document; raster images and PDF may open in the browser.
  """
  @spec link(map(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def link(actor, document_id, file_id, opts \\ []) do
    with {:ok, document} <- Ash.get(Document, document_id, actor: actor),
         %DocumentFile{} = file <- Enum.find(list(document), &(&1.id == file_id)),
         :ok <- AccessLogger.log_document_pdf(actor, document) do
      {:ok,
       App.Storage.link(file.object_key, file.file_name,
         inline: opts[:inline] == true and PeopleFiles.inline?(file.content_type),
         content_type: file.content_type
       )}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp writable(actor, document) do
    if Drafts.editable?(actor, document), do: :ok, else: {:error, :forbidden}
  end
end
