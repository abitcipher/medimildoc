defmodule AppWeb.DocumentFilesComponent do
  @moduledoc """
  A document's files (docs/design/correspondence.md): the list, opened
  through `/documents/:id/files/:file_id`; while the document is a draft
  its editor uploads and removes them (`App.Documents.Files`).
  """
  use AppWeb, :live_component

  alias App.Documents.Files

  @impl true
  def mount(socket) do
    {:ok,
     allow_upload(socket, :file,
       accept: ~w(.pdf .jpg .jpeg .png .webp .tif .tiff .zip),
       max_entries: 10,
       max_file_size: 200 * 1024 * 1024
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(files: Files.list(assigns.document))}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    %{actor: actor, document: document} = socket.assigns

    results =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        {:ok, Files.attach(actor, document, path, entry.client_name)}
      end)

    failed = Enum.count(results, &match?({:error, _}, &1))

    {:noreply,
     socket
     |> assign(files: Files.list(document))
     |> assign(error: if(failed > 0, do: gettext("Some files were not accepted (type or size).")))}
  end

  def handle_event("cancel_entry", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("remove", %{"id" => id}, socket) do
    %{actor: actor, document: document} = socket.assigns
    _ = Files.remove(actor, document, id)
    {:noreply, assign(socket, files: Files.list(document))}
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :error, fn -> nil end)

    ~H"""
    <section id={@id} class="flex flex-col gap-2">
      <h2 class="flex items-center gap-2 font-semibold">
        {gettext("Files")}
        <span class="badge badge-sm badge-ghost">{length(@files)}</span>
      </h2>
      <p :if={@files == [] and not @editable?} class="text-sm opacity-60">{gettext("No files.")}</p>
      <ul :if={@files != []} class="flex flex-col gap-1 text-sm">
        <li :for={file <- @files} class="flex items-center gap-2">
          <.icon name="hero-paper-clip" class="size-4 shrink-0 opacity-70" />
          <a
            href={~p"/documents/#{@document.id}/files/#{file.id}?inline=1"}
            target="_blank"
            rel="noopener"
            class="link min-w-0 truncate"
          >
            {file.file_name}
          </a>
          <span class="shrink-0 opacity-60">{AppWeb.FileSize.display(file.size)}</span>
          <button
            :if={@editable?}
            type="button"
            phx-click="remove"
            phx-value-id={file.id}
            phx-target={@myself}
            data-confirm={gettext("Remove this file?")}
            class="btn btn-ghost btn-xs btn-square text-error"
            aria-label={gettext("Remove")}
            title={gettext("Remove")}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>
      <form
        :if={@editable?}
        id={"#{@id}-upload"}
        phx-change="validate"
        phx-submit="upload"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2"
      >
        <.live_file_input upload={@uploads.file} class="file-input file-input-sm w-full max-w-sm" />
        <button
          type="submit"
          class="btn btn-sm"
          disabled={@uploads.file.entries == []}
        >
          <.icon name="hero-arrow-up-tray" class="size-4" /> {gettext("Upload")}
        </button>
      </form>
      <p :if={@error} class="text-sm text-error">{@error}</p>
    </section>
    """
  end
end
