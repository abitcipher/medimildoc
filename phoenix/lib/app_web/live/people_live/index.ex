defmodule AppWeb.PeopleLive.Index do
  @moduledoc """
  Lists people (M3 forms-UI follow-up). Requires a signed-in
  user (router's `:authenticated_routes` live_session, `AppWeb.LiveUserAuth`)
  — any role can view; "New person" is hidden for `:viewer` 
  , `AppWeb.Authz.can?(user, "people.write")` — UI-only, the real gate is `/people/new`'s
  own route-level `:require_editor` on_mount plus `Person`'s Ash policy).

  (UI-kit adoption) replaced the hand-rolled `<table>` +
  in-memory search box () with `Cinder.collection` — real
  Ash-level filtering/sorting/pagination instead of loading the whole
  roster into memory and filtering client-side, which is what this page
  did before. Whole-row click navigates to the person, matching the
  `phx.gen.live` scaffold convention (Phoenix's own generated index
  pages do the same) rather than a separate link cell.

  The `person_id` column uses the custom `:person_id` filter type
  (`AppWeb.Cinder.Filters.PersonId`) instead of
  Cinder's default `:text` — fixes a rough edge / originally
  shipped with: the column displays `person_id` grouped `AAAA-BBBB-CCCC`
  (`PersonId.format/1`), but a plain `:text` filter matches the *raw*
  stored code, so pasting the value back in exactly as displayed (with
  dashes) silently matched nothing. The custom filter just runs the
  input through `PersonId.unformat/1` before Cinder's own text-filter
  logic — same widget, same operators, one extra normalization step.
  """
  use AppWeb, :live_view

  alias App.People.{Person, PersonId}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("People"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-4xl mx-auto p-4 flex flex-col gap-4">
        <div class="flex items-center justify-between">
          <h1 class="text-xl font-semibold">{gettext("People")}</h1>
          <.link
            :if={AppWeb.Authz.can?(@current_user, "people.write")}
            navigate={~p"/people/new"}
            class="btn btn-primary"
          >
            {gettext("New person")}
          </.link>
        </div>

        <.top_pager id="people-table">
          <Cinder.collection
            id="people-table"
            resource={Person}
            actor={@current_user}
            click={&JS.navigate(~p"/people/#{&1.id}")}
          >
            <:col :let={person} field="given_name" filter sort label={gettext("Name")}>
              {Person.full_name(person)}
              <.synthetic_badge :if={person.synthetic} />
            </:col>
            <:col :let={person} field="email" filter label={gettext("Email")}>
              {person.email}
            </:col>
            <:col :let={person} field="person_id" filter={:person_id} sort label={gettext("PersonID")}>
              <span class="font-mono text-xs">{PersonId.format(person.person_id)}</span>
            </:col>
          </Cinder.collection>
        </.top_pager>
      </div>
    </Layouts.app>
    """
  end
end
