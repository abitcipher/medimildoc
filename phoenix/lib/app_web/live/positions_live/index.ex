defmodule AppWeb.PositionsLive.Index do
  @moduledoc """
  Positions: list + inline create/edit/delete. `organization_id`/
  `reports_to_id` are selects populated from existing rows at render time
  form per data group, dynamic options via `field_options`
  (see `AppWeb.JsonSchemaForm`).

  Deleting a position can fail (FK violation) if it still has Assignments
  or other positions `reports_to` it — migrations don't cascade on
  purpose; the error surfaces as a flash rather than a crash.

  The "New position" and edit forms are shown as the user's interface
  settings say (`AppWeb.FormPanels`) — see `OrganizationsLive.Index`.

  (UI-kit adoption): same `Cinder.collection` + relocated-
  edit-form-below-the-table pattern as `OrganizationsLive.Index` — see
  its moduledoc for why the edit form isn't spliced into the row
  anymore. `field_options` for `organization_id`/`reports_to_id` still
  needs the full lists regardless of what Cinder is currently showing —
  kept as a small separate `assign_options/1`.
  """
  use AppWeb, :live_view

  alias App.People.{Organization, Position, PositionLabel}
  alias AppWeb.{FormPanels, FormSchemas, JsonSchemaForm}

  @table_id "positions-table"

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Positions"))
     # See OrganizationsLive.Index's mount/3 for why this assign exists
     # (`@table_id` inside `~H` reads a socket assign, not the module
     # attribute the handle_event/2 clauses below use).
     |> assign(:table_id, @table_id)
     |> assign(:editing_id, nil)
     |> assign(:creating?, false)
     |> assign(:edit_form, nil)
     |> assign_options()
     |> assign_new_form()}
  end

  # Only for the organization_id/reports_to_id <select> options on both
  # forms — the visible table itself is Cinder's own query.
  defp assign_options(socket) do
    organizations = Ash.read!(Organization, actor: socket.assigns.actor)

    positions =
      Position
      |> Ash.Query.load(:organization)
      |> Ash.read!(actor: socket.assigns.actor)

    # Short labels: many posts share a title ("Company Commander" in every
    # company); the unit and grade tell them apart (App.People.PositionLabel).
    position_options =
      positions
      |> Enum.map(&{PositionLabel.short(AppWeb.PersonRows.position_summary(&1)), &1.id})
      |> Enum.sort_by(&elem(&1, 0))

    socket
    |> assign(:organization_options, Enum.map(organizations, &{&1.name, &1.id}))
    |> assign(:position_options, position_options)
  end

  defp assign_new_form(socket) do
    form =
      Position
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.actor)
      |> to_form()

    assign(socket, :form, form)
  end

  @impl true
  def handle_event("open_create", _params, socket),
    do: {:noreply, assign(socket, creating?: true, editing_id: nil, edit_form: nil)}

  def handle_event("close_create", _params, socket),
    do: {:noreply, socket |> assign(:creating?, false) |> assign_new_form()}

  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params, actor: socket.assigns.actor) do
      {:ok, _position} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Position created"))
         |> assign(:creating?, false)
         |> assign_options()
         |> assign_new_form()
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    position = Ash.get!(Position, id, actor: socket.assigns.actor)

    form =
      position
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.actor, id: "position_update")
      |> to_form()

    {:noreply, assign(socket, editing_id: id, edit_form: form, creating?: false)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, edit_form: nil)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :edit_form, AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form,
           params: params,
           actor: socket.assigns.actor
         ) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Position updated"))
         |> assign_options()
         |> assign(editing_id: nil, edit_form: nil)
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{actor: actor} = socket.assigns
    position = Ash.get!(Position, id, actor: actor)

    case Ash.destroy(position, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Position deleted"))
         |> assign_options()
         |> Cinder.refresh_table(@table_id)}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Could not delete %{title}: still has assignments or positions reporting to it — remove those first (%{reason})",
             title: position.title,
             reason: App.AshErrors.summarize(error)
           )
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-3xl mx-auto p-4 flex flex-col gap-6">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-xl font-semibold">{gettext("Positions")}</h1>
          <FormPanels.create_actions
            :if={AppWeb.Authz.can?(@current_user, "people.write")}
            id="position-actions"
            form="position"
            prefs={@current_user.ui_preferences}
            actions={[%{label: gettext("New position"), event: "open_create"}]}
          />
        </div>

        <.top_pager id={@table_id}>
          <Cinder.collection
            id={@table_id}
            query={Ash.Query.load(Position, [:organization, :holders])}
            actor={@current_user}
          >
            <:col :let={p} field="title" filter sort label={gettext("Title")}>{p.title}</:col>
            <:col :let={p} field="organization.name" filter label={gettext("Organization")}>
              {p.organization.name}
            </:col>
            <:col :let={p} field="authorised_grade" filter sort label={gettext("Authorised grade")}>
              {p.authorised_grade || "—"}
            </:col>
            <:col :let={p} field="strength" sort label={gettext("Holders")}>
              <span class={["font-mono text-sm", p.holders < p.strength && "text-warning"]}>
                {p.holders}/{p.strength}
              </span>
            </:col>
            <:col :let={p} :if={AppWeb.Authz.can?(@current_user, "people.write")} label="">
              <div class="flex gap-1">
                <button type="button" phx-click="edit" phx-value-id={p.id} class="btn btn-xs">
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm={gettext("Delete %{title}?", title: p.title)}
                  class="btn btn-xs btn-error"
                >
                  {gettext("Delete")}
                </button>
              </div>
            </:col>
          </Cinder.collection>
        </.top_pager>

        <FormPanels.form_panel
          id="position-edit"
          kind={:edit}
          open={@editing_id != nil}
          prefs={@current_user.ui_preferences}
          title={gettext("Edit")}
          close="cancel_edit"
          form_id="position-update-form"
          submit_label={gettext("Save")}
        >
          <.form
            for={@edit_form}
            id="position-update-form"
            phx-change="validate_edit"
            phx-submit="save_edit"
            class="flex flex-col gap-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:position)}
              ui_schema={FormSchemas.ui_schema(:position)}
              form={@edit_form}
              field_options={
                %{organization_id: @organization_options, reports_to_id: @position_options}
              }
            />
            <div class="form-actions flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
              <button type="button" phx-click="cancel_edit" class="btn btn-sm">
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </FormPanels.form_panel>

        <FormPanels.form_panel
          :if={AppWeb.Authz.can?(@current_user, "people.write")}
          id="position-new"
          kind={:create}
          form="position"
          open={@creating?}
          prefs={@current_user.ui_preferences}
          title={gettext("New position")}
          close="close_create"
          form_id="position-edit-form"
          submit_label={gettext("Create")}
        >
          <.form for={@form} id="position-edit-form" phx-change="validate" phx-submit="save">
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:position)}
              ui_schema={FormSchemas.ui_schema(:position)}
              form={@form}
              field_options={
                %{organization_id: @organization_options, reports_to_id: @position_options}
              }
            />
            <button type="submit" class="form-actions btn btn-primary mt-2">{gettext("Create")}</button>
          </.form>
        </FormPanels.form_panel>
      </div>
    </Layouts.app>
    """
  end
end
