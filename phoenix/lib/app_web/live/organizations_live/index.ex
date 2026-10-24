defmodule AppWeb.OrganizationsLive.Index do
  @moduledoc """
  Organizations: list + inline create/edit/delete (form per
  data group). Self-referential hierarchy — `parent_id` was
  already fully wired at the resource layer (`belongs_to :parent`/
  `has_many :children`) but never surfaced here; now a `parent_id` select
  on both forms (`field_options`, same pattern as `PositionsLive.Index`'s
  `organization_id`/`reports_to_id`), plus a "Parent" column. Self is
  excluded from the edit form's own options (the trivial cycle); deeper
  cycles (making an org its own grandparent, etc.) are rejected by
  `App.People.Validations.OrganizationParentNotACycle` at the resource
  layer — that's the real boundary, this is just UX.

  Deleting an org can fail (FK violation) if it still has Positions or
  child orgs (`parent_id`) — migrations don't cascade on purpose; the
  error surfaces as a flash rather than a crash.

  The "New organization" and edit forms are shown as the user's interface
  settings say (`AppWeb.FormPanels`, docs/design/ui-preferences.md): in the
  page or in a modal window, the "New" form always visible or opened from
  a toolbar or a ⋮ menu. Opening is server state (`creating?`,
  `editing_id`), never a native `<details>` — confirmed live that
  `<details open>` isn't LiveView-tracked, so a `phx-change` round-trip
  patches it right back to closed.

  (UI-kit adoption): the table is now `Cinder.collection`
  (real filter/sort/pagination), but the edit form is deliberately NOT
  spliced into the editing row the way it was before Cinder — Cinder's
  `:col` slots each control their own cell, not the whole `<tr>`, so
  "replace this one row with a full-width form" isn't natural for it.
  Instead "Edit" opens the same form as a section below the table (same
  page, same always-visible-not-modal philosophy as the moduledoc above
  already commits to — just relocated, not turned into a route change
  or a dialog). `field_options` for the `parent_id` selects (both forms)
  needs the full organization list regardless of what Cinder is
  currently showing (filtered/paginated) — kept as a small separate
  `Ash.read!` via `assign_options/1`, intentionally not reusing
  whatever Cinder has rendered.
  """
  use AppWeb, :live_view

  alias App.People.Organization
  alias AppWeb.{FormPanels, FormSchemas, JsonSchemaForm}

  @table_id "organizations-table"

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Organizations"))
     # `@table_id` inside `~H` reads a socket assign, not the module
     # attribute below (that's only usable from plain Elixir code, e.g.
     # `handle_event`'s `Cinder.refresh_table/2` calls) — caught live via
     # a `KeyError: key :table_id not found` the first time this was
     # written without this assign.
     |> assign(:table_id, @table_id)
     |> assign(:editing_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:creating?, false)
     |> assign_options()
     |> assign_new_form()}
  end

  # Only for the parent_id <select> options on both forms — the visible
  # table itself is Cinder's own query, not this list.
  defp assign_options(socket) do
    organizations = Ash.read!(Organization, actor: socket.assigns.actor)
    assign(socket, :organizations, organizations)
  end

  defp assign_new_form(socket) do
    form =
      Organization
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.actor)
      |> to_form()

    assign(socket, :form, form)
  end

  # All orgs are valid parents for a brand-new one — it can't be anyone's
  # ancestor yet (nothing points at an id that doesn't exist in the DB).
  defp organization_options(organizations, exclude_id \\ nil) do
    organizations
    |> Enum.reject(&(&1.id == exclude_id))
    |> Enum.map(&{&1.name, &1.id})
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
      {:ok, _org} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Organization created"))
         |> assign(:creating?, false)
         |> assign_options()
         |> assign_new_form()
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    org = Ash.get!(Organization, id, actor: socket.assigns.actor)

    form =
      org
      |> AshPhoenix.Form.for_update(:update,
        actor: socket.assigns.actor,
        id: "organization_update"
      )
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
         |> put_flash(:info, gettext("Organization updated"))
         |> assign_options()
         |> assign(editing_id: nil, edit_form: nil)
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{actor: actor} = socket.assigns
    org = Ash.get!(Organization, id, actor: actor)

    case Ash.destroy(org, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Organization deleted"))
         |> assign_options()
         |> Cinder.refresh_table(@table_id)}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Could not delete %{name}: still has positions or child organizations — remove those first (%{reason})",
             name: org.name,
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
          <h1 class="text-xl font-semibold">{gettext("Organizations")}</h1>
          <FormPanels.create_actions
            :if={AppWeb.Authz.can?(@current_user, "people.write")}
            id="organization-actions"
            form="organization"
            prefs={@current_user.ui_preferences}
            actions={[%{label: gettext("New organization"), event: "open_create"}]}
          />
        </div>

        <.top_pager id={@table_id}>
          <Cinder.collection
            id={@table_id}
            query={Ash.Query.load(Organization, :parent)}
            actor={@current_user}
          >
            <:col :let={org} field="name" filter sort label={gettext("Name")}>
              {org.name} <.synthetic_badge :if={org.synthetic} />
            </:col>
            <:col :let={org} field="kind" filter={:select} label={gettext("Kind")}>{org.kind}</:col>
            <:col :let={org} field="parent.name" filter label={gettext("Parent")}>
              {if org.parent, do: org.parent.name, else: "—"}
            </:col>
            <:col :let={org} :if={AppWeb.Authz.can?(@current_user, "people.write")} label="">
              <div class="flex gap-1">
                <button type="button" phx-click="edit" phx-value-id={org.id} class="btn btn-xs">
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={org.id}
                  data-confirm={gettext("Delete %{name}?", name: org.name)}
                  class="btn btn-xs btn-error"
                >
                  {gettext("Delete")}
                </button>
              </div>
            </:col>
          </Cinder.collection>
        </.top_pager>

        <FormPanels.form_panel
          id="organization-edit"
          kind={:edit}
          open={@editing_id != nil}
          prefs={@current_user.ui_preferences}
          title={gettext("Edit")}
          close="cancel_edit"
          form_id="organization-update-form"
          submit_label={gettext("Save")}
        >
          <.form
            for={@edit_form}
            id="organization-update-form"
            phx-change="validate_edit"
            phx-submit="save_edit"
            class="flex flex-col gap-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:organization)}
              ui_schema={FormSchemas.ui_schema(:organization)}
              form={@edit_form}
              field_options={%{parent_id: organization_options(@organizations, @editing_id)}}
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
          id="organization-new"
          kind={:create}
          form="organization"
          open={@creating?}
          prefs={@current_user.ui_preferences}
          title={gettext("New organization")}
          close="close_create"
          form_id="organization-edit-form"
          submit_label={gettext("Create")}
        >
          <.form for={@form} id="organization-edit-form" phx-change="validate" phx-submit="save">
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:organization)}
              ui_schema={FormSchemas.ui_schema(:organization)}
              form={@form}
              field_options={%{parent_id: organization_options(@organizations)}}
            />
            <button type="submit" class="form-actions btn btn-primary mt-2">{gettext("Create")}</button>
          </.form>
        </FormPanels.form_panel>
      </div>
    </Layouts.app>
    """
  end
end
