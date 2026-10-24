defmodule AppWeb.ReadinessLive do
  @moduledoc """
  The start page's Readiness widget (docs/design/ui-plan.md item 8),
  embedded in the controller-rendered start page with `live_render/3` so
  its list can search, sort and load more rows as it scrolls
  (`AppWeb.PeopleListComponent`): counts per status, then everyone with a
  fitness-for-duty assessment the viewer may see.

  The viewer comes from the signed LiveView session the start page
  passes (`"user_id"`), so it can't be swapped by the browser; data is read
  with that user as actor, through the normal policies.
  """
  use AppWeb, :live_view

  alias App.Accounts.User
  alias AppWeb.PersonRows

  @impl true
  def mount(_params, %{"user_id" => user_id} = session, socket) do
    if locale = session["locale"], do: Gettext.put_locale(locale)

    user = Ash.get!(User, user_id, authorize?: false)

    rows =
      if App.Access.can?(user, "readiness.read"), do: PersonRows.readiness(user), else: []

    {:ok,
     assign(socket,
       rows: rows,
       counts: Enum.frequencies_by(rows, & &1.status.value)
     ), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100 p-4" aria-labelledby="w-readiness">
      <h3 id="w-readiness" class="mb-3 flex items-center gap-2 font-semibold">
        <.icon name="hero-check-badge" class="size-5" /> {gettext("Readiness")}
        <span class="text-xs font-normal opacity-60">
          {ngettext("%{count} person", "%{count} people", length(@rows))}
        </span>
      </h3>
      <div class="mb-3 grid grid-cols-3 gap-2 text-center">
        <div class="rounded-box bg-success/10 p-2">
          <div class="text-2xl font-semibold text-success">
            {Map.get(@counts, "fit_for_duty", 0)}
          </div>
          <div class="text-xs">{AppWeb.SchemaText.choice("fit_for_duty")}</div>
        </div>
        <div class="rounded-box bg-warning/10 p-2">
          <div class="text-2xl font-semibold text-warning">
            {Map.get(@counts, "downgraded", 0)}
          </div>
          <div class="text-xs">{AppWeb.SchemaText.choice("downgraded")}</div>
        </div>
        <div class="rounded-box bg-error/10 p-2">
          <div class="text-2xl font-semibold text-error">
            {Map.get(@counts, "non_effective", 0)}
          </div>
          <div class="text-xs">{AppWeb.SchemaText.choice("non_effective")}</div>
        </div>
      </div>
      <.live_component
        module={AppWeb.PeopleListComponent}
        id="readiness-people"
        rows={@rows}
        empty={gettext("No assessments yet.")}
      />
    </section>
    """
  end
end
