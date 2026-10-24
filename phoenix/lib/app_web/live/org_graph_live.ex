defmodule AppWeb.OrgGraphLive do
  @moduledoc """
  The org graph (docs/design/org-graph.md, task ORG-GRAPH): the structure as
  an interactive Cytoscape.js graph — units, posts, who holds them,
  reporting lines, deputies, care providers and their places. Everything is
  read as the viewer (`App.OrgGraph.Data`); the graph itself is drawn in the
  browser (hook `OrgGraph`). Unit, layout, layers and grouping are in the
  URL (`?unit=…&layout=network&layers=units,posts&group=1`), so a view can
  be shared. Collapsing units (ORG-GRAPH.3) happens in the browser.
  """
  use AppWeb, :live_view

  alias App.OrgGraph
  alias App.OrgGraph.{Data, Overlay, Relations}
  alias App.People.{Organization, Person}

  @layouts ~w(network hierarchy circles)
  @default_layers ~w(units posts people reporting deputies)
  @max_matches 50
  # ORG-GRAPH.7: above this many nodes only the units are sent, and a
  # unit's contents when it is opened.
  @progressive_over 600

  @impl true
  def mount(_params, _session, socket) do
    units =
      Organization
      |> Ash.read!(actor: socket.assigns.current_user)
      |> Enum.sort_by(& &1.name)

    {:ok,
     assign(socket,
       page_title: gettext("Org graph"),
       units: units,
       query: "",
       matches: nil,
       counts: nil,
       selected: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = parse_view(params, socket.assigns.units)
    before = socket.assigns
    socket = assign(socket, view)

    cond do
      needs_load?(before, view) ->
        {:noreply, socket |> load() |> load_overlay() |> push_data()}

      before[:overlay] != view.overlay ->
        {:noreply, socket |> load_overlay() |> push_data()}

      before[:layers] != view.layers ->
        {:noreply, push_data(socket)}

      true ->
        {:noreply,
         push_event(socket, "graph:layout", %{layout: view.graph_layout, group: view.group?})}
    end
  end

  defp parse_view(params, units) do
    %{
      unit: if(Enum.any?(units, &(&1.id == params["unit"])), do: params["unit"]),
      graph_layout: if(params["layout"] in @layouts, do: params["layout"], else: "network"),
      layers: parse_layers(params["layers"]),
      group?: params["group"] == "1",
      force_progressive?: params["progressive"] == "1",
      overlay: if(params["overlay"] in Overlay.overlays(), do: params["overlay"]),
      # ORG-GRAPH.5: the holders on a date, and changes since another.
      on: parse_date(params["on"]),
      compare: parse_date(params["compare"])
    }
  end

  # New data: another unit or dates, or a relation layer shown whose data
  # isn't loaded yet (ORG-GRAPH.4).
  defp needs_load?(before, view) do
    relations = Enum.filter(view.layers, &(&1 in Relations.layers()))

    not Map.has_key?(before, :data) or Map.get(before, :loaded_unit, :none) != view.unit or
      {view.on, view.compare} != {before[:on], before[:compare]} or
      not Enum.all?(relations, &(&1 in Map.get(before, :loaded_relations, [])))
  end

  defp parse_date(value) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_layers(nil), do: @default_layers

  defp parse_layers(value),
    do: value |> String.split(",", trim: true) |> Enum.filter(&(&1 in OrgGraph.layers()))

  defp load(socket) do
    relations = Enum.filter(socket.assigns.layers, &(&1 in Relations.layers()))

    data =
      Data.load(socket.assigns.unit, socket.assigns.current_user,
        relations: relations,
        on: socket.assigns.on,
        compare: socket.assigns.compare
      )

    nodes =
      Enum.count(
        OrgGraph.elements(data, OrgGraph.layers()),
        &(not Map.has_key?(&1.data, :source))
      )

    assign(socket,
      data: data,
      loaded_unit: socket.assigns.unit,
      loaded_relations: relations,
      selected: nil,
      progressive?: socket.assigns.force_progressive? or nodes > @progressive_over,
      opened: top_units(data, socket.assigns.unit)
    )
  end

  # Opened at first: the chosen unit, or the top units of the whole tree.
  defp top_units(data, nil) do
    ids = MapSet.new(data.units, & &1.id)

    for unit <- data.units,
        not MapSet.member?(ids, unit.parent_id),
        into: MapSet.new(),
        do: unit.id
  end

  defp top_units(_data, unit), do: MapSet.new([unit])

  # Everything the viewer may see, with the overlay.
  defp full_elements(socket) do
    socket.assigns.data
    |> OrgGraph.elements(socket.assigns.layers)
    |> OrgGraph.overlay(socket.assigns.overlay, socket.assigns.overlay_data)
  end

  # What is sent: everything, or in progressive mode the opened part.
  defp elements(socket) do
    full = full_elements(socket)

    if socket.assigns.progressive?,
      do: OrgGraph.subgraph(full, socket.assigns.data, socket.assigns.opened),
      else: full
  end

  # Open units (ORG-GRAPH.7) and send the browser the new sub-graph.
  defp open_units(socket, unit_ids) do
    socket
    |> update(:opened, &MapSet.union(&1, MapSet.new(unit_ids)))
    |> then(&push_event(&1, "graph:merge", %{elements: elements(&1)}))
  end

  # The units holding these nodes (posts, people, providers).
  defp units_of(ids, data) do
    post_unit = Map.new(data.posts, &{&1.id, &1.organization_id})

    Enum.flat_map(ids, fn
      "p:" <> id -> [post_unit[id]]
      "h:" <> id -> for {^id, post} <- data.holders, do: post_unit[post]
      "c:" <> id -> [Enum.find_value(data.providers, &(&1.id == id && &1.organization_id))]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ORG-GRAPH.6: the overlay's values, read again with the data.
  defp load_overlay(socket) do
    %{overlay: name, data: data, current_user: actor} = socket.assigns
    assign(socket, overlay_data: Overlay.load(name, data, actor))
  end

  # Before the hook is connected nothing is listening; the hook asks
  # with "ready" and gets the elements in the reply.
  defp push_data(socket) do
    elements = elements(socket)

    socket
    |> assign(counts: counts(full_elements(socket)))
    |> push_event("graph:data", %{
      elements: elements,
      layout: socket.assigns.graph_layout,
      group: socket.assigns.group?
    })
  end

  defp counts(elements) do
    elements
    |> Enum.reject(&Map.has_key?(&1.data, :source))
    |> Enum.frequencies_by(& &1.data.type)
  end

  @impl true
  def handle_event("ready", _params, socket) do
    elements = elements(socket)

    {:reply,
     %{elements: elements, layout: socket.assigns.graph_layout, group: socket.assigns.group?},
     assign(socket, counts: counts(full_elements(socket)))}
  end

  def handle_event("view", params, socket) do
    layers = Enum.filter(OrgGraph.layers(), &(params["layer_" <> &1] == "true"))

    {:noreply,
     push_patch(socket,
       to:
         graph_path(%{
           unit: blank_to_nil(params["unit"]),
           layout: params["layout"],
           layers: layers,
           group: params["group"] == "true",
           overlay: blank_to_nil(params["overlay"]),
           on: blank_to_nil(params["on"]),
           compare: blank_to_nil(params["compare"])
         })
     )}
  end

  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q)
    ids = if q == "", do: [], else: matches(full_elements(socket), q)
    shown = Enum.take(ids, @max_matches)

    # In progressive mode the units holding the matches are opened first.
    socket =
      if socket.assigns.progressive? and shown != [],
        do: open_units(socket, units_of(shown, socket.assigns.data)),
        else: socket

    {:noreply,
     socket
     |> assign(query: q, matches: if(q == "", do: nil, else: length(ids)))
     |> push_event("graph:highlight", %{ids: shown})}
  end

  def handle_event("select", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, assign(socket, selected: id)}

  def handle_event("select", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  # Open a unit's contents (ORG-GRAPH.7): a double-click on it or its details.
  def handle_event("expand", %{"id" => "u:" <> id}, socket),
    do: {:noreply, open_units(socket, [id])}

  def handle_event("expand", _params, socket), do: {:noreply, socket}

  # Collapse or expand a unit (ORG-GRAPH.3), from its details.
  def handle_event("toggle", %{"id" => id}, socket),
    do: {:noreply, push_event(socket, "graph:toggle", %{id: id})}

  # A name in the details panel: select that node on the graph too.
  def handle_event("go", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(selected: id) |> push_event("graph:select", %{id: id})}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp matches(elements, q) do
    q = String.downcase(q)

    for %{data: %{label: label, id: id}} <- elements,
        is_binary(label),
        String.contains?(String.downcase(label), q),
        do: id
  end

  # Layers always go in the URL (none shown is a choice too).
  defp graph_path(%{unit: unit, layout: layout, layers: layers, group: group} = view) do
    query =
      Enum.reject(
        [
          unit: unit,
          layout: layout,
          on: view[:on],
          compare: view[:compare],
          overlay: view[:overlay]
        ],
        fn {_key, value} -> value in [nil, ""] end
      ) ++
        [layers: Enum.join(layers, ",")] ++ if(group, do: [group: "1"], else: [])

    ~p"/org-graph?#{query}"
  end

  # What the details panel shows for the selected node.
  defp details(nil, _data), do: nil

  defp details("u:" <> id, data) do
    with %{} = unit <- Enum.find(data.units, &(&1.id == id)) do
      posts = Enum.filter(data.posts, &(&1.organization_id == id))
      post_ids = MapSet.new(posts, & &1.id)

      %{
        type: :unit,
        title: unit.name,
        rows: [
          {gettext("Parent unit"), parent_name(unit, data)},
          {gettext("Location"), location(unit.id, data)},
          {gettext("Posts"), length(posts)},
          {gettext("People"), Enum.count(data.holders, &MapSet.member?(post_ids, elem(&1, 1)))}
        ],
        links: Enum.map(sub_units(id, data), &{"u:" <> &1.id, &1.name}),
        links_title: gettext("Sub-units"),
        path: nil
      }
    end
  end

  defp details("p:" <> id, data) do
    with %{} = post <- Enum.find(data.posts, &(&1.id == id)) do
      holders = for {person, ^id} <- data.holders, do: person
      boss = Enum.find(data.posts, &(&1.id == post.reports_to_id))

      %{
        type: :post,
        title: post.title,
        rows: [
          {gettext("Unit"), unit_name(post.organization_id, data)},
          {gettext("Grade"), post.authorised_grade},
          {gettext("Strength"), post.strength || 1},
          {gettext("Vacant"), max((post.strength || 1) - length(holders), 0)},
          {gettext("Reports to"), boss && boss.title}
        ],
        links: Enum.map(holders, &{"h:" <> &1, Person.full_name(data.people[&1])}),
        links_title: gettext("Holders"),
        path: nil
      }
    end
  end

  defp details("h:" <> id, data) do
    with %{} = person <- data.people[id] do
      posts = for {^id, post} <- data.holders, do: Enum.find(data.posts, &(&1.id == post))
      deputy_of = for {from, ^id} <- data.deputies, do: from
      deputies = for {^id, to} <- data.deputies, do: to

      %{
        type: :person,
        title: Person.full_name(person),
        rows:
          Enum.map(
            posts,
            &{gettext("Post"), "#{&1.title} · #{unit_name(&1.organization_id, data)}"}
          ) ++
            [
              {gettext("Location"),
               posts |> List.first() |> then(&(&1 && location(&1.organization_id, data)))},
              {gettext("Deputy for"), names(deputy_of, data)},
              {gettext("Deputies"), names(deputies, data)}
            ],
        links: Enum.map(posts, &{"p:" <> &1.id, &1.title}),
        links_title: gettext("Posts"),
        path: ~p"/people/#{id}"
      }
    end
  end

  defp details("c:" <> id, data) do
    with %{} = provider <- Enum.find(data.providers, &(&1.id == id)) do
      %{
        type: :provider,
        title: provider.name,
        rows: [
          {gettext("Unit"),
           provider.organization_id && unit_name(provider.organization_id, data)},
          {gettext("Locality"), provider.locality},
          {gettext("Country"), provider.country}
        ],
        links: [],
        links_title: nil,
        path: ~p"/care-providers"
      }
    end
  end

  # A place: the units there (with their own place) and the care providers.
  defp details("l:" <> _ = id, data) do
    units = Enum.filter(data.units, &(OrgGraph.place_id(&1) == id))
    providers = Enum.filter(data.providers, &(OrgGraph.place_id(&1) == id))

    case units ++ providers do
      [first | _] ->
        %{
          type: :place,
          title: OrgGraph.place_label(first),
          rows: [],
          links:
            Enum.map(units, &{"u:" <> &1.id, &1.name}) ++
              Enum.map(providers, &{"c:" <> &1.id, &1.name}),
          links_title: gettext("Units and care providers"),
          path: nil
        }

      [] ->
        nil
    end
  end

  defp details(_id, _data), do: nil

  # A unit not opened yet in progressive mode (ORG-GRAPH.7): how many of
  # its posts and holders the button would bring.
  defp with_remote(%{type: :unit} = detail, %{selected: "u:" <> id} = assigns) do
    remote =
      if assigns.progressive? and not MapSet.member?(assigns.opened, id) do
        posts =
          for post <- assigns.data.posts,
              post.organization_id == id,
              into: MapSet.new(),
              do: post.id

        MapSet.size(posts) + Enum.count(assigns.data.holders, &MapSet.member?(posts, elem(&1, 1)))
      end

    Map.put(detail, :remote, if(remote && remote > 0, do: remote))
  end

  defp with_remote(detail, _assigns), do: detail

  # Where a unit is: its own place, or "… (as Parent)" when inherited.
  defp location(unit_id, data) do
    case OrgGraph.unit_place(unit_id, data.units) do
      nil -> nil
      {%{id: ^unit_id}, label} -> label
      {unit, label} -> gettext("%{place} (as %{unit})", place: label, unit: unit.name)
    end
  end

  defp parent_name(%{parent_id: nil}, _data), do: nil
  defp parent_name(%{parent_id: id}, data), do: unit_name(id, data)

  defp unit_name(id, data), do: Enum.find_value(data.units, &(&1.id == id && &1.name))

  defp sub_units(id, data),
    do: data.units |> Enum.filter(&(&1.parent_id == id)) |> Enum.sort_by(& &1.name)

  defp names([], _data), do: nil
  defp names(ids, data), do: Enum.map_join(ids, ", ", &Person.full_name(data.people[&1]))

  defp layer_label("units"), do: gettext("Units")
  defp layer_label("posts"), do: gettext("Posts")
  defp layer_label("people"), do: gettext("People")
  defp layer_label("reporting"), do: gettext("Reporting lines")
  defp layer_label("deputies"), do: gettext("Deputies")
  defp layer_label("providers"), do: gettext("Care providers")
  defp layer_label("places"), do: gettext("Places")
  defp layer_label("duty"), do: gettext("On duty together")
  defp layer_label("approvals"), do: gettext("Approves / signs")
  defp layer_label("acknowledgements"), do: gettext("Acknowledged")
  defp layer_label("referrals"), do: gettext("Referrals")
  defp layer_label("family"), do: gettext("Family")

  defp export_formats,
    do: [
      {"png", gettext("Image (PNG)")},
      {"svg", gettext("Vector image (SVG)")},
      {"graphml", gettext("Graph (GraphML)")},
      {"csv-nodes", gettext("Nodes (CSV)")},
      {"csv-edges", gettext("Edges (CSV)")}
    ]

  defp overlay_label("readiness"), do: gettext("Readiness")
  defp overlay_label("absence"), do: gettext("Away on the date")
  defp overlay_label("vacancies"), do: gettext("Vacancies by unit")

  # What the overlay's colours mean (the same theme colours as the graph).
  defp legend("readiness"),
    do: [
      {"bg-success", AppWeb.SchemaText.choice("fit_for_duty")},
      {"bg-warning", AppWeb.SchemaText.choice("downgraded")},
      {"bg-error", AppWeb.SchemaText.choice("non_effective")},
      {"bg-base-300", gettext("No assessment you may see")}
    ]

  defp legend("absence"),
    do: [
      {"bg-warning", gettext("On leave")},
      {"bg-error", gettext("Sick leave")},
      {"bg-info", gettext("Business trip")},
      {"bg-base-300", gettext("Present")}
    ]

  defp legend("vacancies"),
    do: [{"bg-error", gettext("Unit: vacant places in it and its sub-units")}]

  defp layout_label("hierarchy"), do: gettext("Hierarchy")
  defp layout_label("network"), do: gettext("Network")
  defp layout_label("circles"), do: gettext("Circles")

  # The swatch next to a layer: the node shape or line it draws.
  defp swatch_class("units"), do: "h-3 w-4 rounded-sm bg-neutral"
  defp swatch_class("posts"), do: "size-3 border border-base-300 bg-base-200"
  defp swatch_class("people"), do: "size-3 rounded-full bg-primary"
  defp swatch_class("reporting"), do: "h-0 w-4 border-t-2 border-dashed border-secondary"
  defp swatch_class("deputies"), do: "h-0 w-4 border-t-2 border-dotted border-accent"
  defp swatch_class("providers"), do: "size-3 rotate-45 bg-info"
  defp swatch_class("places"), do: "size-3 rounded-sm bg-success"
  defp swatch_class("duty"), do: "h-0 w-4 border-t-2 border-warning"
  defp swatch_class("approvals"), do: "h-0 w-4 border-t-2 border-info"
  defp swatch_class("acknowledgements"), do: "h-0 w-4 border-t-2 border-dashed border-success"
  defp swatch_class("referrals"), do: "h-0 w-4 border-t-2 border-dashed border-error"
  defp swatch_class("family"), do: "size-3 rounded-full border-2 border-accent"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        layouts: @layouts,
        overlays: Overlay.overlays(),
        all_layers: OrgGraph.layers(),
        detail: assigns.selected |> details(assigns.data) |> with_remote(assigns)
      )

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-7xl flex-col gap-3 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Org graph")}
            <.field_description description={
              gettext(
                "Units, their posts, who holds them, reporting lines (dashed arrows to the superior post), deputies (dotted arrows), care providers, places, and relations between people as extra layers. Click a node to see its details; double-click a unit to collapse or expand it, another node to zoom to it. As of: the holders on that date; Compare with: who joined or left a post since. An overlay colours people by readiness or absence, or shows vacant places per unit. Dashed post border: vacant places. Thick border: a post others report to. Only people you may see are shown."
              )
            } />
          </h1>
          <form
            id="graph-search"
            phx-change="search"
            phx-submit="search"
            class="flex items-center gap-2"
          >
            <label for="graph-search-q" class="sr-only">{gettext("Find on the graph")}</label>
            <input
              id="graph-search-q"
              type="search"
              name="q"
              value={@query}
              phx-debounce="300"
              placeholder={gettext("Find on the graph")}
              class="input input-sm w-56"
            />
            <span :if={@matches} id="graph-matches" class="text-sm tabular-nums opacity-70">
              {ngettext("%{count} found", "%{count} found", @matches)}
            </span>
          </form>
        </div>

        <form id="graph-view" phx-change="view" class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <label for="graph-unit" class="sr-only">{gettext("Unit")}</label>
          <select id="graph-unit" name="unit" class="select select-sm max-w-64">
            <option value="" selected={is_nil(@unit)}>{gettext("All units")}</option>
            <option :for={unit <- @units} value={unit.id} selected={unit.id == @unit}>
              {unit.name}
            </option>
          </select>
          <label for="graph-layout" class="sr-only">{gettext("Layout")}</label>
          <select id="graph-layout" name="layout" class="select select-sm w-36">
            <option :for={layout <- @layouts} value={layout} selected={layout == @graph_layout}>
              {layout_label(layout)}
            </option>
          </select>
          <label for="graph-overlay" class="sr-only">{gettext("Overlay")}</label>
          <select id="graph-overlay" name="overlay" class="select select-sm w-44">
            <option value="" selected={is_nil(@overlay)}>{gettext("No overlay")}</option>
            <option :for={name <- @overlays} value={name} selected={name == @overlay}>
              {overlay_label(name)}
            </option>
          </select>
          <label class="flex items-center gap-1.5 text-sm">
            <span class="opacity-70">{gettext("As of")}</span>
            <input
              type="date"
              id="graph-on"
              name="on"
              value={@on && Date.to_iso8601(@on)}
              class="input input-sm w-40"
            />
          </label>
          <label class="flex items-center gap-1.5 text-sm">
            <span class="opacity-70">{gettext("Compare with")}</span>
            <input
              type="date"
              id="graph-compare"
              name="compare"
              value={@compare && Date.to_iso8601(@compare)}
              class="input input-sm w-40"
            />
          </label>
          <label class="flex cursor-pointer items-center gap-1.5 text-sm">
            <input type="hidden" name="group" value="false" />
            <input
              type="checkbox"
              name="group"
              value="true"
              checked={@group?}
              class="toggle toggle-xs"
              id="graph-group"
            />
            {gettext("Group by unit")}
          </label>
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
            <label :for={layer <- @all_layers} class="flex cursor-pointer items-center gap-1.5">
              <input type="hidden" name={"layer_" <> layer} value="false" />
              <input
                type="checkbox"
                name={"layer_" <> layer}
                value="true"
                checked={layer in @layers}
                class="checkbox checkbox-xs"
              />
              <span class={["inline-block shrink-0", swatch_class(layer)]}></span>
              {layer_label(layer)}
              <span
                :if={layer in ~w(referrals family)}
                class="cursor-help"
                data-float-tip={
                  gettext(
                    "Sensitive: shown only where you may read it, and each one you see is written to the access log."
                  )
                }
              >
                <.icon name="hero-lock-closed" class="size-3.5 opacity-60" />
              </span>
              <span
                :if={
                  layer in ~w(units posts people providers places family) and
                    Map.get(@counts || %{}, type_of(layer))
                }
                class="tabular-nums opacity-60"
              >
                {Map.get(@counts || %{}, type_of(layer))}
              </span>
            </label>
          </div>
        </form>

        <div
          :if={@overlay}
          id="graph-legend"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs"
        >
          <span :for={{swatch, label} <- legend(@overlay)} class="flex items-center gap-1.5">
            <span class={["inline-block size-3 shrink-0 rounded-full", swatch]}></span>
            {label}
          </span>
        </div>

        <p :if={@data.changes} id="graph-changes" class="text-sm">
          <span class="badge badge-sm badge-success badge-outline">
            {ngettext("%{count} joined", "%{count} joined", MapSet.size(@data.changes.joined))}
          </span>
          <span class="badge badge-sm badge-error badge-outline">
            {ngettext("%{count} left", "%{count} left", length(@data.changes.left))}
          </span>
          <span class="opacity-70">
            {gettext("posts between %{from} and %{to}",
              from: AppWeb.DateFormat.display(@data.changes.since),
              to: AppWeb.DateFormat.display(@data.on)
            )}
          </span>
        </p>

        <div class="flex flex-col gap-3 md:flex-row">
          <div
            id="org-graph"
            phx-hook="OrgGraph"
            data-src={~p"/assets/js/org_graph.js"}
            class="relative min-w-0 flex-1"
          >
            <div
              id="org-graph-canvas"
              data-graph-canvas
              phx-update="ignore"
              class="h-[70vh] w-full rounded-box border border-base-300 bg-base-100"
            >
            </div>
            <div class="absolute top-2 right-2 flex gap-1">
              <button
                type="button"
                data-graph-action="collapse"
                class="btn btn-xs btn-square"
                aria-label={gettext("Collapse units")}
                data-float-tip={gettext("Collapse units")}
              >
                <.icon name="hero-arrows-pointing-in" class="size-4" />
              </button>
              <button
                type="button"
                data-graph-action="expand"
                class="btn btn-xs btn-square"
                aria-label={gettext("Expand all")}
                data-float-tip={gettext("Expand all")}
              >
                <.icon name="hero-squares-plus" class="size-4" />
              </button>
              <button
                type="button"
                data-graph-action="fit"
                class="btn btn-xs btn-square"
                aria-label={gettext("Fit to screen")}
                data-float-tip={gettext("Fit to screen")}
              >
                <.icon name="hero-arrows-pointing-out" class="size-4" />
              </button>
              <%!-- ORG-GRAPH.8: what is shown, as an image or as data. --%>
              <details id="graph-export" class="dropdown dropdown-end">
                <summary
                  class="btn btn-xs btn-square"
                  aria-label={gettext("Export")}
                  data-float-tip={gettext("Export")}
                >
                  <.icon name="hero-arrow-down-tray" class="size-4" />
                </summary>
                <ul class="menu dropdown-content z-10 w-56 rounded-box border border-base-300 bg-base-100 p-1 text-sm shadow">
                  <li :for={{action, label} <- export_formats()}>
                    <button type="button" data-graph-action={action}>{label}</button>
                  </li>
                </ul>
              </details>
            </div>
          </div>

          <aside
            :if={@detail}
            id="graph-details"
            class="flex w-full shrink-0 flex-col gap-3 rounded-box border border-base-300 p-3 text-sm md:w-72"
          >
            <div class="flex items-start justify-between gap-2">
              <h2 class="font-semibold">{@detail.title}</h2>
              <button
                type="button"
                phx-click="select"
                class="btn btn-ghost btn-xs btn-square"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
              <%= for {label, value} <- @detail.rows, value not in [nil, ""] do %>
                <dt class="opacity-70">{label}</dt>
                <dd class="min-w-0 break-words">{value}</dd>
              <% end %>
            </dl>
            <div :if={@detail.links != []} class="flex flex-col gap-1">
              <h3 class="text-xs font-semibold opacity-70">{@detail.links_title}</h3>
              <ul class="flex flex-col gap-0.5">
                <li :for={{id, label} <- @detail.links}>
                  <button
                    type="button"
                    phx-click="go"
                    phx-value-id={id}
                    class="link link-hover text-left"
                  >
                    {label}
                  </button>
                </li>
              </ul>
            </div>
            <button
              :if={@detail.type == :unit and @progressive? and @detail.remote}
              type="button"
              id="graph-expand-unit"
              phx-click="expand"
              phx-value-id={@selected}
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-plus" class="size-4" />
              {ngettext("Show %{count} more", "Show %{count} more", @detail.remote)}
            </button>
            <button
              :if={@detail.type == :unit}
              type="button"
              id="graph-toggle-unit"
              phx-click="toggle"
              phx-value-id={@selected}
              class="btn btn-sm"
            >
              <.icon name="hero-arrows-up-down" class="size-4" /> {gettext("Collapse / expand")}
            </button>
            <.link :if={@detail.path} navigate={@detail.path} class="btn btn-sm">
              {gettext("Open")}
            </.link>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp type_of("units"), do: "unit"
  defp type_of("posts"), do: "post"
  defp type_of("people"), do: "person"
  defp type_of("providers"), do: "provider"
  defp type_of("places"), do: "place"
  defp type_of("family"), do: "relative"
end
