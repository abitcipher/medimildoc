defmodule AppWeb.IncidentsLive do
  @moduledoc """
  Data consistency incidents (docs/design/data-consistency.md; `audit.read`):
  newest first, open ones on top; each can be reviewed as explained (an
  error, corrected) or confirmed (a real problem), with a note.
  """
  use AppWeb, :live_view

  alias App.Audit.Incident

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Incidents"), reviewing: nil) |> load()}
  end

  defp load(socket) do
    incidents =
      Incident
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(200)
      |> Ash.read!(actor: socket.assigns.current_user)
      |> Enum.sort_by(&(&1.status != :open))

    assign(socket, incidents: incidents)
  end

  @impl true
  def handle_event("review", %{"id" => id}, socket), do: {:noreply, assign(socket, reviewing: id)}

  def handle_event(
        "save_review",
        %{"incident_id" => id, "status" => status, "note" => note},
        socket
      ) do
    actor = socket.assigns.current_user
    incident = Enum.find(socket.assigns.incidents, &(&1.id == id))

    incident
    |> Ash.Changeset.for_update(
      :review,
      %{status: String.to_existing_atom(status), review_note: note},
      actor: actor
    )
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} -> {:noreply, socket |> assign(reviewing: nil) |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("cancel_review", _params, socket),
    do: {:noreply, assign(socket, reviewing: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("Incidents")}
          <.field_description description={
            gettext(
              "Each incident is data that broke a consistency rule — a mistake or possible falsification. Review it: explained (an error, corrected) or confirmed."
            )
          } />
        </h1>
        <p :if={@incidents == []} class="text-sm opacity-60">{gettext("No incidents.")}</p>
        <ul :if={@incidents != []} class="divide-y divide-base-200 rounded-box border border-base-300">
          <li :for={i <- @incidents} id={"incident-#{i.id}"} class="flex flex-col gap-1 p-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class={["badge badge-sm", status_tone(i.status)]}>{status_label(i.status)}</span>
              <span class={["badge badge-sm badge-outline", i.severity == :block && "badge-error"]}>
                {AppWeb.RulesLive.Index.severity_label(i.severity)} · {outcome_label(i.outcome)}
              </span>
              <span class="font-medium">{Gettext.gettext(AppWeb.Gettext, i.message || i.code || "")}</span>
            </div>
            <p class="text-xs opacity-70">
              {AppWeb.DateFormat.display_datetime(i.inserted_at)} · {i.rule_key} v{i.rule_version} · {i.point} · {i.subject} · {i.actor_email ||
                gettext("system")}
              <.link :if={i.person_id} navigate={~p"/people/#{i.person_id}"} class="link link-hover">
                · {gettext("person")}
              </.link>
              <.link
                :if={i.subject_id && String.starts_with?(i.subject, "document:")}
                navigate={"/documents/#{i.subject_id}"}
                class="link link-hover"
              >
                · {gettext("document")}
              </.link>
            </p>
            <p :if={i.review_note} class="text-xs italic opacity-80">
              {i.reviewed_by_email}: «{i.review_note}»
            </p>
            <button
              :if={i.status == :open and @reviewing != i.id}
              type="button"
              phx-click="review"
              phx-value-id={i.id}
              class="btn btn-xs self-start"
            >
              {gettext("Review")}
            </button>
            <form
              :if={@reviewing == i.id}
              id={"review-#{i.id}"}
              phx-submit="save_review"
              class="mt-1 flex flex-col gap-2"
            >
              <input type="hidden" name="incident_id" value={i.id} />
              <select name="status" class="select select-sm w-auto">
                <option value="explained">{status_label(:explained)}</option>
                <option value="confirmed">{status_label(:confirmed)}</option>
              </select>
              <textarea name="note" rows="2" class="textarea textarea-sm" required></textarea>
              <div class="flex gap-2">
                <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
                <button type="button" phx-click="cancel_review" class="btn btn-sm btn-ghost">
                  {gettext("Cancel")}
                </button>
              </div>
            </form>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp status_label(:open), do: gettext("Open")
  defp status_label(:explained), do: gettext("Explained")
  defp status_label(:confirmed), do: gettext("Confirmed")

  defp status_tone(:open), do: "badge-warning"
  defp status_tone(:explained), do: "badge-ghost"
  defp status_tone(:confirmed), do: "badge-error"

  defp outcome_label(:refused), do: gettext("refused")
  defp outcome_label(:saved), do: gettext("saved")
  defp outcome_label(:found), do: gettext("found in existing data")
end
