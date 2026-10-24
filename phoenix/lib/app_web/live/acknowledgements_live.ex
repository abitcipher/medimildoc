defmodule AppWeb.AcknowledgementsLive do
  @moduledoc """
  Recording that people acknowledged their orders, in bulk
  (docs/design/acknowledgements.md): the signed orders still awaiting
  acknowledgement that the viewer may record (HR for the types they
  write, a commander for the people in their unit), filtered by unit (with
  its sub-units), order type and signing date; check the ones read out at
  a formation or signed on paper and record them in one step — each
  through `App.Documents.Acknowledgement`'s `:record`, so the policies and
  checks apply to every one.

  One DOM per row (a grid on wide screens, a card on phones), because the
  check boxes belong to one form — a list drawn twice would send them
  twice. The record bar stays at the bottom of the screen while the list
  scrolls.
  """
  use AppWeb, :live_view

  alias App.Documents.{Acknowledgement, Queries, Types}
  alias AppWeb.DocumentUI

  @limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Acknowledgements"),
       units: units(socket.assigns.current_user),
       types: Types.acknowledge_types(),
       filters: %{"unit" => "", "type" => "", "signed_from" => ""},
       selected: MapSet.new(),
       limit: @limit
     )
     |> load()}
  end

  defp load(socket) do
    documents =
      Queries.pending_acknowledgements(
        socket.assigns.current_user,
        query_filters(socket.assigns.filters),
        @limit
      )

    ids = MapSet.new(documents, & &1.id)

    assign(socket,
      documents: documents,
      selected: MapSet.intersection(socket.assigns.selected, ids)
    )
  end

  defp query_filters(filters) do
    %{
      unit: blank(filters["unit"]),
      type: Enum.find(Types.acknowledge_types(), &(Atom.to_string(&1) == filters["type"])),
      signed_from:
        case Date.from_iso8601(filters["signed_from"] || "") do
          {:ok, date} -> date
          _ -> nil
        end
    }
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  # Units to filter by: the organizations the viewer may read, by name.
  defp units(actor) do
    App.People.Organization
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&{&1.name, &1.id})
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> assign(filters: Map.merge(socket.assigns.filters, filters)) |> load()}
  end

  def handle_event("select", params, socket) do
    ids = params |> Map.get("ids", []) |> List.wrap() |> MapSet.new()
    {:noreply, assign(socket, selected: ids)}
  end

  def handle_event("select_all", _params, socket) do
    all = MapSet.new(socket.assigns.documents, & &1.id)
    selected = if MapSet.equal?(socket.assigns.selected, all), do: MapSet.new(), else: all
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("record", %{"acknowledgement" => params}, socket) do
    actor = socket.assigns.current_user

    results =
      for id <- socket.assigns.selected do
        Acknowledgement
        |> Ash.Changeset.for_create(
          :record,
          %{
            document_id: id,
            acknowledged_on: params["acknowledged_on"],
            method: params["method"],
            note: blank(params["note"] || "")
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
      end

    {done, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

    socket =
      socket
      |> assign(selected: MapSet.new())
      |> load()
      |> put_flash(:info, ngettext("%{count} recorded", "%{count} recorded", length(done)))

    socket =
      case failed do
        [] ->
          socket

        [{:error, error} | _] ->
          put_flash(
            socket,
            :error,
            ngettext(
              "%{count} not recorded: %{reason}",
              "%{count} not recorded, for example: %{reason}",
              length(failed),
              reason: translate(App.AshErrors.summarize(error))
            )
          )
      end

    {:noreply, socket}
  end

  defp translate(text),
    do: text |> String.split("; ") |> Enum.map_join("; ", &Gettext.gettext(AppWeb.Gettext, &1))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-6 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("Acknowledgements")}
          <.field_description description={
            gettext(
              "Signed orders whose person has not acknowledged them yet, among those you may record: when an order was read out to the person or they signed it on paper, check it and record it here. People can also acknowledge their own orders in the app."
            )
          } />
        </h1>

        <form id="acknowledgement-filters" phx-change="filter" class="flex flex-wrap items-end gap-3">
          <label class="flex min-w-48 flex-col gap-1">
            <span class="text-xs opacity-70">{gettext("Unit")}</span>
            <select name="filters[unit]" class="select select-sm">
              <option value="">{gettext("All units")}</option>
              <option :for={{name, id} <- @units} value={id} selected={@filters["unit"] == id}>
                {name}
              </option>
            </select>
          </label>
          <label class="flex min-w-48 flex-col gap-1">
            <span class="text-xs opacity-70">{gettext("Order")}</span>
            <select name="filters[type]" class="select select-sm">
              <option value="">{gettext("All orders")}</option>
              <option
                :for={type <- @types}
                value={type}
                selected={@filters["type"] == Atom.to_string(type)}
              >
                {DocumentUI.type_label(type)}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">{gettext("Signed from")}</span>
            <input
              type="date"
              name="filters[signed_from]"
              value={@filters["signed_from"]}
              class="input input-sm"
            />
          </label>
        </form>

        <section id="pending-acknowledgements" class="flex flex-col gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="flex items-center gap-2 font-semibold">
              {gettext("Awaiting acknowledgement")}
              <span class="badge badge-sm badge-ghost">{length(@documents)}</span>
            </h2>
            <button
              :if={@documents != []}
              id="select-all"
              type="button"
              phx-click="select_all"
              class="btn btn-ghost btn-sm"
            >
              {if MapSet.size(@selected) == length(@documents),
                do: gettext("Select none"),
                else: gettext("Select all")}
            </button>
          </div>
          <p :if={length(@documents) == @limit} class="text-sm opacity-70">
            {gettext("Showing the oldest %{count}; narrow the filters to see others.", count: @limit)}
          </p>
          <p :if={@documents == []} class="text-sm opacity-70">
            {gettext("Nothing awaits acknowledgement.")}
          </p>

          <form
            :if={@documents != []}
            id="acknowledgement-selection"
            phx-change="select"
            class="flex flex-col"
          >
            <div class="hidden grid-cols-[2rem_2fr_2fr_1fr_1fr] gap-3 border-b border-base-300 px-2 pb-2 text-xs font-semibold opacity-70 md:grid">
              <span></span>
              <span>{gettext("Person")}</span>
              <span>{gettext("Order")}</span>
              <span>{gettext("Number")}</span>
              <span>{gettext("Signed")}</span>
            </div>
            <ul class="flex flex-col gap-2 md:gap-0 md:divide-y md:divide-base-200">
              <li
                :for={document <- @documents}
                id={"pending-#{document.id}"}
                class={[
                  "grid grid-cols-[2rem_1fr] gap-x-3 gap-y-1 rounded-box border border-base-300 p-3 text-sm md:grid-cols-[2rem_2fr_2fr_1fr_1fr] md:items-center md:rounded-none md:border-0 md:px-2 md:py-2",
                  document.id in @selected && "bg-base-200"
                ]}
              >
                <input
                  type="checkbox"
                  name="ids[]"
                  value={document.id}
                  checked={document.id in @selected}
                  class="checkbox checkbox-sm row-span-4 md:row-span-1"
                  aria-label={gettext("Select")}
                />
                <.link navigate={~p"/people/#{document.person_id}"} class="link link-hover truncate">
                  {App.People.Person.full_name(document.person)}
                </.link>
                <span class="truncate">{DocumentUI.type_label(document.type)}</span>
                <.link navigate={~p"/documents/#{document.id}"} class="link link-hover font-mono">
                  № {document.number}
                </.link>
                <span class="opacity-70">{AppWeb.DateFormat.display(
                  DateTime.to_date(document.signed_at)
                )}</span>
              </li>
            </ul>
          </form>

          <form
            :if={@documents != []}
            id="acknowledgement-record"
            phx-submit="record"
            class="sticky bottom-0 z-10 flex flex-wrap items-end gap-2 rounded-box border border-base-300 bg-base-200 p-3 shadow-lg"
          >
            <label class="flex flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("Date")}</span>
              <input
                type="date"
                name="acknowledgement[acknowledged_on]"
                value={Date.to_iso8601(Date.utc_today())}
                max={Date.to_iso8601(Date.utc_today())}
                class="input input-sm"
                required
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("How")}</span>
              <select name="acknowledgement[method]" class="select select-sm">
                <option value="in_person">{DocumentUI.acknowledgement_method(:in_person)}</option>
                <option value="paper">{DocumentUI.acknowledgement_method(:paper)}</option>
              </select>
            </label>
            <label class="flex min-w-48 grow flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("Note")}</span>
              <input
                type="text"
                name="acknowledgement[note]"
                maxlength="500"
                class="input input-sm w-full"
              />
            </label>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              disabled={MapSet.size(@selected) == 0}
              data-confirm={
                gettext("Record acknowledgement for %{count} selected?",
                  count: MapSet.size(@selected)
                )
              }
            >
              <.icon name="hero-check-badge" class="size-4" />
              {gettext("Record for %{count} selected", count: MapSet.size(@selected))}
            </button>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
