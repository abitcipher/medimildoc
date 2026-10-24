defmodule AppWeb.CareProvidersLive.Index do
  @moduledoc """
  The register of medical care providers (docs/design/referral-discharge.md):
  a searchable list, our own priority units first; create and edit with
  `providers.manage`. Same layout as `OrganizationsLive.Index`: the list,
  the edit form below it when editing, the new-provider form last.
  """
  use AppWeb, :live_view

  alias App.Care.Provider
  alias App.People.Organization
  alias AppWeb.{FormPanels, FormSchemas, JsonSchemaForm}

  @table_id "care-providers-table"

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(
       actor: actor,
       page_title: gettext("Care providers"),
       table_id: @table_id,
       manage?: AppWeb.Authz.can?(actor, "providers.manage"),
       editing_id: nil,
       edit_form: nil,
       creating?: false,
       unit_options:
         Organization |> Ash.read!(actor: actor) |> Enum.map(&{&1.name, &1.id}) |> Enum.sort()
     )
     |> assign_new_form()}
  end

  defp assign_new_form(socket) do
    form =
      Provider |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.actor) |> to_form()

    assign(socket, :form, form)
  end

  @impl true
  def handle_event("open_create", _params, socket),
    do: {:noreply, assign(socket, creating?: true, editing_id: nil, edit_form: nil)}

  def handle_event("close_create", _params, socket),
    do: {:noreply, socket |> assign(:creating?, false) |> assign_new_form()}

  def handle_event("validate", %{"form" => params}, socket),
    do: {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params, actor: socket.assigns.actor) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Provider added"))
         |> assign(:creating?, false)
         |> assign_new_form()
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    form =
      Provider
      |> Ash.get!(id, actor: socket.assigns.actor)
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.actor, id: "provider-edit")
      |> to_form()

    {:noreply, assign(socket, editing_id: id, edit_form: form, creating?: false)}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing_id: nil, edit_form: nil)}

  def handle_event("validate_edit", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :edit_form, AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form,
           params: params,
           actor: socket.assigns.actor
         ) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Provider updated"))
         |> assign(editing_id: nil, edit_form: nil)
         |> Cinder.refresh_table(@table_id)}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-6 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Care providers")}
            <.field_description description={
              gettext(
                "Organizations providing medical care, named in referrals and discharge summaries. Our own units (priority) need no service contract or transfer of information to a third party and are listed first."
              )
            } />
          </h1>
          <FormPanels.create_actions
            :if={@manage?}
            id="provider-actions"
            form="provider"
            prefs={@current_user.ui_preferences}
            actions={[%{label: gettext("New provider"), event: "open_create"}]}
          />
        </div>

        <.top_pager id={@table_id}>
          <Cinder.collection
            id={@table_id}
            query={Ash.Query.sort(Provider, priority: :desc, name: :asc)}
            actor={@current_user}
          >
            <:col :let={provider} field="name" filter sort label={gettext("Name")}>
              <span class="flex flex-wrap items-center gap-1">
                {provider.name}
                <.text_badge
                  :if={provider.priority}
                  text={gettext("Our unit")}
                  class="badge-sm badge-primary"
                />
                <.text_badge
                  :if={!provider.active}
                  text={gettext("Inactive")}
                  class="badge-sm badge-ghost"
                />
                <.synthetic_badge :if={provider.synthetic} />
              </span>
            </:col>
            <:col :let={provider} field="provider_type" filter={:select} label={gettext("Type")}>
              {AppWeb.SchemaText.choice(
                Atom.to_string(provider.provider_type),
                FormSchemas.schema(:care_provider)["properties"]["provider_type"]["x-enum-labels"]
              )}
            </:col>
            <:col :let={provider} field="priority" filter={:boolean} label={gettext("Our unit")}>
              {if provider.priority, do: gettext("Yes"), else: gettext("No")}
            </:col>
            <:col :let={provider} field="locality" filter sort label={gettext("Locality")}>
              {provider.locality}
            </:col>
            <:col :let={provider} field="registry_code" filter label={gettext("Registry code")}>
              {provider.registry_code}
            </:col>
            <:col :let={provider} :if={@manage?} label="">
              <button type="button" phx-click="edit" phx-value-id={provider.id} class="btn btn-xs">
                {gettext("Edit")}
              </button>
            </:col>
          </Cinder.collection>
        </.top_pager>

        <FormPanels.form_panel
          id="provider-edit"
          kind={:edit}
          open={@editing_id != nil}
          prefs={@current_user.ui_preferences}
          title={gettext("Edit")}
          close="cancel_edit"
          form_id="provider-edit-form"
          submit_label={gettext("Save")}
        >
          <.form
            for={@edit_form}
            id="provider-edit-form"
            phx-change="validate_edit"
            phx-submit="save_edit"
            class="flex flex-col gap-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:care_provider)}
              ui_schema={FormSchemas.ui_schema(:care_provider)}
              form={@edit_form}
              field_options={%{organization_id: @unit_options}}
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
          :if={@manage?}
          id="provider-new"
          kind={:create}
          form="provider"
          open={@creating?}
          prefs={@current_user.ui_preferences}
          title={gettext("New provider")}
          close="close_create"
          form_id="provider-new-form"
          submit_label={gettext("Add")}
        >
          <.form for={@form} id="provider-new-form" phx-change="validate" phx-submit="save">
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:care_provider)}
              ui_schema={FormSchemas.ui_schema(:care_provider)}
              form={@form}
              field_options={%{organization_id: @unit_options}}
            />
            <button type="submit" class="form-actions btn btn-primary mt-2">{gettext("Add")}</button>
          </.form>
        </FormPanels.form_panel>
      </div>
    </Layouts.app>
    """
  end
end
