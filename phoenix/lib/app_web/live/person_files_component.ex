defmodule AppWeb.PersonFilesComponent do
  @moduledoc """
  The Files tab of a person (docs/design/reference-data-and-files.md):
  upload (up to 200 MB each; a portrait photo up to 10 MB), optionally
  onto one of the person's records; list what the viewer may read; open,
  download, delete. Opening goes through `/files/:id`
  (`AppWeb.FileController`: access check, access log, signed link).

  Attributes: `person`, `actor`, `writable_kinds` (record kinds the actor
  may write), `photo?` (may set the portrait: `people.write`),
  `person_files?` (may add files to the person itself:
  `people.private.write`). Without `person_files?`, files go onto records
  only. All UI hints; the resource policies decide.

  Tells the parent LiveView `{:files_changed, person_id}` after uploads and
  deletions (the avatar and record cards may change).
  """
  use AppWeb, :live_component

  require Ash.Query

  alias App.People.{Attachment, Files, PersonRecord}

  @max_entries 5

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:messages, [])
     |> allow_upload(:file,
       accept: Files.accept(:document),
       max_entries: @max_entries,
       max_file_size: Files.max_bytes(:document)
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, socket |> assign_new(:purpose, fn -> "document" end) |> load()}
  end

  defp load(socket) do
    %{person: person, actor: actor} = socket.assigns

    files =
      Attachment
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load(:record)
      |> Ash.read!(actor: actor)

    records =
      PersonRecord
      |> Ash.Query.filter(person_id == ^person.id and kind in ^socket.assigns.writable_kinds)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.Query.select([:id, :kind, :recorded_at, :person_id])
      |> Ash.read!(actor: actor)

    %{photo?: photo?, person_files?: person_files?} = socket.assigns

    purposes =
      if(photo?, do: [:photo], else: []) ++
        if(person_files? or records != [], do: [:document, :imaging, :other], else: [])

    assign(socket,
      files: files,
      purposes: purposes,
      record_options:
        Enum.map(
          records,
          &{"#{AppWeb.RecordComponents.kind_label(&1.kind)} · #{AppWeb.DateFormat.display(&1.recorded_at)}",
           &1.id}
        ),
      can_upload?: purposes != []
    )
  end

  @impl true
  def handle_event("validate", params, socket),
    do: {:noreply, assign(socket, :purpose, params["purpose"] || socket.assigns.purpose)}

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("upload", params, socket) do
    %{actor: actor, person: person} = socket.assigns
    record_id = if params["record_id"] in [nil, ""], do: nil, else: params["record_id"]
    purpose = purpose(params["purpose"])

    results =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        result =
          Files.store(actor, path, %{
            person_id: person.id,
            record_id: record_id,
            purpose: purpose,
            file_name: entry.client_name
          })

        {:ok, {entry.client_name, result}}
      end)

    send(self(), {:files_changed, person.id})

    {:noreply,
     socket
     |> assign(:messages, Enum.map(results, &message/1))
     |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{actor: actor, person: person} = socket.assigns

    message =
      with {:ok, file} <- Ash.get(Attachment, id, actor: actor),
           :ok <- Ash.destroy(file, actor: actor) do
        {:ok, gettext("Deleted %{name}.", name: file.file_name)}
      else
        _ -> {:error, gettext("This file can't be deleted.")}
      end

    send(self(), {:files_changed, person.id})
    {:noreply, socket |> assign(:messages, [message]) |> load()}
  end

  defp purpose(value) when value in ~w(photo document imaging other),
    do: String.to_existing_atom(value)

  defp purpose(_value), do: :document

  defp message({name, {:ok, _}}), do: {:ok, gettext("Uploaded %{name}.", name: name)}

  defp message({name, {:error, reason}}),
    do: {:error, gettext("%{name}: %{reason}", name: name, reason: error_text(reason))}

  defp error_text(:unsupported_type),
    do: gettext("unsupported file type (JPEG, PNG, WebP, TIFF, PDF, DICOM, ZIP)")

  defp error_text(:not_a_photo), do: gettext("a photo must be JPEG, PNG or WebP")
  defp error_text(:too_large), do: gettext("the file is too large")
  defp error_text(%Ash.Error.Forbidden{}), do: gettext("you may not add files here")
  defp error_text(_reason), do: gettext("could not be stored")

  defp upload_error_text(:too_large), do: gettext("too large (max 200 MB)")
  defp upload_error_text(:not_accepted), do: gettext("unsupported file type")

  defp upload_error_text(:too_many_files),
    do: gettext("at most %{n} files at once", n: @max_entries)

  defp upload_error_text(_), do: gettext("could not be uploaded")

  defp purpose_label(:photo), do: gettext("Portrait photo")
  defp purpose_label(:document), do: gettext("Document or scan")
  defp purpose_label(:imaging), do: gettext("Imaging (X-ray, CT, MRI)")
  defp purpose_label(:other), do: gettext("Other")

  defp icon_for(%{purpose: :photo}), do: "hero-user-circle"
  defp icon_for(%{content_type: "image/svg+xml"}), do: "hero-paint-brush"
  defp icon_for(%{content_type: "application/postscript"}), do: "hero-paint-brush"
  defp icon_for(%{content_type: "image/" <> _}), do: "hero-photo"
  defp icon_for(%{content_type: "application/pdf"}), do: "hero-document-text"
  defp icon_for(%{content_type: "application/dicom"}), do: "hero-film"
  defp icon_for(%{content_type: "application/zip"}), do: "hero-archive-box"
  defp icon_for(_file), do: "hero-paper-clip"

  defp size(bytes), do: AppWeb.FileSize.display(bytes)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-4">
      <form
        :if={@can_upload?}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="upload"
        phx-target={@myself}
        class="flex flex-col gap-3 rounded-box border border-base-300 p-3"
      >
        <h3 class="font-semibold">{gettext("Add files")}</h3>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <label class="fieldset">
            <span class="label mb-1">{gettext("What is it?")}</span>
            <select name="purpose" class="select w-full">
              <option :for={p <- @purposes} value={p} selected={to_string(p) == @purpose}>
                {purpose_label(p)}
              </option>
            </select>
          </label>
          <label :if={@record_options != [] and @purpose != "photo"} class="fieldset">
            <%!-- Without person_files? the file must go onto a record. --%>
            <span class="label mb-1">{gettext("Attach to a record (optional)")}</span>
            <select name="record_id" class="select w-full">
              <option :if={@person_files?} value="">{gettext("— the person —")}</option>
              <option :for={{label, id} <- @record_options} value={id}>{label}</option>
            </select>
          </label>
        </div>

        <label
          for={@uploads.file.ref}
          phx-drop-target={@uploads.file.ref}
          class="flex cursor-pointer flex-col items-center gap-1 rounded-box border-2 border-dashed border-base-300 p-4 text-center text-sm hover:border-primary"
        >
          <.icon name="hero-arrow-up-tray" class="size-6 opacity-60" />
          <span>{gettext("Drop files here or choose them")}</span>
          <span class="text-xs opacity-60">
            {gettext("JPEG, PNG, WebP, TIFF, PDF, DICOM, ZIP · up to 200 MB each")}
          </span>
          <.live_file_input upload={@uploads.file} class="sr-only" />
        </label>

        <ul :if={@uploads.file.entries != []} class="flex flex-col gap-2">
          <li :for={entry <- @uploads.file.entries} class="flex flex-col gap-1 text-sm">
            <div class="flex items-center gap-2">
              <span class="min-w-0 grow truncate">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <progress class="progress progress-primary w-full" value={entry.progress} max="100">
              {entry.progress}%
            </progress>
            <p :for={err <- upload_errors(@uploads.file, entry)} class="text-xs text-error">
              {upload_error_text(err)}
            </p>
          </li>
        </ul>
        <p :for={err <- upload_errors(@uploads.file)} class="text-sm text-error">
          {upload_error_text(err)}
        </p>

        <div>
          <button type="submit" class="btn btn-primary btn-sm" disabled={@uploads.file.entries == []}>
            <.icon name="hero-arrow-up-tray" class="size-4" /> {gettext("Upload")}
          </button>
        </div>
      </form>

      <ul :if={@messages != []} class="flex flex-col gap-1 text-sm" aria-live="polite">
        <li
          :for={{status, text} <- @messages}
          class={if status == :ok, do: "text-success", else: "text-error"}
        >
          {text}
        </li>
      </ul>

      <p :if={@files == []} class="text-sm opacity-60">{gettext("No files yet.")}</p>

      <ul
        :if={@files != []}
        class="flex flex-col divide-y divide-base-200 rounded-box border border-base-300"
      >
        <li
          :for={file <- @files}
          id={"file-#{file.id}"}
          class="flex flex-wrap items-center gap-2 px-3 py-2"
        >
          <.icon name={icon_for(file)} class="size-5 shrink-0 opacity-70" />
          <div class="min-w-0 grow">
            <a
              href={
                ~p"/files/#{file.id}?#{[inline: if(Files.inline?(file.content_type), do: "1", else: "0")]}"
              }
              target="_blank"
              rel="noopener"
              class="link link-hover block truncate text-sm font-medium"
            >
              {file.file_name}
            </a>
            <p class="text-xs opacity-60">
              {purpose_label(file.purpose)} · {size(file.size)} · {AppWeb.DateFormat.display(
                file.inserted_at
              )}
              <span :if={file.record}>
                · {gettext("on %{record}",
                  record: AppWeb.RecordComponents.kind_label(file.record.kind)
                )}
              </span>
            </p>
          </div>
          <a
            href={~p"/files/#{file.id}"}
            class="btn btn-ghost btn-xs"
            aria-label={gettext("Download %{name}", name: file.file_name)}
            title={gettext("Download")}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </a>
          <button
            :if={deletable?(file, @photo?, @person_files?, @writable_kinds)}
            type="button"
            phx-click="delete"
            phx-value-id={file.id}
            phx-target={@myself}
            data-confirm={gettext("Delete %{name}?", name: file.file_name)}
            class="btn btn-ghost btn-xs text-error"
            aria-label={gettext("Delete %{name}", name: file.file_name)}
            title={gettext("Delete")}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # UI hint only; the resource policy decides.
  defp deletable?(%{record_id: nil, purpose: :photo}, photo?, _files?, _kinds), do: photo?
  defp deletable?(%{record_id: nil}, _photo?, files?, _kinds), do: files?
  defp deletable?(%{kind: kind}, _photo?, _files?, kinds), do: kind in kinds
end
