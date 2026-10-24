defmodule AppWeb.SearchLive do
  @moduledoc """
  Global search results (docs/design/search-timeline-notifications.md):
  `App.Search.run/2` as the viewer, grouped; results update while typing
  (the text is kept in the URL, `?q=`).
  """
  use AppWeb, :live_view

  alias App.People.{Person, PersonId, PositionLabel}
  alias AppWeb.DocumentUI

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Search"), q: "", results: nil)}

  @impl true
  def handle_params(params, _uri, socket) do
    q = String.trim(params["q"] || "")
    results = if q == "", do: nil, else: App.Search.run(socket.assigns.current_user, q)
    {:noreply, assign(socket, q: q, results: results)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/search?#{[q: q]}", replace: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-5 p-4">
        <form id="search-form" phx-change="search" phx-submit="search" role="search">
          <label class="input w-full">
            <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
            <input
              type="search"
              name="q"
              value={@q}
              phx-debounce="300"
              autofocus
              autocomplete="off"
              class="grow"
              placeholder={gettext("Name, Person ID, document number…")}
              aria-label={gettext("Search")}
            />
            <.field_description description={
              gettext(
                "People by name, Person ID or e-mail; documents by number; units, posts and care providers by name. A national ID or document number finds its person by exact match, and each such search is recorded in the access log."
              )
            } />
          </label>
        </form>

        <p :if={@results && !App.Search.any?(@results)} class="text-sm opacity-70">
          {gettext("Nothing found.")}
        </p>

        <.group
          :if={@results}
          id="found-identified"
          title={gettext("By national ID or document number")}
          items={@results.identified}
        >
          <:item :let={person}><.person_row person={person} /></:item>
        </.group>
        <.group :if={@results} id="found-people" title={gettext("People")} items={@results.people}>
          <:item :let={person}><.person_row person={person} /></:item>
        </.group>
        <.group
          :if={@results}
          id="found-documents"
          title={gettext("Documents")}
          items={@results.documents}
        >
          <:item :let={document}><DocumentUI.row document={document} /></:item>
        </.group>
        <.group
          :if={@results}
          id="found-units"
          title={gettext("Organizations")}
          items={@results.organizations}
        >
          <:item :let={org}>
            <.plain_row navigate={~p"/organizations"} icon="hero-building-office" text={org.name} />
          </:item>
        </.group>
        <.group
          :if={@results}
          id="found-posts"
          title={gettext("Positions")}
          items={@results.positions}
        >
          <:item :let={position}>
            <.plain_row
              navigate={~p"/positions"}
              icon="hero-briefcase"
              text={PositionLabel.for_position(position)}
            />
          </:item>
        </.group>
        <.group
          :if={@results}
          id="found-providers"
          title={gettext("Care providers")}
          items={@results.providers}
        >
          <:item :let={provider}>
            <.plain_row
              navigate={~p"/care-providers"}
              icon="hero-building-library"
              text={provider.name}
            />
          </:item>
        </.group>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :items, :list, required: true
  slot :item, required: true

  defp group(assigns) do
    ~H"""
    <section :if={@items != []} id={@id} class="flex flex-col gap-1" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="text-sm font-semibold opacity-80">{@title}</h2>
      <ul class="divide-y divide-base-200 rounded-box border border-base-300">
        <li :for={item <- @items}>{render_slot(@item, item)}</li>
      </ul>
    </section>
    """
  end

  attr :person, :map, required: true

  defp person_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/people/#{@person.id}"}
      class="flex min-w-0 items-center gap-3 rounded-box px-3 py-2 hover:bg-base-200"
    >
      <.icon name="hero-user" class="size-5 shrink-0 opacity-70" />
      <span class="min-w-0 grow truncate font-medium">{Person.full_name(@person)}</span>
      <span :if={@person.person_id} class="shrink-0 font-mono text-xs opacity-70">
        {PersonId.format(@person.person_id)}
      </span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :text, :string, required: true

  defp plain_row(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex min-w-0 items-center gap-3 rounded-box px-3 py-2 hover:bg-base-200"
    >
      <.icon name={@icon} class="size-5 shrink-0 opacity-70" />
      <span class="min-w-0 truncate">{@text}</span>
    </.link>
    """
  end
end
