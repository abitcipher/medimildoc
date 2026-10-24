defmodule AppWeb.PeopleListComponent do
  @moduledoc """
  A scrollable list of people (direct reports, readiness): quick search,
  sorting by full name or position, and rows rendered 20 at a time as
  the list scrolls (a LiveView stream; `phx-viewport-bottom` asks for the
  next page). Rows come from `AppWeb.PersonRows`; search and sort run over
  them in memory — these lists are one unit's people, and readiness status
  is encrypted, so it can't be filtered in SQL anyway.

  Row: avatar (hover: name and PersonID), full name linking to the person,
  position badge, and the status badge when rows carry a status.
  """
  use AppWeb, :live_component

  alias AppWeb.PersonBadges

  @page 20

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:sort, fn -> {:name, :asc} end)
      |> assign_new(:empty, fn -> gettext("Nobody here yet.") end)

    socket =
      if socket.assigns[:configured?],
        do: socket,
        else:
          socket
          |> stream_configure(:rows, dom_id: &"#{assigns.id}-#{&1.id}")
          |> assign(:configured?, true)

    {:ok, reset(socket)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> reset()}

  def handle_event("sort", %{"by" => by}, socket) do
    by = if by == "position", do: :position, else: :name

    sort =
      case socket.assigns.sort do
        {^by, :asc} -> {by, :desc}
        _ -> {by, :asc}
      end

    {:noreply, socket |> assign(:sort, sort) |> reset()}
  end

  def handle_event("more", _params, socket) do
    %{filtered: filtered, shown: shown} = socket.assigns
    next = filtered |> Enum.drop(shown) |> Enum.take(@page)

    {:noreply,
     socket
     |> stream(:rows, next, at: -1)
     |> assign(:shown, shown + length(next))}
  end

  defp reset(socket) do
    %{rows: rows, query: query, sort: sort} = socket.assigns
    filtered = rows |> filter(query) |> sort_rows(sort)
    first = Enum.take(filtered, @page)

    socket
    |> assign(filtered: filtered, total: length(filtered), shown: length(first))
    |> assign(:status?, Enum.any?(rows, & &1.status))
    |> stream(:rows, first, reset: true)
  end

  defp filter(rows, query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        rows

      needle ->
        Enum.filter(rows, fn row ->
          [
            row.name,
            row.person_id,
            row.position && row.position.title,
            row.position && row.position.organization
          ]
          |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
        end)
    end
  end

  # People without a position go last, whatever the direction.
  defp sort_rows(rows, {:name, dir}), do: Enum.sort_by(rows, &String.downcase(&1.name), dir)

  defp sort_rows(rows, {:position, dir}) do
    {with, without} = Enum.split_with(rows, & &1.position)

    Enum.sort_by(with, &{String.downcase(&1.position.title), String.downcase(&1.name)}, dir) ++
      Enum.sort_by(without, &String.downcase(&1.name))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div :if={@rows != []} class="flex flex-wrap items-center gap-2">
        <form
          id={"#{@id}-search"}
          phx-change="search"
          phx-submit="search"
          phx-target={@myself}
          class="min-w-40 grow"
          role="search"
        >
          <label class="input input-sm w-full">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="search"
              name="q"
              value={@query}
              phx-debounce="200"
              autocomplete="off"
              placeholder={gettext("Search by name or position")}
              aria-label={gettext("Search by name or position")}
            />
          </label>
        </form>
        <div class="join" role="group" aria-label={gettext("Sort")}>
          <.sort_button target={@myself} by={:name} sort={@sort} label={gettext("Name")} />
          <.sort_button target={@myself} by={:position} sort={@sort} label={gettext("Position")} />
        </div>
      </div>

      <p :if={@rows != [] and @total != length(@rows)} class="text-xs opacity-60" aria-live="polite">
        {gettext("%{found} of %{total}", found: @total, total: length(@rows))}
      </p>

      <ul
        id={"#{@id}-rows"}
        phx-update="stream"
        phx-viewport-bottom={@shown < @total && JS.push("more", target: @myself)}
        class="max-h-80 overflow-y-auto overscroll-contain rounded-box border border-base-300 empty:hidden"
      >
        <li
          :for={{dom_id, row} <- @streams.rows}
          id={dom_id}
          class="flex items-center gap-2 border-b border-base-200 px-2 py-1.5 last:border-b-0"
        >
          <PersonBadges.avatar
            name={row.name}
            key={row.id}
            photo_url={row[:photo_url]}
            tip={Enum.join(Enum.reject([row.name, row.person_id], &is_nil/1), " · ")}
          />
          <.link
            navigate={~p"/people/#{row.id}"}
            class="link link-hover min-w-0 grow truncate text-sm"
          >
            {row.name}
          </.link>
          <PersonBadges.position position={row.position} class="max-w-28 sm:max-w-48" />
          <PersonBadges.status
            :if={@status? && row.status}
            label={row.status.label}
            badge={row.status.badge}
            details={row.status.details}
          />
        </li>
      </ul>

      <p :if={@total == 0} class="text-sm opacity-60">
        {if @rows == [], do: @empty, else: gettext("No matches.")}
      </p>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :by, :atom, required: true
  attr :sort, :any, required: true
  attr :label, :string, required: true

  defp sort_button(assigns) do
    assigns = assign(assigns, :active, elem(assigns.sort, 0) == assigns.by)

    ~H"""
    <button
      type="button"
      phx-click="sort"
      phx-value-by={@by}
      phx-target={@target}
      class={["btn btn-xs join-item", @active && "btn-active"]}
      aria-pressed={to_string(@active)}
    >
      {@label}
      <.icon
        :if={@active}
        name={if elem(@sort, 1) == :asc, do: "hero-arrow-up", else: "hero-arrow-down"}
        class="size-3"
      />
    </button>
    """
  end
end
