defmodule AppWeb.AssignmentPlan do
  @moduledoc """
  The preview of an assignments import (`App.People.AssignmentSync.plan/2`)
  and its result — shared by the offline Import / export page and the
  Google Sheets sidebar (docs/design/assignments-sheets.md). Nothing is
  written until the user confirms (`confirm` event); then appointments,
  transfers and releases become draft orders and corrected start dates are
  applied.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias App.People.{Person, PositionLabel}

  attr :plan, :map, required: true
  attr :target, :any, default: nil, doc: "phx-target for the confirm/cancel events"
  attr :compact, :boolean, default: false, doc: "narrow layout (sidebar)"
  attr :id, :string, default: "import-preview"

  def preview(assigns) do
    ~H"""
    <section id={@id} class="flex flex-col gap-3" aria-labelledby={"#{@id}-heading"}>
      <h3 id={"#{@id}-heading"} class="flex items-center gap-2 font-semibold">
        {gettext("Changes")}
        <span
          class="cursor-help"
          data-float-tip={
            gettext(
              "Appointments, transfers and releases become draft orders in your Tasks: complete them and send them for approval; posts change when the orders are signed. Corrected start dates are applied directly."
            )
          }
        >
          <.icon name="hero-information-circle" class="size-4 opacity-60" />
        </span>
      </h3>
      <p class="text-sm">
        {ngettext("%{count} change", "%{count} changes", length(@plan.changes))} · {ngettext(
          "%{count} row with errors",
          "%{count} rows with errors",
          length(@plan.errors)
        )} · {ngettext("%{count} row unchanged", "%{count} rows unchanged", @plan.unchanged)}
      </p>

      <p
        :if={Map.get(@plan, :stale, []) != []}
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
        <li
          :for={change <- @plan.changes}
          class={[
            "flex flex-wrap items-center gap-x-2 gap-y-1 px-3 py-2",
            @compact && "flex-col items-start"
          ]}
        >
          <span class="badge badge-sm badge-ghost font-mono">{gettext("row %{n}", n: change.row)}</span>
          <span class={["badge badge-sm", kind_tone(change.kind)]}>{kind_label(change.kind)}</span>
          <span class="font-medium">{Person.full_name(change.person)}</span>
          <span class="opacity-80">{describe(change)}</span>
          <span :for={note <- change.notes} class="badge badge-sm badge-warning badge-outline">{note_text(
            note
          )}</span>
          <span
            :if={change.conflict?}
            class="badge badge-sm badge-error badge-outline gap-1"
            data-float-tip={
              gettext(
                "Changed by someone else after the export: check this change. A corrected start date overwrites it and the conflict is logged."
              )
            }
          >
            <.icon name="hero-exclamation-triangle" class="size-3.5" /> {gettext("conflict")}
          </span>
        </li>
      </ul>

      <div :if={@plan.errors != []} class="rounded-box border border-error/40 bg-error/5 p-3 text-sm">
        <p class="mb-1 font-medium text-error">{gettext("Skipped rows")}</p>
        <ul class="flex flex-col gap-0.5">
          <li :for={{row, message} <- @plan.errors}>
            <span class="font-mono">{gettext("row %{n}", n: row)}</span>: {error_text(message)}
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

  @doc """
  The draft orders `AssignmentSync.apply/2` created, for `report/1`:
  `[%{id, kind, name}]` in the plan's order.
  """
  @spec drafts(map(), map()) :: [map()]
  def drafts(plan, result) do
    for change <- plan.changes,
        {:drafted, kind, id} <- [Map.get(result.outcomes, change.row)],
        do: %{id: id, kind: kind, name: Person.full_name(change.person)}
  end

  attr :result, :map, required: true

  attr :drafts, :list,
    default: [],
    doc: "`drafts/2`: listed with links; with `target`, \"Cancel these drafts\" too"

  attr :target, :any, default: nil

  def report(assigns) do
    ~H"""
    <div id="import-report" class="rounded-box border border-base-300 p-3 text-sm" role="status">
      <p :if={@result.drafted > 0} class="font-medium">
        {ngettext(
          "%{count} draft order created",
          "%{count} draft orders created",
          @result.drafted
        )} ·
        <a href="/tasks" class="link" target={@target && "_blank"}>{gettext("open them in Tasks")}</a>
      </p>
      <ul :if={@drafts != []} id="import-drafts" class="my-1 flex flex-col gap-0.5">
        <li :for={draft <- @drafts} class="flex items-center gap-1">
          <.icon name="hero-document-text" class="size-3.5 shrink-0 opacity-60" />
          <a href={"/documents/#{draft.id}"} target={@target && "_blank"} class="link truncate">
            {kind_label(draft.kind)} · {draft.name}
          </a>
        </li>
      </ul>
      <button
        :if={@drafts != [] and @target != nil}
        type="button"
        id="cancel-drafts"
        phx-click="cancel_drafts"
        phx-target={@target}
        data-confirm={gettext("Cancel the draft orders this import created?")}
        class="btn btn-ghost btn-xs text-error"
      >
        <.icon name="hero-x-mark" class="size-4" /> {gettext("Cancel these drafts")}
      </button>
      <p :if={@result.drafted > 0} class="opacity-80">
        {gettext(
          "Posts change when the orders are signed; until then the list shows the current posts."
        )}
      </p>
      <p :if={@result.corrected > 0}>
        {ngettext(
          "%{count} start date corrected",
          "%{count} start dates corrected",
          @result.corrected
        )}
      </p>
      <p :if={@result.drafted == 0 and @result.corrected == 0} class="font-medium">
        {gettext("Nothing was changed.")}
      </p>
      <ul :if={@result.skipped != []} class="mt-1 text-warning">
        <li :for={{row, _reason} <- @result.skipped}>
          <span class="font-mono">{gettext("row %{n}", n: row)}</span>: {gettext(
            "skipped — a personnel order for this person is already open"
          )}
        </li>
      </ul>
      <p :if={@result.conflicts > 0} class="text-warning">
        {ngettext(
          "%{count} of them overwrote a newer change (logged under Change conflicts)",
          "%{count} of them overwrote newer changes (logged under Change conflicts)",
          @result.conflicts
        )}
      </p>
      <ul :if={@result.failed != []} class="mt-1 text-error">
        <li :for={{row, message} <- @result.failed}>
          <span class="font-mono">{gettext("row %{n}", n: row)}</span>: {message}
        </li>
      </ul>
    </div>
    """
  end

  defp describe(%{kind: :move} = c),
    do:
      "#{post(c.current.position)} → #{post(c.to)} · #{gettext("from %{date}", date: date(c.on))}"

  defp describe(%{kind: :start} = c),
    do: "#{post(c.to)} · #{gettext("from %{date}", date: date(c.on))}"

  defp describe(%{kind: :end} = c),
    do: "#{post(c.current.position)} · #{gettext("ends %{date}", date: date(c.on))}"

  defp describe(%{kind: :redate} = c), do: gettext("started %{date}", date: date(c.on))

  defp post(%{title: _} = position), do: PositionLabel.for_position(position)
  defp post(_not_loaded), do: ""

  defp date(date), do: AppWeb.DateFormat.display(date)

  @doc "A change's kind in words."
  @spec kind_label(atom()) :: String.t()
  def kind_label(:move), do: gettext("Transfer order")
  def kind_label(:start), do: gettext("Appointment order")
  def kind_label(:end), do: gettext("Release order")
  def kind_label(:redate), do: gettext("Start date correction")

  defp kind_tone(:move), do: "badge-info"
  defp kind_tone(:start), do: "badge-success"
  defp kind_tone(:end), do: "badge-warning"
  defp kind_tone(:redate), do: "badge-ghost"

  @doc "A plan error (`App.People.AssignmentSync.error()`) in words."
  @spec error_text(term()) :: String.t()
  def error_text(:empty), do: gettext("the sheet is empty")

  def error_text({:missing_columns, names}),
    do: gettext("missing columns: %{names}", names: Enum.join(names, ", "))

  def error_text(:unknown_person), do: gettext("unknown PersonID")
  def error_text(:duplicate_person), do: gettext("this person is on an earlier row too")

  def error_text({:unknown_position, label}),
    do: gettext("unknown position \"%{label}\" (use the dropdown)", label: label)

  def error_text(:not_a_date), do: gettext("\"Since\" must be a date like 27.09.2026")
  def error_text(:not_a_real_date), do: gettext("\"Since\" is not a real date")

  def error_text(:since_not_after_start),
    do: gettext("\"Since\" must be after the current assignment's start")

  def error_text(:starts_in_future),
    do: gettext("the current assignment starts in the future; end it on the person page")

  def error_text({:overlaps_previous, ended_on}),
    do:
      gettext(
        "\"Since\" must be after the previous assignment ended (%{date}); export the sheet again if it is older than the last change",
        date: AppWeb.DateFormat.display(Date.to_iso8601(ended_on))
      )

  def error_text(message) when is_binary(message), do: message

  defp note_text("starts today"), do: gettext("starts today")
  defp note_text("post over strength"), do: gettext("post over strength")
  defp note_text(other), do: other
end
