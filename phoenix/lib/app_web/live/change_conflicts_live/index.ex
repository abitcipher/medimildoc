defmodule AppWeb.ChangeConflictsLive.Index do
  @moduledoc """
  View of `App.Audit.ChangeConflict` ) —
  the "observability" half of "last-write-wins, but log the incident".
  Read-only: nothing here ever resolves or dismisses a conflict, since
  the design doesn't call for a resolution workflow, only a record that a
  collision happened. Needs `audit.read` (the CISO profile; route gate
  in the router, real enforcement in the resource policy) — conflict records can name any user
  involved as the overwriting actor, which is exactly the kind of detail
  that shouldn't be visible to a `:viewer`/`:hr` browsing their own
  ordinary work.

  (UI-kit adoption): the simplest of the four list views
  extended to `Cinder.collection` flagged this as the natural
  next step) — no inline forms/edit state to reconcile with Cinder's
  own row rendering, unlike `Organizations`/`PositionsLive.Index`, so
  this one is close to a pure drop-in replacement of the old
  `mount/3`-time `Ash.read!` + hand-rolled `<table>`.
  """
  use AppWeb, :live_view

  alias App.Audit.{ChangeConflict, Correction}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Change conflicts"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-4xl mx-auto p-4 flex flex-col gap-4">
        <div>
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Change conflicts")}
            <.field_description description={
              gettext(
                "Edits always win last-write-wins — nothing here was blocked or lost data beyond what last-write-wins itself implies. Each row is a detected case where a save was based on a version of a record that someone else had already changed by the time it was written."
              )
            } />
          </h1>
        </div>

        <.top_pager id="conflicts-table">
          <Cinder.collection id="conflicts-table" resource={ChangeConflict} actor={@current_user}>
            <:col :let={c} field="detected_at" sort label={gettext("Detected")}>
              {c.detected_at}
            </:col>
            <:col :let={c} field="resource" filter sort label={gettext("Resource")}>
              {c.resource}
            </:col>
            <:col :let={c} field="record_id" filter label={gettext("Record")}>
              <span class="font-mono text-xs">{c.record_id}</span>
            </:col>
            <:col :let={c} field="actor_email" filter label={gettext("Overwriting actor")}>
              {c.actor_email || "—"}
            </:col>
            <:col :let={c} field="expected_updated_at" label={gettext("Expected updated_at")}>
              {c.expected_updated_at}
            </:col>
            <:col :let={c} field="found_updated_at" label={gettext("Found updated_at")}>
              {c.found_updated_at}
            </:col>
          </Cinder.collection>
        </.top_pager>

        <%!-- Direct changes to assignments, made without a personnel order
        (docs/design/documents-core.md: orders preferred, corrections logged). --%>
        <h2 class="flex items-center gap-2 font-semibold" id="corrections">
          {gettext("Direct changes (without an order)")}
          <.field_description description={
            gettext(
              "Assignments are normally changed by signed personnel orders. Each row is a change made directly instead: who made it, when, and what changed."
            )
          } />
        </h2>
        <.top_pager id="corrections-table">
          <Cinder.collection
            id="corrections-table"
            resource={Correction}
            actor={@current_user}
            query={Ash.Query.sort(Correction, inserted_at: :desc)}
          >
            <:col :let={c} field="inserted_at" sort label={gettext("When")}>
              {AppWeb.DateFormat.display_datetime(c.inserted_at)}
            </:col>
            <:col :let={c} field="actor_email" filter label={gettext("Who")}>{c.actor_email}</:col>
            <:col :let={c} field="action" filter label={gettext("Action")}>
              {correction_action(c.action)}
            </:col>
            <:col :let={c} field="person_id" label={gettext("Person")}>
              <.link :if={c.person_id} navigate={~p"/people/#{c.person_id}"} class="link link-hover">
                {gettext("Open")}
              </.link>
            </:col>
            <:col :let={c} label={gettext("Changes")}>
              <span class="font-mono text-xs">{changes_text(c.changes)}</span>
            </:col>
          </Cinder.collection>
        </.top_pager>
      </div>
    </Layouts.app>
    """
  end

  defp correction_action(:create), do: gettext("Created")
  defp correction_action(:update), do: gettext("Changed")
  defp correction_action(:destroy), do: gettext("Deleted")

  # "starts_on: 2026-09-01 → 2026-09-02"
  defp changes_text(%{"removed" => removed}),
    do:
      gettext("removed: %{what}",
        what: Enum.map_join(removed, ", ", fn {k, v} -> "#{k}: #{v}" end)
      )

  defp changes_text(%{} = changes),
    do:
      Enum.map_join(changes, "; ", fn {key, %{"from" => from, "to" => to}} ->
        "#{key}: #{from || "—"} → #{to || "—"}"
      end)

  defp changes_text(_changes), do: ""
end
