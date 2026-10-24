defmodule AppWeb.PersonDocumentsComponent do
  @moduledoc """
  The person page's Documents tab (docs/design/documents-core.md): the
  person's documents the viewer may read, newest first, and "New
  document" for the types the viewer may write for this person — which
  opens a draft and goes to its page.
  """
  use AppWeb, :live_component

  require Ash.Query

  alias App.Documents.{Access, Document, Types}
  alias AppWeb.DocumentUI

  @impl true
  def update(assigns, socket) do
    %{person: person, actor: actor} = assigns

    documents =
      Document
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load(:person)
      |> Ash.read!(actor: actor)

    creatable =
      Enum.filter(
        Types.ids(),
        &(Access.can_write?(actor, &1, person.id) and Types.basis(&1) == [])
      )

    {:ok, assign(socket, assigns) |> assign(documents: documents, creatable: creatable)}
  end

  @impl true
  def handle_event("new", %{"type" => type}, socket) do
    %{person: person, actor: actor, creatable: creatable} = socket.assigns

    case Enum.find(creatable, &(Atom.to_string(&1) == type)) do
      nil -> {:noreply, socket}
      type -> create(socket, type, person, actor)
    end
  end

  defp create(socket, type, person, actor) do
    Document
    |> Ash.Changeset.for_create(:create, %{type: type, person_id: person.id, data: %{}},
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, document} ->
        {:noreply, push_navigate(socket, to: "/documents/#{document.id}")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the document."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="flex flex-col gap-3" id="person-documents">
      <form
        :if={@creatable != []}
        id="new-document-form"
        phx-submit="new"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2"
      >
        <label for="new-document-type" class="sr-only">{gettext("New document")}</label>
        <select id="new-document-type" name="type" class="select select-sm w-auto max-w-full">
          <option :for={type <- @creatable} value={type}>{DocumentUI.type_label(type)}</option>
        </select>
        <button type="submit" class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> {gettext("New document")}
        </button>
      </form>
      <p :if={@documents == []} class="text-sm opacity-60">{gettext("No documents.")}</p>
      <ul :if={@documents != []} class="divide-y divide-base-200 rounded-box border border-base-300">
        <li :for={document <- @documents}>
          <DocumentUI.row document={document} person?={false} />
        </li>
      </ul>
    </section>
    """
  end
end
