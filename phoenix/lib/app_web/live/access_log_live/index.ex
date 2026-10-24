defmodule AppWeb.AccessLogLive.Index do
  @moduledoc """
  Who read which sensitive record, and when
  (docs/design/access-control-phase1.md). Read-only; needs `audit.read`
  (the CISO profile), enforced by `App.Audit.AccessLog`'s policy, with the
  route gate as UX only. Newest first.
  """
  use AppWeb, :live_view

  alias App.Audit.{AccessLog, EmergencyAccess}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Access log"))
     |> assign(:query, Ash.Query.sort(AccessLog, accessed_at: :desc))
     |> load_emergencies()}
  end

  # Break the Glass review (docs/design/access-control-phase2.md).
  @impl true
  def handle_event("review_emergency", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    EmergencyAccess
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(:review, %{}, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, _} ->
        {:noreply,
         socket |> load_emergencies() |> put_flash(:info, gettext("Marked as reviewed."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  defp load_emergencies(socket) do
    emergencies =
      EmergencyAccess
      |> Ash.Query.sort(granted_at: :desc)
      |> Ash.Query.limit(50)
      |> Ash.read!(actor: socket.assigns.current_user)

    socket
    |> assign(:emergencies, emergencies)
    |> assign(:unreviewed, Enum.count(emergencies, &is_nil(&1.reviewed_at)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-5xl mx-auto p-4 flex flex-col gap-4">
        <div>
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Access log")}
            <.field_description description={
              gettext(
                "One row for every clinical, vetting, pay or family record, national ID or document number a signed-in user was shown. Rows are written before the value is shown; if one can't be written, the value isn't shown."
              )
            } />
          </h1>
        </div>

        <section :if={@emergencies != []} class="flex flex-col gap-2">
          <h2 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-bolt" class="size-5 text-error" />
            {gettext("Emergency accesses")}
            <span :if={@unreviewed > 0} class="badge badge-error badge-sm">
              {ngettext("%{count} to review", "%{count} to review", @unreviewed)}
            </span>
          </h2>
          <ul class="flex flex-col gap-2">
            <li
              :for={grant <- @emergencies}
              id={"emergency-#{grant.id}"}
              class={[
                "flex flex-wrap items-start gap-3 rounded-box border p-3 text-sm",
                if(grant.reviewed_at, do: "border-base-300", else: "border-error/50 bg-error/5")
              ]}
            >
              <div class="min-w-0 grow">
                <p>
                  <span class="font-medium">{grant.actor_email}</span>
                  <span class="opacity-70">→</span>
                  <.link navigate={~p"/people/#{grant.person_id}"} class="link font-mono text-xs">
                    {grant.person_id}
                  </.link>
                </p>
                <p class="italic">“{grant.reason}”</p>
                <p class="text-xs opacity-70">
                  {gettext("Granted %{at} · until %{until}",
                    at: Calendar.strftime(grant.granted_at, "%Y-%m-%d %H:%M"),
                    until: Calendar.strftime(grant.expires_at, "%H:%M")
                  )}
                  <span
                    :if={DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt}
                    class="badge badge-warning badge-xs ml-1"
                  >
                    {gettext("active")}
                  </span>
                </p>
              </div>
              <button
                :if={is_nil(grant.reviewed_at)}
                type="button"
                phx-click="review_emergency"
                phx-value-id={grant.id}
                class="btn btn-sm"
              >
                <.icon name="hero-check" class="size-4" />
                {gettext("Mark reviewed")}
              </button>
              <span :if={grant.reviewed_at} class="text-xs opacity-70">
                <.icon name="hero-check-circle" class="size-4 text-success" />
                {gettext("Reviewed by %{email}", email: grant.reviewed_by_email)}
              </span>
            </li>
          </ul>
        </section>

        <.top_pager id="access-log-table">
          <Cinder.collection id="access-log-table" query={@query} actor={@current_user}>
            <:col :let={entry} field="accessed_at" sort label={gettext("When")}>
              {entry.accessed_at}
            </:col>
            <:col :let={entry} field="actor_email" filter sort label={gettext("User")}>
              {entry.actor_email}
            </:col>
            <:col :let={entry} field="kind" filter sort label={gettext("What")}>
              {entry.kind}
            </:col>
            <:col :let={entry} field="person_id" label={gettext("Person")}>
              <.link
                :if={entry.person_id}
                navigate={~p"/people/#{entry.person_id}"}
                class="link font-mono text-xs"
              >
                {entry.person_id}
              </.link>
            </:col>
            <:col :let={entry} field="reason" label={gettext("Reason")}>
              {entry.reason || "—"}
            </:col>
          </Cinder.collection>
        </.top_pager>
      </div>
    </Layouts.app>
    """
  end
end
