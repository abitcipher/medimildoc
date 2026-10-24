defmodule AppWeb.ImportExportLive do
  @moduledoc """
  Import / export of current assignments as an offline .xlsx workbook
  (docs/design/assignments-sheets.md): download the workbook, edit it in
  Excel or LibreOffice (Position from the dropdown, Since as dd.mm.yyyy),
  upload it, check the preview, apply. Works without Google.
  """
  use AppWeb, :live_view

  alias App.People.AssignmentSync
  alias AppWeb.AssignmentPlan

  @max_bytes 10 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Import / export"))
     |> assign(plan: nil, result: nil, error: nil)
     |> allow_upload(:workbook, accept: ~w(.xlsx), max_entries: 1, max_file_size: @max_bytes)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    actor = socket.assigns.current_user

    outcome =
      consume_uploaded_entries(socket, :workbook, fn %{path: path}, _entry ->
        {:ok, App.Xlsx.read_assignments(path)}
      end)

    case outcome do
      [{:ok, rows}] ->
        {:noreply,
         assign(socket, plan: AssignmentSync.plan(actor, rows), result: nil, error: nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, plan: nil, error: read_error(reason))}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_import", _params, %{assigns: %{plan: plan}} = socket)
      when plan != nil do
    result = AssignmentSync.apply(socket.assigns.current_user, plan)
    {:noreply, assign(socket, plan: nil, result: result)}
  end

  def handle_event("cancel_import", _params, socket),
    do: {:noreply, assign(socket, plan: nil, error: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        <span class="flex items-center gap-2">
          {gettext("Import / export")}
          <.field_description description={
            gettext(
              "Current assignments as a spreadsheet: edit offline in Excel or LibreOffice, then upload."
            )
          } />
        </span>
      </.header>

      <section class="rounded-box border border-base-300 p-4" aria-labelledby="export-heading">
        <h2 id="export-heading" class="mb-2 font-semibold">{gettext("1. Download")}</h2>
        <p class="mb-3 text-sm opacity-80">
          {gettext(
            "One row per person. Choose Position from the dropdown (sheet Positions); put the date it starts in Since (dd.mm.yyyy). Clear Position to end an assignment. History is read-only."
          )}
        </p>
        <a href={~p"/exports/assignments.xlsx"} class="btn btn-sm btn-outline" download>
          <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download workbook (.xlsx)")}
        </a>
      </section>

      <section class="rounded-box border border-base-300 p-4" aria-labelledby="import-heading">
        <h2 id="import-heading" class="mb-2 font-semibold">{gettext("2. Upload and check")}</h2>
        <form
          id="workbook-form"
          phx-change="validate"
          phx-submit="preview"
          class="flex flex-wrap items-center gap-3"
        >
          <.live_file_input upload={@uploads.workbook} class="file-input file-input-sm" />
          <button
            type="submit"
            class="btn btn-sm btn-primary"
            disabled={@uploads.workbook.entries == []}
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> {gettext("Check changes")}
          </button>
        </form>
        <p :for={err <- upload_errors(@uploads.workbook)} class="mt-2 text-sm text-error">
          {upload_error(err)}
        </p>
        <p :if={@error} class="mt-2 text-sm text-error" role="alert">{@error}</p>
      </section>

      <AssignmentPlan.preview :if={@plan} plan={@plan} />
      <AssignmentPlan.report :if={@result} result={@result} />
    </Layouts.app>
    """
  end

  defp read_error(:no_assignments_sheet),
    do:
      gettext("The workbook has no sheet named Assignments. Start from the downloaded workbook.")

  defp read_error(_unreadable), do: gettext("This is not a readable .xlsx file.")

  defp upload_error(:too_large), do: gettext("The file is too large (max 10 MB).")
  defp upload_error(:not_accepted), do: gettext("Choose an .xlsx file.")
  defp upload_error(_), do: gettext("The file could not be uploaded.")
end
