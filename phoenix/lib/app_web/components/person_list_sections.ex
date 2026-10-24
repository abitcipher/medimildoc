defmodule AppWeb.PersonListSections do
  @moduledoc """
  The person page's list sections (docs/design/ui-preferences.md):
  assignment history, national ID numbers and identity documents. Each is
  a header with its count and add control, the entries as a table or
  cards, icon buttons per entry, and the add and edit forms opened on
  demand as the viewer's interface settings say. Markup only — the events
  (`open_create`, `edit_identifier`, `save_document`, …) are handled by
  `AppWeb.PeopleLive.Show`, which passes its assigns in.
  """
  use AppWeb, :html

  alias AppWeb.{DataList, FormPanels, FormSchemas, JsonSchemaForm}

  attr :person, :map, required: true
  attr :current_user, :map, required: true
  attr :creating, :string, default: nil
  attr :editing_assignment_id, :any, default: nil
  attr :assignment_edit_form, :any, default: nil
  attr :assignment_form, :any, required: true
  attr :position_options, :list, default: []

  def assignments(assigns) do
    ~H"""
    <section id="assignments-section">
      <DataList.section_header
        id="assignments-header"
        title={gettext("Assignment history")}
        count={length(@person.assignments)}
        prefs={@current_user.ui_preferences}
        form="assignment"
        actions={
          if AppWeb.Authz.can?(@current_user, "people.write"),
            do: [
              %{
                label: gettext("Assign to a position"),
                event: "open_create",
                values: %{form: "assignment"}
              }
            ],
            else: []
        }
      />
      <DataList.data_list
        id="assignments-list"
        rows={@person.assignments}
        current={@editing_assignment_id}
        empty={gettext("No assignments yet.")}
      >
        <:col :let={a} label={gettext("Position")}>{a.position.title}</:col>
        <:col :let={a} label={gettext("Organization")}>
          {a.position.organization.name}
        </:col>
        <:col :let={a} label={gettext("Starts")}>
          {AppWeb.DateFormat.display(a.starts_on)}
          <.order_ref id={a.basis_document_id} document={a.basis_document} />
        </:col>
        <:col :let={a} label={gettext("Ends")}>
          {if a.ends_on,
            do: AppWeb.DateFormat.display(a.ends_on),
            else: gettext("current")}
          <.order_ref id={a.end_document_id} document={a.end_document} />
        </:col>
        <:action :let={a} :if={AppWeb.Authz.can?(@current_user, "people.write")}>
          <DataList.row_actions
            id={a.id}
            edit="edit_assignment"
            delete="delete_assignment"
            confirm={gettext("Remove this assignment?")}
          />
        </:action>
      </DataList.data_list>

      <FormPanels.form_panel
        id="assignment-edit-panel"
        kind={:edit}
        open={@editing_assignment_id != nil}
        prefs={@current_user.ui_preferences}
        title={gettext("Edit assignment")}
        close="cancel_edit_assignment"
        form_id="assignment-edit-form-element"
        submit_label={gettext("Save")}
      >
        <.form
          :if={@assignment_edit_form}
          for={@assignment_edit_form}
          id="assignment-edit-form-element"
          phx-change="validate_assignment_edit"
          phx-submit="save_assignment_edit"
          class="flex flex-col gap-2"
        >
          <JsonSchemaForm.json_schema_form
            schema={
              %{
                "properties" => %{
                  "starts_on" => %{"type" => "string", "format" => "date"},
                  "ends_on" => %{"type" => "string", "format" => "date"}
                }
              }
            }
            ui_schema={
              %{
                "elements" => [
                  %{
                    "type" => "Control",
                    "scope" => "#/properties/starts_on",
                    "label" => gettext("Start date")
                  },
                  %{
                    "type" => "Control",
                    "scope" => "#/properties/ends_on",
                    "label" => gettext("End date")
                  }
                ]
              }
            }
            form={@assignment_edit_form}
          />
          <div class="form-actions flex gap-2">
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
            <button type="button" phx-click="cancel_edit_assignment" class="btn btn-sm">
              {gettext("Cancel")}
            </button>
          </div>
        </.form>
      </FormPanels.form_panel>

      <FormPanels.form_panel
        :if={AppWeb.Authz.can?(@current_user, "people.write")}
        id="assignment-new-panel"
        kind={:create}
        form="assignment"
        open={@creating == "assignment"}
        prefs={@current_user.ui_preferences}
        title={gettext("Assign to a position")}
        close="close_create"
        form_id="assignment-form-element"
        submit_label={gettext("Save assignment")}
      >
        <.form
          for={@assignment_form}
          id="assignment-form-element"
          phx-change="validate_assignment"
          phx-submit="save_assignment"
        >
          <JsonSchemaForm.json_schema_form
            schema={FormSchemas.schema(:assignment)}
            ui_schema={FormSchemas.ui_schema(:assignment)}
            form={@assignment_form}
            field_options={%{position_id: @position_options}}
          />
          <button type="submit" class="form-actions btn btn-primary mt-2">
            {gettext("Save assignment")}
          </button>
        </.form>
      </FormPanels.form_panel>
    </section>
    """
  end

  attr :current_user, :map, required: true
  attr :creating, :string, default: nil
  attr :identifiers, :list, required: true
  attr :editing_identifier_id, :any, default: nil
  attr :identifier_edit_form, :any, default: nil
  attr :identifier_form, :any, required: true
  attr :documents, :list, required: true
  attr :editing_document_id, :any, default: nil
  attr :document_edit_form, :any, default: nil
  attr :document_form, :any, required: true

  def identity(assigns) do
    ~H"""
    <div class="flex flex-col gap-8">
      <section id="identifiers-section">
        <DataList.section_header
          id="identifiers-header"
          title={gettext("National ID numbers")}
          count={length(@identifiers)}
          prefs={@current_user.ui_preferences}
          form="identifier"
          actions={
            if AppWeb.Authz.can?(@current_user, "people.private.write"),
              do: [
                %{
                  label: gettext("Add an identifier"),
                  event: "open_create",
                  values: %{form: "identifier"}
                }
              ],
              else: []
          }
        />
        <DataList.data_list
          id="identifiers-list"
          rows={@identifiers}
          current={@editing_identifier_id}
          empty={gettext("No identifiers yet.")}
        >
          <:col :let={i} label={gettext("Type")}>
            {i.id_type}{if i.id_type == :other, do: " (#{i.other_type_label})"}
          </:col>
          <:col :let={i} label={gettext("Country")}><.country code={i.country} /></:col>
          <:col :let={i} label={gettext("Value")} class="font-mono">{i.value}</:col>
          <:col :let={i} label={gettext("Current")}>
            <.badge :if={i.is_current} color="success">{gettext("Current")}</.badge>
            <.badge :if={!i.is_current} color="neutral" outline>
              {gettext("Superseded")}
            </.badge>
          </:col>
          <:action :let={i} :if={AppWeb.Authz.can?(@current_user, "people.private.write")}>
            <DataList.row_actions
              id={i.id}
              edit="edit_identifier"
              delete="delete_identifier"
              confirm={gettext("Remove this identifier?")}
            />
          </:action>
        </DataList.data_list>

        <FormPanels.form_panel
          id="identifier-edit-panel"
          kind={:edit}
          open={@editing_identifier_id != nil}
          prefs={@current_user.ui_preferences}
          title={gettext("Edit identifier")}
          close="cancel_edit_identifier"
          form_id="identifier-edit-form-element"
          submit_label={gettext("Save")}
        >
          <.form
            :if={@identifier_edit_form}
            for={@identifier_edit_form}
            id="identifier-edit-form-element"
            phx-change="validate_identifier_edit"
            phx-submit="save_identifier_edit"
            class="flex flex-col gap-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:person_identifier)}
              ui_schema={FormSchemas.ui_schema(:person_identifier)}
              form={@identifier_edit_form}
            />
            <div class="form-actions flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
              <button type="button" phx-click="cancel_edit_identifier" class="btn btn-sm">
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </FormPanels.form_panel>

        <FormPanels.form_panel
          :if={AppWeb.Authz.can?(@current_user, "people.private.write")}
          id="identifier-new-panel"
          kind={:create}
          form="identifier"
          open={@creating == "identifier"}
          prefs={@current_user.ui_preferences}
          title={gettext("Add an identifier")}
          close="close_create"
          form_id="identifier-form-element"
          submit_label={gettext("Save identifier")}
        >
          <.form
            for={@identifier_form}
            id="identifier-form-element"
            phx-change="validate_identifier"
            phx-submit="save_identifier"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:person_identifier)}
              ui_schema={FormSchemas.ui_schema(:person_identifier)}
              form={@identifier_form}
            />
            <button type="submit" class="form-actions btn btn-primary mt-2">
              {gettext("Save identifier")}
            </button>
          </.form>
        </FormPanels.form_panel>
      </section>

      <section id="identity-documents-section">
        <DataList.section_header
          id="identity-documents-header"
          title={gettext("Identity documents")}
          count={length(@documents)}
          prefs={@current_user.ui_preferences}
          form="identity_document"
          actions={
            if AppWeb.Authz.can?(@current_user, "people.private.write"),
              do: [
                %{
                  label: gettext("Add a document"),
                  event: "open_create",
                  values: %{form: "identity_document"}
                }
              ],
              else: []
          }
        />
        <DataList.data_list
          id="identity-documents-list"
          rows={@documents}
          current={@editing_document_id}
          empty={gettext("No documents yet.")}
        >
          <:col :let={d} label={gettext("Type")}>{d.document_type}</:col>
          <:col :let={d} label={gettext("Number")} class="font-mono">
            {if d.series, do: "#{d.series} ", else: ""}{d.number}
          </:col>
          <:col :let={d} label={gettext("Issuing country")}>
            <.country code={d.issuing_country} />
          </:col>
          <:col :let={d} label={gettext("Expires")}>
            {if d.expires_on, do: AppWeb.DateFormat.display(d.expires_on), else: "—"}
          </:col>
          <:action :let={d} :if={AppWeb.Authz.can?(@current_user, "people.private.write")}>
            <DataList.row_actions
              id={d.id}
              edit="edit_document"
              delete="delete_document"
              confirm={gettext("Remove this document?")}
            />
          </:action>
        </DataList.data_list>

        <FormPanels.form_panel
          id="identity-document-edit-panel"
          kind={:edit}
          open={@editing_document_id != nil}
          prefs={@current_user.ui_preferences}
          title={gettext("Edit document")}
          close="cancel_edit_document"
          form_id="document-edit-form-element"
          submit_label={gettext("Save")}
        >
          <.form
            :if={@document_edit_form}
            for={@document_edit_form}
            id="document-edit-form-element"
            phx-change="validate_document_edit"
            phx-submit="save_document_edit"
            class="flex flex-col gap-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:identity_document)}
              ui_schema={FormSchemas.ui_schema(:identity_document)}
              form={@document_edit_form}
            />
            <div class="form-actions flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
              <button type="button" phx-click="cancel_edit_document" class="btn btn-sm">
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </FormPanels.form_panel>

        <FormPanels.form_panel
          :if={AppWeb.Authz.can?(@current_user, "people.private.write")}
          id="identity-document-new-panel"
          kind={:create}
          form="identity_document"
          open={@creating == "identity_document"}
          prefs={@current_user.ui_preferences}
          title={gettext("Add a document")}
          close="close_create"
          form_id="document-form-element"
          submit_label={gettext("Save document")}
        >
          <.form
            for={@document_form}
            id="document-form-element"
            phx-change="validate_document"
            phx-submit="save_document"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:identity_document)}
              ui_schema={FormSchemas.ui_schema(:identity_document)}
              form={@document_form}
            />
            <button type="submit" class="form-actions btn btn-primary mt-2">
              {gettext("Save document")}
            </button>
          </.form>
        </FormPanels.form_panel>
      </section>
    </div>
    """
  end

  # The personnel order behind an assignment's start or end: its number,
  # linked; "by order" alone when the viewer may not read orders.
  attr :id, :any, required: true
  attr :document, :any, required: true

  defp order_ref(%{id: nil} = assigns), do: ~H""

  defp order_ref(assigns) do
    ~H"""
    <.link
      :if={match?(%{number: _}, @document)}
      navigate={"/documents/#{@id}"}
      class="block font-mono text-xs link link-hover opacity-80"
    >
      № {@document.number}
    </.link>
    <span :if={!match?(%{number: _}, @document)} class="block text-xs opacity-60">
      {gettext("by order")}
    </span>
    """
  end
end
