defmodule AppWeb.SheetPlan do
  @moduledoc """
  The preview and result of importing a people or records tab
  (`App.People.SheetSync`, SHEETS-UI stage 2, docs/design/sheets-ui.md) —
  the counterpart of `AppWeb.AssignmentPlan` for every other dataset.
  Nothing is written until the user confirms (`confirm_import`).
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias App.People.Person
  alias AppWeb.SheetLayout

  attr :plan, :map, required: true
  attr :target, :any, default: nil
  attr :id, :string, default: "sheet-preview"

  def preview(assigns) do
    assigns = assign(assigns, labels: labels(assigns.plan.dataset))

    ~H"""
    <section id={@id} class="flex flex-col gap-3" aria-labelledby={"#{@id}-heading"}>
      <h3 id={"#{@id}-heading"} class="font-semibold">{gettext("Changes")}</h3>
      <p class="text-sm">
        {ngettext("%{count} change", "%{count} changes", length(@plan.changes))} · {ngettext(
          "%{count} row with errors",
          "%{count} rows with errors",
          length(@plan.errors)
        )} · {ngettext("%{count} row unchanged", "%{count} rows unchanged", @plan.unchanged)}
      </p>

      <p
        :if={@plan.stale != []}
        id={"#{@id}-stale"}
        class="rounded-box border border-warning/40 bg-warning/5 p-3 text-sm"
      >
        {ngettext(
          "%{count} row was changed in the app after the export and is left out (rows %{rows}); export again to edit it.",
          "%{count} rows were changed in the app after the export and are left out (rows %{rows}); export again to edit them.",
          length(@plan.stale),
          rows: Enum.join(@plan.stale, ", ")
        )}
      </p>

      <ul
        :if={@plan.changes != []}
        class="flex flex-col divide-y divide-base-200 rounded-box border border-base-300 text-sm"
      >
        <li :for={change <- @plan.changes} class="flex flex-col items-start gap-1 px-3 py-2">
          <div class="flex flex-wrap items-center gap-1">
            <span class="badge badge-sm badge-ghost font-mono">{gettext("row %{n}", n: change.row)}</span>
            <span class={[
              "badge badge-sm",
              change.kind == :create && "badge-success",
              change.kind == :update && "badge-info"
            ]}>
              {kind_label(change.kind)}
            </span>
            <span :if={change.person} class="font-medium">{Person.full_name(change.person)}</span>
            <span :if={!change.person && change.attrs[:family_name]} class="font-medium">
              {Enum.join(
                Enum.filter([change.attrs[:given_name], change.attrs[:family_name]], & &1),
                " "
              )}
            </span>
            <span :if={change[:new_id]} class="badge badge-sm badge-ghost font-mono">
              {change.new_id}
            </span>
            <span
              :if={change.conflict?}
              class="badge badge-sm badge-error badge-outline gap-1"
              data-float-tip={
                gettext(
                  "Changed by someone else after the export: check this change. Saving it overwrites theirs and the conflict is logged."
                )
              }
            >
              <.icon name="hero-exclamation-triangle" class="size-3.5" /> {gettext("conflict")}
            </span>
          </div>
          <span class="text-xs opacity-80">{Enum.map_join(change.changed, ", ", &(@labels[&1] || &1))}</span>
        </li>
      </ul>

      <div :if={@plan.errors != []} class="rounded-box border border-error/40 bg-error/5 p-3 text-sm">
        <p class="mb-1 font-medium text-error">{gettext("Skipped rows")}</p>
        <ul class="flex flex-col gap-0.5">
          <li :for={{row, error} <- @plan.errors}>
            <span class="font-mono">{gettext("row %{n}", n: row)}</span>: {error_text(error)}
          </li>
        </ul>
      </div>

      <div class="flex gap-2">
        <button
          :if={@plan.changes != []}
          type="button"
          phx-click="confirm_import"
          phx-target={@target}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-check" class="size-4" />
          {ngettext("Carry out %{count} change", "Carry out %{count} changes", length(@plan.changes))}
        </button>
        <button
          type="button"
          phx-click="cancel_import"
          phx-target={@target}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Cancel")}
        </button>
      </div>
    </section>
    """
  end

  attr :result, :map, required: true

  def report(assigns) do
    ~H"""
    <div id="sheet-report" class="rounded-box border border-base-300 p-3 text-sm" role="status">
      <p :if={@result.created > 0} class="font-medium">
        {ngettext("%{count} row added to the app", "%{count} rows added to the app", @result.created)}
      </p>
      <p :if={@result.updated > 0} class="font-medium">
        {ngettext("%{count} row saved", "%{count} rows saved", @result.updated)}
      </p>
      <p :if={@result.created == 0 and @result.updated == 0} class="font-medium">
        {gettext("Nothing was changed.")}
      </p>
      <ul :if={@result.failed != []} class="mt-1 text-error">
        <li :for={{row, message} <- @result.failed}>
          <span class="font-mono">{gettext("row %{n}", n: row)}</span>: {message}
        </li>
      </ul>
    </div>
    """
  end

  @doc "A change's kind in words."
  @spec kind_label(:create | :update) :: String.t()
  def kind_label(:create), do: gettext("New")
  def kind_label(:update), do: gettext("Update")

  @doc "The dataset's column labels by key."
  @spec labels(String.t()) :: %{String.t() => String.t()}
  def labels(dataset), do: Map.new(SheetLayout.columns(dataset), &{&1.key, &1.label})

  @doc "A plan error (`App.People.SheetSync.error()`) in words."
  @spec error_text(term()) :: String.t()
  def error_text(:unknown_person), do: gettext("unknown PersonID")
  def error_text(:unknown_record), do: gettext("unknown record (RecordID changed?)")
  def error_text(:duplicate_row), do: gettext("the same record is on an earlier row too")
  def error_text(:no_person), do: gettext("a new row needs the person's PersonID")

  def error_text({:missing_columns, names}),
    do: gettext("missing columns: %{names}", names: Enum.join(names, ", "))

  def error_text({:invalid, message}), do: message
  def error_text(other), do: inspect(other)
end
