defmodule AppWeb.DataList do
  @moduledoc """
  Sections of a page that list entries and let the viewer add and change
  them (docs/design/ui-preferences.md): a header with the title, the
  count and the add control (`AppWeb.FormPanels.create_actions/1`, where
  the interface settings put it); the entries as a table on wide screens
  and as cards on narrow ones (one DOM each, switched at `md`); compact
  icon buttons for editing and removing an entry.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias AppWeb.FormPanels

  @doc """
  A section header: `title`, `count` and the add control for `form`
  (`actions` as in `FormPanels.create_actions/1`; empty when the viewer
  may not add).
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :prefs, :map, default: %{}
  attr :form, :string, default: nil
  attr :actions, :list, default: []
  attr :help, :string, default: nil, doc: "explanation in an ⓘ next to the title"

  def section_header(assigns) do
    ~H"""
    <div class="mb-2 flex min-h-8 flex-wrap items-center justify-between gap-2">
      <h2 class="flex items-center gap-2 font-semibold">
        {@title}
        <span :if={@count} class="badge badge-sm badge-ghost">{@count}</span>
        <AppWeb.CoreComponents.field_description :if={@help} description={@help} />
      </h2>
      <FormPanels.create_actions
        :if={@actions != []}
        id={"#{@id}-actions"}
        prefs={@prefs}
        form={@form}
        actions={@actions}
      />
    </div>
    """
  end

  @doc """
  Entries as a table (wide screens) or cards (narrow screens). Each `col`
  is a labelled value; `action` holds the entry's buttons. `current` marks
  the entry being edited.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :empty, :string, required: true
  attr :current, :any, default: nil, doc: "id of the entry being edited"

  slot :col, required: true do
    attr :label, :string, required: true
    attr :class, :string
  end

  slot :action

  def data_list(assigns) do
    ~H"""
    <p :if={@rows == []} id={"#{@id}-empty"} class="text-sm opacity-70">{@empty}</p>
    <div :if={@rows != []} id={@id}>
      <div class="hidden overflow-x-auto rounded-box border border-base-300 md:block">
        <table class="table table-sm">
          <thead>
            <tr>
              <th :for={col <- @col}>{col.label}</th>
              <th :if={@action != []} class="w-px">
                <span class="sr-only">{gettext("Actions")}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class={row.id == @current && "bg-base-200"}>
              <td :for={col <- @col} class={col[:class]}>{render_slot(col, row)}</td>
              <td :if={@action != []} class="whitespace-nowrap text-right">
                {render_slot(@action, row)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <ul class="flex flex-col gap-2 md:hidden">
        <li
          :for={row <- @rows}
          class={[
            "rounded-box border border-base-300 p-3",
            row.id == @current && "bg-base-200"
          ]}
        >
          <div class="flex items-start gap-2">
            <dl class="grid min-w-0 grow grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
              <%= for col <- @col do %>
                <dt class="opacity-70">{col.label}</dt>
                <dd class={["min-w-0 break-words", col[:class]]}>{render_slot(col, row)}</dd>
              <% end %>
            </dl>
            <div :if={@action != []} class="flex shrink-0 gap-1">{render_slot(@action, row)}</div>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc "Compact edit and remove buttons for one entry (icons; names on hover and for screen readers)."
  attr :id, :any, required: true
  attr :edit, :string, default: nil, doc: "event that opens the entry for editing"
  attr :delete, :string, default: nil, doc: "event that removes the entry"
  attr :confirm, :string, default: nil
  attr :edit_label, :string, default: nil
  attr :delete_label, :string, default: nil

  def row_actions(assigns) do
    assigns =
      assign(assigns,
        edit_label: assigns.edit_label || gettext("Edit"),
        delete_label: assigns.delete_label || gettext("Delete")
      )

    ~H"""
    <span class="inline-flex gap-1">
      <button
        :if={@edit}
        type="button"
        phx-click={@edit}
        phx-value-id={@id}
        class="btn btn-ghost btn-xs btn-square"
        aria-label={@edit_label}
        title={@edit_label}
      >
        <.icon name="hero-pencil-square" class="size-4" />
      </button>
      <button
        :if={@delete}
        type="button"
        phx-click={@delete}
        phx-value-id={@id}
        data-confirm={@confirm}
        class="btn btn-ghost btn-xs btn-square text-error"
        aria-label={@delete_label}
        title={@delete_label}
      >
        <.icon name="hero-trash" class="size-4" />
      </button>
    </span>
    """
  end
end
