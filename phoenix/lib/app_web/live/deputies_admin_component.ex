defmodule AppWeb.DeputiesAdminComponent do
  @moduledoc """
  Deputies of all users, for administrators (`users.manage`) on the Users
  page (docs/design/inbox-first.md §Stand-ins): who stands in for whom,
  when, whether it is active today; add one for any user, remove any.
  The same rules as a user's own (`App.Documents.Deputy`).
  """
  use AppWeb, :live_component

  alias App.Accounts.User
  alias App.Documents.{Deputies, Deputy}
  alias AppWeb.{DataList, DateFormat, FormPanels, FormSchemas, JsonSchemaForm}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:creating?, fn -> false end)
     |> assign(users: users())
     |> load()
     |> assign_form()}
  end

  defp users do
    User
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{name(&1), &1.id})
    |> Enum.sort()
  end

  defp load(socket) do
    deputies =
      Deputy
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: socket.assigns.actor)
      |> Ash.load!([:user, :deputy], authorize?: false)

    active = deputies |> Enum.map(& &1.user_id) |> Enum.uniq() |> Deputies.of()

    rows =
      Enum.map(deputies, fn d ->
        Map.put(d, :active?, d.deputy_id in Map.get(active, d.user_id, []))
      end)

    assign(socket, deputies: rows)
  end

  defp assign_form(socket) do
    form =
      Deputy
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.actor, id: "deputy-admin")
      |> to_form()

    assign(socket, form: form)
  end

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, creating?: true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, creating?: false)}

  def handle_event("validate", %{"form" => params}, socket),
    do: {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _} -> {:noreply, socket |> assign(creating?: false) |> load() |> assign_form()}
      {:error, form} -> {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    with {:ok, deputy} <- Ash.get(Deputy, id, actor: actor),
         :ok <- Ash.destroy(deputy, actor: actor) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp name(nil), do: "—"
  defp name(user), do: user.name || to_string(user.email)

  defp period(%{starts_on: nil}), do: gettext("whenever away")

  defp period(d),
    do: "#{DateFormat.display(d.starts_on)} – #{DateFormat.display(d.ends_on)}"

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id}>
      <div class="mb-2 flex min-h-8 flex-wrap items-center justify-between gap-2">
        <h2 class="flex items-center gap-2 font-semibold">
          {gettext("Deputies")}
          <span class="badge badge-sm badge-ghost">{length(@deputies)}</span>
          <.field_description description={
            gettext(
              "Who approves and signs for whom: with dates, or without them whenever the user is away. A deputy acts only on documents where they hold the needed permission themselves."
            )
          } />
        </h2>
        <button
          :if={not @creating?}
          id={"#{@id}-add"}
          type="button"
          phx-click="open"
          phx-target={@myself}
          class="btn btn-sm btn-primary"
        >
          <.icon name="hero-plus" class="size-4" /> {gettext("Add a deputy")}
        </button>
      </div>

      <DataList.data_list id={"#{@id}-list"} rows={@deputies} empty={gettext("No deputies.")}>
        <:col :let={d} label={gettext("User")}>{name(d.user)}</:col>
        <:col :let={d} label={gettext("Deputy")}>{name(d.deputy)}</:col>
        <:col :let={d} label={gettext("When")}>{period(d)}</:col>
        <:col :let={d} label={gettext("Now")}>
          <span :if={d.active?} class="badge badge-sm badge-success">{gettext("active")}</span>
          <span :if={!d.active?} class="opacity-60">—</span>
        </:col>
        <:action :let={d}>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={d.id}
            phx-target={@myself}
            data-confirm={gettext("Remove this deputy?")}
            class="btn btn-ghost btn-xs btn-square text-error"
            aria-label={gettext("Remove")}
            title={gettext("Remove")}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </:action>
      </DataList.data_list>

      <FormPanels.form_panel
        id={"#{@id}-panel"}
        kind={:create}
        form="deputy"
        open={@creating?}
        prefs={@actor.ui_preferences}
        title={gettext("Add a deputy")}
        close={JS.push("close", target: @myself)}
        form_id={"#{@id}-form"}
        submit_label={gettext("Add")}
      >
        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <JsonSchemaForm.json_schema_form
            schema={FormSchemas.schema(:deputy_admin)}
            ui_schema={FormSchemas.ui_schema(:deputy_admin)}
            form={@form}
            field_options={%{user_id: @users, deputy_id: @users}}
          />
          <p class="mt-1 text-xs opacity-70">{gettext("No dates: whenever the user is away.")}</p>
          <button type="submit" class="form-actions btn btn-primary btn-sm mt-2">
            {gettext("Add")}
          </button>
        </.form>
      </FormPanels.form_panel>
    </section>
    """
  end
end
