defmodule AppWeb.DeputiesSection do
  @moduledoc """
  Stand-ins on the Tasks page (docs/design/inbox-first.md §Stand-ins): the
  viewer's deputies — with dates or "whenever I'm away" — and whom the
  viewer stands in for. Events are handled by `AppWeb.TasksLive`.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias AppWeb.{DataList, DateFormat, FormPanels, FormSchemas, JsonSchemaForm}

  attr :overview, :map, required: true
  attr :candidates, :list, required: true
  attr :creating?, :boolean, required: true
  attr :form, :any, required: true
  attr :prefs, :map, default: %{}

  def deputies(assigns) do
    ~H"""
    <section id="deputies">
      <DataList.section_header
        id="deputies-header"
        title={gettext("My deputies")}
        count={length(@overview.mine)}
        prefs={@prefs}
        form="deputy"
        help={
          gettext(
            "A deputy approves and signs for you. With dates: between them. Without dates: whenever you are away on recorded leave or a business trip. A deputy acts only on documents where they hold the needed permission themselves; the route shows who decided."
          )
        }
        actions={
          if @candidates != [],
            do: [%{label: gettext("Add a deputy"), event: "open_deputy"}],
            else: []
        }
      />
      <DataList.data_list
        id="deputies-list"
        rows={@overview.mine}
        empty={gettext("No deputies.")}
      >
        <:col :let={d} label={gettext("Deputy")}>{name(d.deputy)}</:col>
        <:col :let={d} label={gettext("When")}>{period(d)}</:col>
        <:col :let={d} label={gettext("Now")}>
          <span :if={d.active?} class="badge badge-sm badge-success">{gettext("active")}</span>
          <span :if={!d.active?} class="opacity-60">—</span>
        </:col>
        <:action :let={d}>
          <DataList.row_actions
            id={d.id}
            delete="delete_deputy"
            confirm={gettext("Remove this deputy?")}
          />
        </:action>
      </DataList.data_list>

      <FormPanels.form_panel
        :if={@candidates != []}
        id="deputy-new"
        kind={:create}
        form="deputy"
        open={@creating?}
        prefs={@prefs}
        title={gettext("Add a deputy")}
        close="close_deputy"
        form_id="deputy-form"
        submit_label={gettext("Add")}
      >
        <.form for={@form} id="deputy-form" phx-change="validate_deputy" phx-submit="add_deputy">
          <JsonSchemaForm.json_schema_form
            schema={FormSchemas.schema(:deputy)}
            ui_schema={FormSchemas.ui_schema(:deputy)}
            form={@form}
            field_options={%{deputy_id: Enum.map(@candidates, &{name(&1), &1.id})}}
          />
          <p class="mt-1 text-xs opacity-70">{gettext("No dates: whenever you are away.")}</p>
          <button type="submit" class="form-actions btn btn-primary btn-sm mt-2">
            {gettext("Add")}
          </button>
        </.form>
      </FormPanels.form_panel>

      <div :if={@overview.standing_in != []} id="standing-in" class="mt-4">
        <h3 class="mb-1 font-semibold">{gettext("I stand in for")}</h3>
        <ul class="flex flex-col gap-1 text-sm">
          <li :for={d <- @overview.standing_in} class="flex flex-wrap items-center gap-2">
            <.icon name="hero-user" class="size-4 opacity-70" />
            <span>{name(d.user)}</span>
            <span class="opacity-70">· {period(d)}</span>
            <span :if={d.active?} class="badge badge-sm badge-success">{gettext("active")}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp name(nil), do: "—"
  defp name(user), do: user.name || to_string(user.email)

  defp period(%{starts_on: nil}), do: gettext("whenever away")

  defp period(d),
    do: "#{DateFormat.display(d.starts_on)} – #{DateFormat.display(d.ends_on)}"
end
