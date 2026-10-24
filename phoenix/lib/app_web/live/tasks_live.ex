defmodule AppWeb.TasksLive do
  @moduledoc """
  The inbox (docs/design/documents-core.md): documents waiting for the
  viewer — to approve or sign, their own drafts (returned ones first), and
  drafts the system opened for their team (a conclusion for the board, a
  scheduled re-examination), soonest first. `Queries.inbox/1`. A user
  linked to a person also sees, first, signed orders about them still to
  acknowledge (docs/design/acknowledgements.md), their own requests, and
  files new ones here:
  every self-service type — leave (docs/design/leave.md) and certificates
  (docs/design/certificates.md).
  """
  use AppWeb, :live_view

  alias App.Documents.{Deputies, Deputy, DeputyCandidates, Document, Queries, Types}

  alias AppWeb.{DeputiesSection, DocumentUI}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Tasks"),
       inbox: Queries.inbox(socket.assigns.current_user),
       to_acknowledge: Queries.to_acknowledge(socket.assigns.current_user),
       # Reports written from a document (a trip report from its order) aren't
       # offered here (docs/design/business-trips.md §Report).
       request_types: Enum.filter(Types.self_service_types(), &(Types.basis(&1) == [])),
       candidates: DeputyCandidates.for_user(socket.assigns.current_user),
       creating_deputy?: false
     )
     |> assign_deputies()
     |> assign_deputy_form()}
  end

  defp assign_deputy_form(socket) do
    form =
      Deputy
      |> AshPhoenix.Form.for_create(:create,
        actor: socket.assigns.current_user,
        id: "deputy-new-form"
      )
      |> to_form()

    assign(socket, deputy_form: form)
  end

  defp assign_deputies(socket),
    do: assign(socket, deputies: Deputies.overview(socket.assigns.current_user))

  @impl true
  def handle_event("new_request", %{"type" => type}, socket) do
    actor = socket.assigns.current_user

    case Enum.find(socket.assigns.request_types, &(Atom.to_string(&1) == type)) do
      nil -> {:noreply, socket}
      type -> create(socket, type, actor)
    end
  end

  # Stand-ins (docs/design/inbox-first.md).
  def handle_event("open_deputy", _params, socket),
    do: {:noreply, assign(socket, creating_deputy?: true)}

  def handle_event("close_deputy", _params, socket),
    do: {:noreply, assign(socket, creating_deputy?: false)}

  def handle_event("validate_deputy", %{"form" => params}, socket) do
    params = Map.put(params, "user_id", socket.assigns.current_user.id)

    {:noreply,
     assign(socket, deputy_form: AshPhoenix.Form.validate(socket.assigns.deputy_form, params))}
  end

  def handle_event("add_deputy", %{"form" => params}, socket) do
    params = Map.put(params, "user_id", socket.assigns.current_user.id)

    case AshPhoenix.Form.submit(socket.assigns.deputy_form, params: params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(creating_deputy?: false)
         |> assign_deputies()
         |> assign_deputy_form()
         |> put_flash(:info, gettext("Deputy added"))}

      {:error, form} ->
        {:noreply, assign(socket, deputy_form: form)}
    end
  end

  def handle_event("delete_deputy", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, deputy} <- Ash.get(Deputy, id, actor: actor),
         :ok <- Ash.destroy(deputy, actor: actor) do
      {:noreply, socket |> assign_deputies() |> put_flash(:info, gettext("Deputy removed"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove the deputy."))}
    end
  end

  defp create(socket, type, actor) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{type: type, person_id: actor.person_id, data: %{}},
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, document} ->
        {:noreply, push_navigate(socket, to: ~p"/documents/#{document.id}")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the document."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-6 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-xl font-semibold">{gettext("Tasks")}</h1>
          <form
            :if={@current_user.person_id}
            id="new-request-form"
            phx-submit="new_request"
            class="flex flex-wrap items-center gap-2"
          >
            <label for="new-request-type" class="sr-only">{gettext("New request")}</label>
            <select id="new-request-type" name="type" class="select select-sm w-auto max-w-full">
              <option :for={type <- @request_types} value={type}>
                {DocumentUI.type_label(type)}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-primary">
              <.icon name="hero-plus" class="size-4" /> {gettext("New request")}
            </button>
          </form>
        </div>

        <.section
          :if={@to_acknowledge != []}
          id="to-acknowledge"
          title={gettext("Orders to acknowledge")}
          documents={@to_acknowledge}
          empty=""
        />

        <.section
          id="to-decide"
          title={gettext("To approve or sign")}
          documents={@inbox.to_decide}
          empty={gettext("Nothing waits for your decision.")}
        />

        <section
          :if={@inbox.instructions != []}
          id="instructions"
          class="flex flex-col gap-1"
          aria-labelledby="instructions-title"
        >
          <h2 id="instructions-title" class="flex items-center gap-2 font-semibold">
            {gettext("Instructions to carry out")}
            <span class="badge badge-sm">{length(@inbox.instructions)}</span>
          </h2>
          <ul class="divide-y divide-base-200 rounded-box border border-base-300">
            <li :for={document <- @inbox.instructions}>
              <DocumentUI.row document={document} />
              <p class="truncate px-3 pb-2 pl-11 text-sm opacity-80">
                {document.instruction.text}
              </p>
            </li>
          </ul>
        </section>

        <.section
          id="my-drafts"
          title={gettext("My drafts")}
          documents={@inbox.my_drafts}
          empty={gettext("No drafts.")}
        />

        <.section
          :if={@current_user.person_id}
          id="mine"
          title={gettext("My requests")}
          documents={@inbox.mine}
          empty={gettext("No requests.")}
        />

        <.section
          id="team"
          title={gettext("For my team")}
          documents={@inbox.team}
          empty={gettext("Nothing opened for your team.")}
        />

        <DeputiesSection.deputies
          :if={@candidates != [] or @deputies.mine != [] or @deputies.standing_in != []}
          overview={@deputies}
          candidates={@candidates}
          creating?={@creating_deputy?}
          form={@deputy_form}
          prefs={@current_user.ui_preferences}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :documents, :list, required: true
  attr :empty, :string, required: true

  defp section(assigns) do
    ~H"""
    <section id={@id} class="flex flex-col gap-1" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="flex items-center gap-2 font-semibold">
        {@title}
        <span class="badge badge-sm">{length(@documents)}</span>
      </h2>
      <p :if={@documents == []} class="text-sm opacity-60">{@empty}</p>
      <ul :if={@documents != []} class="divide-y divide-base-200 rounded-box border border-base-300">
        <li :for={document <- @documents}>
          <DocumentUI.row document={document} note={note(document)} />
        </li>
      </ul>
    </section>
    """
  end

  defp note(document) do
    cond do
      Map.get(document, :returned?) ->
        gettext("returned")

      user = Map.get(document, :on_behalf_of) ->
        gettext("for %{name}", name: user.name || user.email)

      true ->
        nil
    end
  end
end
