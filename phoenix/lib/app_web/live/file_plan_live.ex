defmodule AppWeb.FilePlanLive do
  @moduledoc """
  The file plan (номенклатура справ) for a year
  (docs/design/registers-file-plan.md): cases with index, title, retention
  period and the document types filed into them, how many documents each
  holds (→ its contents on the Registers page). The records officer
  (`records.manage`) adds, edits and removes empty cases, copies last
  year's plan or starts from the template; HR reads it. The year is in
  the URL.
  """
  use AppWeb, :live_view

  alias App.Documents.Types
  alias App.People.Organization
  alias App.Records.{Case, FilePlan}
  alias AppWeb.{DataList, DocumentUI, FormPanels, FormSchemas, JsonSchemaForm}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: gettext("File plan"),
       manage?: AppWeb.Authz.can?(actor, "records.manage"),
       creating?: false,
       editing_id: nil,
       edit_form: nil,
       schema: case_schema(),
       unit_options:
         Organization |> Ash.read!(actor: actor) |> Enum.map(&{&1.name, &1.id}) |> Enum.sort()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    year =
      case Integer.parse(params["year"] || "") do
        {year, ""} when year in 2000..2100 -> year
        _ -> Date.utc_today().year
      end

    {:noreply, socket |> assign(year: year) |> load() |> assign_new_form()}
  end

  defp load(socket) do
    actor = socket.assigns.current_user
    cases = FilePlan.cases(socket.assigns.year, actor)

    assign(socket,
      cases: cases,
      counts: FilePlan.counts(Enum.map(cases, & &1.id)),
      previous: length(FilePlan.cases(socket.assigns.year - 1, actor)),
      disposal: FilePlan.due_for_disposal(Date.utc_today(), actor),
      summary: summary(cases)
    )
  end

  defp assign_new_form(socket) do
    form =
      Case
      |> AshPhoenix.Form.for_create(:create,
        actor: socket.assigns.current_user,
        id: "case-new"
      )
      |> to_form()

    assign(socket, form: form)
  end

  # The document types to choose from come from the document type
  # definitions, so the form's JSON Schema doesn't repeat them.
  defp case_schema do
    types = Types.ids()

    FormSchemas.schema(:file_plan_case)
    |> put_in(
      ["properties", "document_types", "items", "enum"],
      Enum.map(types, &Atom.to_string/1)
    )
    |> put_in(
      ["properties", "document_types", "x-enum-labels"],
      Map.new(types, &{Atom.to_string(&1), Types.label(&1)})
    )
  end

  @impl true
  def handle_event("open_create", _params, socket),
    do: {:noreply, assign(socket, creating?: true, editing_id: nil, edit_form: nil)}

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, creating?: false)}

  def handle_event("validate", %{"form" => params}, socket) do
    params = with_year(params, socket)
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: with_year(params, socket)) do
      {:ok, kase} ->
        filed = FilePlan.file_backlog(kase)

        {:noreply,
         socket
         |> assign(creating?: false)
         |> load()
         |> assign_new_form()
         |> put_flash(:info, saved_message(filed))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("edit_case", %{"id" => id}, socket) do
    kase = Enum.find(socket.assigns.cases, &(&1.id == id))

    form =
      kase
      |> AshPhoenix.Form.for_update(:update,
        actor: socket.assigns.current_user,
        id: "case-edit"
      )
      |> to_form()

    {:noreply, assign(socket, editing_id: id, edit_form: form, creating?: false)}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing_id: nil, edit_form: nil)}

  def handle_event("validate_edit", %{"form" => params}, socket),
    do:
      {:noreply,
       assign(socket, edit_form: AshPhoenix.Form.validate(socket.assigns.edit_form, params))}

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, kase} ->
        filed = FilePlan.file_backlog(kase)

        {:noreply,
         socket
         |> assign(editing_id: nil, edit_form: nil)
         |> load()
         |> put_flash(:info, saved_message(filed))}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  def handle_event("delete_case", %{"id" => id}, socket) do
    kase = Enum.find(socket.assigns.cases, &(&1.id == id))

    case kase && FilePlan.delete(kase, socket.assigns.current_user) do
      :ok ->
        {:noreply, socket |> load() |> put_flash(:info, gettext("Case removed"))}

      {:error, :not_empty} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Documents are filed into this case; it can't be removed.")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the case."))}
    end
  end

  # Closing (docs/design/registers-file-plan.md §Closing).
  def handle_event("close_case", %{"id" => id}, socket), do: case_action(socket, id, :close)
  def handle_event("reopen_case", %{"id" => id}, socket), do: case_action(socket, id, :reopen)

  def handle_event("close_year", _params, socket) do
    closed = FilePlan.close_year(socket.assigns.year, socket.assigns.current_user)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, ngettext("%{count} case closed", "%{count} cases closed", closed))}
  end

  def handle_event("copy_previous", _params, socket) do
    year = socket.assigns.year
    created = FilePlan.copy(year - 1, year, socket.assigns.current_user)
    {:noreply, socket |> load() |> put_flash(:info, created_message(created))}
  end

  def handle_event("fill_template", _params, socket) do
    created = FilePlan.copy(:template, socket.assigns.year, socket.assigns.current_user)
    {:noreply, socket |> load() |> put_flash(:info, created_message(created))}
  end

  defp with_year(params, socket), do: Map.put(params, "year", socket.assigns.year)

  defp case_action(socket, id, action) do
    with %Case{} = kase <- Enum.find(socket.assigns.cases, &(&1.id == id)),
         {:ok, _} <-
           kase
           |> Ash.Changeset.for_update(action, %{}, actor: socket.assigns.current_user)
           |> Ash.update() do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not change the case."))}
    end
  end

  defp summary(cases) do
    by = Enum.frequencies_by(cases, &FilePlan.category/1)

    %{
      total: length(cases),
      closed: Enum.count(cases, & &1.closed_on),
      permanent: Map.get(by, :permanent, 0),
      long: Map.get(by, :long, 0),
      temporary: Map.get(by, :temporary, 0),
      unspecified: Map.get(by, :unspecified, 0)
    }
  end

  defp kind_label(:permanent), do: gettext("Permanent")
  defp kind_label(:long), do: gettext("Long-term (over 10 years)")
  defp kind_label(:temporary), do: gettext("Temporary (up to 10 years)")
  defp kind_label(:unspecified), do: gettext("No period given")

  defp saved_message(0), do: gettext("Saved")

  defp saved_message(filed),
    do: ngettext("Saved; %{count} document filed", "Saved; %{count} documents filed", filed)

  defp created_message(created),
    do: ngettext("%{count} case created", "%{count} cases created", created)

  defp type_labels(case_types) do
    Enum.map(case_types, fn type ->
      type |> String.to_existing_atom() |> DocumentUI.type_label()
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("File plan")}
            <.field_description description={
              gettext(
                "The cases of a year. Signed documents are filed into the case of their type and year; documents signed before their case existed are filed when it is created."
              )
            } />
          </h1>
          <div class="join" id="year-nav">
            <.link patch={~p"/file-plan?year=#{@year - 1}"} class="btn btn-sm join-item">
              <.icon name="hero-chevron-left" class="size-4" />
              <span class="sr-only">{gettext("Previous year")}</span>
            </.link>
            <span class="btn btn-sm join-item pointer-events-none">{@year}</span>
            <.link patch={~p"/file-plan?year=#{@year + 1}"} class="btn btn-sm join-item">
              <.icon name="hero-chevron-right" class="size-4" />
              <span class="sr-only">{gettext("Next year")}</span>
            </.link>
          </div>
        </div>

        <div :if={@manage?} class="flex flex-wrap gap-2">
          <button
            :if={Enum.any?(@cases, &is_nil(&1.closed_on))}
            id="close-year"
            type="button"
            phx-click="close_year"
            data-confirm={
              gettext("Close all cases of %{year}? Nothing more is filed into them.", year: @year)
            }
            class="btn btn-sm"
          >
            <.icon name="hero-lock-closed" class="size-4" />
            {gettext("Close the cases of %{year}", year: @year)}
          </button>
          <button
            :if={@previous > 0}
            id="copy-previous"
            type="button"
            phx-click="copy_previous"
            class="btn btn-sm"
          >
            <.icon name="hero-document-duplicate" class="size-4" />
            {gettext("Copy cases from %{year}", year: @year - 1)}
          </button>
          <button
            :if={@cases == []}
            id="fill-template"
            type="button"
            phx-click="fill_template"
            class="btn btn-sm"
          >
            <.icon name="hero-sparkles" class="size-4" /> {gettext("Start from the template")}
          </button>
        </div>

        <section id="cases">
          <DataList.section_header
            id="cases-header"
            title={gettext("Cases")}
            count={length(@cases)}
            prefs={@current_user.ui_preferences}
            form="case"
            actions={
              if @manage?,
                do: [%{label: gettext("New case"), event: "open_create"}],
                else: []
            }
          />
          <DataList.data_list
            id="cases-list"
            rows={@cases}
            current={@editing_id}
            empty={gettext("No cases for this year.")}
          >
            <:col :let={c} label={gettext("Index")} class="font-mono">
              {c.index}
              <span :if={c.closed_on} class="badge badge-sm badge-neutral ml-1 font-sans">
                {gettext("closed")}
              </span>
            </:col>
            <:col :let={c} label={gettext("Title")}>{c.title}</:col>
            <:col :let={c} label={gettext("Retention")}>
              {c.retention}
              <span :if={c.retention_ref} class="opacity-70">({c.retention_ref})</span>
            </:col>
            <:col :let={c} label={gettext("Document types")}>
              <span class="flex flex-wrap gap-1">
                <span :for={label <- type_labels(c.document_types)} class="badge badge-sm badge-ghost">
                  {label}
                </span>
              </span>
            </:col>
            <:col :let={c} label={gettext("Documents")}>
              <.link navigate={~p"/registers?case=#{c.id}"} class="link" data-case-count={c.id}>
                {Map.get(@counts, c.id, 0)}
              </.link>
            </:col>
            <:action :let={c} :if={@manage?}>
              <button
                :if={is_nil(c.closed_on)}
                type="button"
                phx-click="close_case"
                phx-value-id={c.id}
                class="btn btn-ghost btn-xs btn-square"
                aria-label={gettext("Close the case")}
                title={gettext("Close the case")}
              >
                <.icon name="hero-lock-closed" class="size-4" />
              </button>
              <button
                :if={c.closed_on}
                type="button"
                phx-click="reopen_case"
                phx-value-id={c.id}
                class="btn btn-ghost btn-xs btn-square"
                aria-label={gettext("Reopen the case")}
                title={gettext("Reopen the case")}
              >
                <.icon name="hero-lock-open" class="size-4" />
              </button>
              <DataList.row_actions
                id={c.id}
                edit="edit_case"
                delete="delete_case"
                confirm={gettext("Remove this case?")}
              />
            </:action>
          </DataList.data_list>

          <FormPanels.form_panel
            :if={@manage?}
            id="case-edit-panel"
            kind={:edit}
            open={@editing_id != nil}
            prefs={@current_user.ui_preferences}
            title={gettext("Edit case")}
            close="cancel_edit"
            form_id="case-edit-form"
            submit_label={gettext("Save")}
          >
            <.form
              :if={@edit_form}
              for={@edit_form}
              id="case-edit-form"
              phx-change="validate_edit"
              phx-submit="save_edit"
            >
              <JsonSchemaForm.json_schema_form
                schema={@schema}
                ui_schema={FormSchemas.ui_schema(:file_plan_case)}
                form={@edit_form}
                field_options={%{organization_id: @unit_options}}
              />
              <button type="submit" class="form-actions btn btn-primary btn-sm mt-2">
                {gettext("Save")}
              </button>
            </.form>
          </FormPanels.form_panel>

          <FormPanels.form_panel
            :if={@manage?}
            id="case-new-panel"
            kind={:create}
            form="case"
            open={@creating?}
            prefs={@current_user.ui_preferences}
            title={gettext("New case")}
            close="close_create"
            form_id="case-new-form"
            submit_label={gettext("Add")}
          >
            <.form for={@form} id="case-new-form" phx-change="validate" phx-submit="save">
              <JsonSchemaForm.json_schema_form
                schema={@schema}
                ui_schema={FormSchemas.ui_schema(:file_plan_case)}
                form={@form}
                field_options={%{organization_id: @unit_options}}
              />
              <button type="submit" class="form-actions btn btn-primary btn-sm mt-2">
                {gettext("Add")}
              </button>
            </.form>
          </FormPanels.form_panel>
        </section>

        <section :if={@cases != []} id="inventory">
          <DataList.section_header
            id="inventory-header"
            title={gettext("Inventory of cases")}
            help={
              gettext(
                "The inventory lists the year's closed cases of one retention class: dates of the first and last document and how many documents each holds."
              )
            }
          />
          <p id="plan-summary" class="mb-3 text-sm opacity-80">
            {gettext(
              "%{total} cases, %{closed} closed: permanent %{permanent}, long-term %{long}, temporary %{temporary}, no period %{unspecified}.",
              @summary
            )}
          </p>
          <ul class="flex flex-col gap-2">
            <li
              :for={kind <- App.Records.Inventory.kinds()}
              :if={Map.get(@summary, kind) > 0}
              class="flex flex-wrap items-center gap-2"
            >
              <span class="min-w-48">{kind_label(kind)}</span>
              <a
                href={~p"/exports/case-inventory.pdf?year=#{@year}&kind=#{kind}"}
                target="_blank"
                rel="noopener"
                class="btn btn-xs"
              >
                PDF
              </a>
              <a href={~p"/exports/case-inventory.xlsx?year=#{@year}&kind=#{kind}"} class="btn btn-xs">
                .xlsx
              </a>
            </li>
          </ul>
        </section>

        <section :if={@disposal != []} id="disposal">
          <DataList.section_header
            id="disposal-header"
            title={gettext("Due for disposal")}
            count={length(@disposal)}
            help={
              gettext(
                "Closed cases whose retention period has ended (counted from the 1st of January after their year). Permanent cases are never listed."
              )
            }
          />
          <a
            :if={@manage?}
            id="disposal-act"
            href={~p"/exports/disposal-act.pdf"}
            target="_blank"
            rel="noopener"
            class="btn btn-sm mb-2"
          >
            <.icon name="hero-document-arrow-down" class="size-4" /> {gettext("Disposal act (PDF)")}
          </a>
          <DataList.data_list id="disposal-list" rows={@disposal} empty="">
            <:col :let={c} label={gettext("Year")}>{c.year}</:col>
            <:col :let={c} label={gettext("Index")} class="font-mono">{c.index}</:col>
            <:col :let={c} label={gettext("Title")}>{c.title}</:col>
            <:col :let={c} label={gettext("Retention")}>{c.retention}</:col>
          </DataList.data_list>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
