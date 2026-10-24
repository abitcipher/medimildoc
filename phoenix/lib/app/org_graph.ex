defmodule App.OrgGraph do
  @moduledoc """
  The org graph (docs/design/org-graph.md, task ORG-GRAPH) as Cytoscape.js
  elements, pure: nodes for units, posts, people, care providers and
  places; edges for "part of", "post in", "holds", "reports to", "deputy",
  "serves" and "located in". Which of them are shown is the `layers` set;
  when a layer in the middle is off, the edges skip it (a person joins
  their unit directly when posts are hidden).

  Node ids are prefixed by type (`u:`, `p:`, `h:`, `c:`, `l:`) so the
  page can tell what was clicked; labels are names as stored. Edges point
  down the structure (unit → post → holder, superior post → subordinate),
  which the hierarchy layout follows; a post that reports to another post
  on the graph hangs under it, so its "post in" edge is marked `via_boss`
  and left out of that layout.
  """

  alias App.People.Person

  @layers ~w(units posts people reporting deputies providers places) ++
            ~w(duty approvals acknowledgements referrals family)

  @doc "Every layer, in the order the page lists them."
  @spec layers() :: [String.t()]
  def layers, do: @layers

  @doc "The elements for `data` (`App.OrgGraph.Data.load/2`) with `layers` shown."
  @spec elements(map(), Enumerable.t()) :: [map()]
  def elements(data, layers) do
    on = MapSet.new(layers)
    on? = &MapSet.member?(on, &1)
    unit_ids = MapSet.new(data.units, & &1.id)
    post_unit = Map.new(data.posts, &{&1.id, &1.organization_id})
    held = Enum.frequencies_by(data.holders, &elem(&1, 1))
    leaders = data.posts |> Enum.map(& &1.reports_to_id) |> MapSet.new()

    List.flatten([
      if(on?.("units"), do: units(data.units, unit_ids, on?), else: []),
      if(on?.("posts"), do: posts(data.posts, held, leaders, on?), else: []),
      if(on?.("people"), do: people(data, post_unit, unit_ids, on?), else: []),
      if(on?.("providers"), do: providers(data.providers, unit_ids, on?), else: []),
      if(on?.("people"), do: relations(Map.get(data, :relations, %{}), data, on?), else: [])
    ])
    # A place may come from units and providers alike: once.
    |> Enum.uniq_by(& &1.data.id)
  end

  defp units(units, unit_ids, on?) do
    Enum.flat_map(units, fn unit ->
      place = on?.("places") && place_id(unit)

      [
        node("u:" <> unit.id, unit.name, "unit", %{kind: to_string(unit.kind)}),
        unit.parent_id && MapSet.member?(unit_ids, unit.parent_id) &&
          edge("u:" <> unit.parent_id, "u:" <> unit.id, "part_of"),
        # ORG-GRAPH.1: a unit with a place of its own; one below it is
        # where its parent is (no edge of its own).
        place && node(place, place_label(unit), "place"),
        place && edge("u:" <> unit.id, place, "located_in")
      ]
      |> Enum.filter(& &1)
    end)
    |> Enum.uniq_by(& &1.data.id)
  end

  defp posts(posts, held, leaders, on?) do
    post_ids = MapSet.new(posts, & &1.id)

    Enum.flat_map(posts, fn post ->
      boss? =
        on?.("reporting") && post.reports_to_id && MapSet.member?(post_ids, post.reports_to_id)

      [
        post_node(post, Map.get(held, post.id, 0), MapSet.member?(leaders, post.id)),
        on?.("units") &&
          edge(
            "u:" <> post.organization_id,
            "p:" <> post.id,
            "post_in",
            if(boss?, do: ["via_boss"], else: [])
          ),
        boss? && edge("p:" <> post.reports_to_id, "p:" <> post.id, "reports_to")
      ]
      |> Enum.filter(& &1)
    end)
  end

  defp post_node(post, holders, leader?) do
    strength = post.strength || 1
    vacant = max(strength - holders, 0)
    classes = Enum.filter([vacant > 0 && "vacant", leader? && "leader"], & &1)
    node("p:" <> post.id, post.title, "post", %{vacant: vacant, strength: strength}, classes)
  end

  # ORG-GRAPH.5: with a comparison date, who joined a post since then is
  # marked, and who left one is drawn faded.
  defp people(data, post_unit, unit_ids, on?) do
    changes = Map.get(data, :changes) || %{joined: MapSet.new(), left: []}

    person_nodes(data, changes) ++
      hold_edges(data, changes, post_unit, unit_ids, on?) ++
      if(on?.("deputies"), do: deputy_edges(data.deputies), else: [])
  end

  defp person_nodes(data, %{joined: joined, left: left}) do
    current = MapSet.new(data.holders, &elem(&1, 0))

    newcomers =
      for {person, _} = pair <- data.holders,
          MapSet.member?(joined, pair),
          into: MapSet.new(),
          do: person

    (data.holders ++ left)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      classes =
        cond do
          not MapSet.member?(current, id) -> ["left"]
          MapSet.member?(newcomers, id) -> ["joined"]
          true -> []
        end

      node("h:" <> id, Person.full_name(data.people[id]), "person", %{}, classes)
    end)
  end

  defp hold_edges(data, %{joined: joined, left: left}, post_unit, unit_ids, on?) do
    marked =
      Enum.map(data.holders, &{&1, if(MapSet.member?(joined, &1), do: ["joined"], else: [])}) ++
        Enum.map(left, &{&1, ["left"]})

    marked
    |> Enum.flat_map(fn {{person, post}, classes} ->
      case hold_source(post, post_unit, unit_ids, on?) do
        nil -> []
        source -> [edge(source, "h:" <> person, "holds", classes)]
      end
    end)
    |> Enum.uniq_by(& &1.data.id)
  end

  # A holder hangs on the post, or on its unit when posts are hidden.
  defp hold_source(post, post_unit, unit_ids, on?) do
    cond do
      on?.("posts") -> "p:" <> post
      on?.("units") and MapSet.member?(unit_ids, post_unit[post]) -> "u:" <> post_unit[post]
      true -> nil
    end
  end

  defp deputy_edges(deputies),
    do: Enum.map(deputies, fn {from, to} -> edge("h:" <> to, "h:" <> from, "deputy") end)

  defp providers(providers, unit_ids, on?) do
    Enum.flat_map(providers, fn provider ->
      place = place_id(provider)

      [
        node("c:" <> provider.id, provider.name, "provider", %{
          provider_type: to_string(provider.provider_type)
        }),
        on?.("units") && provider.organization_id &&
          MapSet.member?(unit_ids, provider.organization_id) &&
          edge("c:" <> provider.id, "u:" <> provider.organization_id, "serves"),
        on?.("places") && place && node(place, place_label(provider), "place"),
        on?.("places") && place && edge("c:" <> provider.id, place, "located_in")
      ]
      |> Enum.filter(& &1)
    end)
    |> Enum.uniq_by(& &1.data.id)
  end

  @doc """
  ORG-GRAPH.7: the part of `elements` to send when only the `opened`
  units show their contents — every unit; a unit's posts, their holders,
  its care providers and their dependants only when it is opened (a
  person shows when any of their posts' units is); places and edges when
  both ends are sent. A unit not opened gets `remote` (how many of its
  own posts and holders wait) and the class `remote`.
  """
  @spec subgraph([map()], map(), MapSet.t()) :: [map()]
  def subgraph(elements, data, opened) do
    post_unit = Map.new(data.posts, &{"p:" <> &1.id, &1.organization_id})

    ctx = %{
      open?: &MapSet.member?(opened, &1),
      post_unit: post_unit,
      provider_unit: Map.new(data.providers, &{"c:" <> &1.id, &1.organization_id}),
      person_units:
        Enum.group_by(data.holders, &("h:" <> elem(&1, 0)), &post_unit["p:" <> elem(&1, 1)])
    }

    kept = kept_ids(elements, ctx)
    waiting = remote_counts(data, post_unit, ctx.open?)
    Enum.flat_map(elements, &sent(&1, kept, waiting))
  end

  # The nodes sent: units, the opened units' contents, then what links to
  # them only (places, dependants).
  defp kept_ids(elements, ctx) do
    nodes = Enum.filter(elements, &(not Map.has_key?(&1.data, :source)))
    first = MapSet.new(for n <- nodes, keep(n, ctx) == true, do: n.data.id)

    linked =
      for %{data: %{source: s, target: t}} <- elements,
          MapSet.member?(first, s) or MapSet.member?(first, t),
          into: MapSet.new(),
          do: if(MapSet.member?(first, s), do: t, else: s)

    MapSet.union(
      first,
      MapSet.new(
        for n <- nodes, keep(n, ctx) == :later, MapSet.member?(linked, n.data.id), do: n.data.id
      )
    )
  end

  defp keep(%{data: %{type: "unit"}}, _ctx), do: true
  defp keep(%{data: %{type: "post", id: id}}, ctx), do: ctx.open?.(ctx.post_unit[id])

  defp keep(%{data: %{type: "person", id: id}}, ctx),
    do: Enum.any?(ctx.person_units[id] || [], ctx.open?)

  defp keep(%{data: %{type: "provider", id: id}}, ctx),
    do: is_nil(ctx.provider_unit[id]) or ctx.open?.(ctx.provider_unit[id])

  defp keep(_node, _ctx), do: :later

  defp sent(%{data: %{source: s, target: t}} = edge, kept, _waiting),
    do: if(MapSet.member?(kept, s) and MapSet.member?(kept, t), do: [edge], else: [])

  defp sent(%{data: %{type: "unit", id: "u:" <> id}} = unit, _kept, waiting) do
    case waiting[id] do
      n when is_integer(n) and n > 0 ->
        [unit |> put_in([:data, :remote], n) |> add_classes(["remote"])]

      _ ->
        [unit]
    end
  end

  defp sent(%{data: %{id: id}} = node, kept, _waiting),
    do: if(MapSet.member?(kept, id), do: [node], else: [])

  # Per unit not opened: its own posts and their holders.
  defp remote_counts(data, post_unit, open?) do
    holders = Enum.frequencies_by(data.holders, &post_unit["p:" <> elem(&1, 1)])

    data.posts
    |> Enum.frequencies_by(& &1.organization_id)
    |> Enum.reject(fn {unit, _} -> open?.(unit) end)
    |> Map.new(fn {unit, posts} -> {unit, posts + Map.get(holders, unit, 0)} end)
  end

  @doc """
  Lays an overlay (`App.OrgGraph.Overlay`, ORG-GRAPH.6) over `elements`:
  a person gets the class `ov-<value>` (`ov-none` without one; with
  `absence`, also `ov-away`), a unit its vacant places (`vacant_total`,
  class `has-vacancies`).
  """
  @spec overlay([map()], String.t() | nil, map()) :: [map()]
  def overlay(elements, nil, _values), do: elements

  def overlay(elements, name, %{people: people, units: units}) do
    Enum.map(elements, fn
      %{data: %{type: "person", id: "h:" <> id}} = el ->
        add_classes(el, person_classes(name, people[id]))

      %{data: %{type: "unit", id: "u:" <> id}} = el when name == "vacancies" ->
        n = Map.get(units, id, 0)
        el = put_in(el, [:data, :vacant_total], n)
        if n > 0, do: add_classes(el, ["has-vacancies"]), else: el

      el ->
        el
    end)
  end

  defp person_classes("vacancies", _value), do: []
  defp person_classes(_name, nil), do: ["ov-none"]
  defp person_classes("absence", type), do: ["ov-away", "ov-" <> css(type)]
  defp person_classes(_name, value), do: ["ov-" <> css(value)]

  defp css(value), do: value |> to_string() |> String.replace(~r/[^a-z0-9_]/, "_")

  defp add_classes(el, []), do: el
  defp add_classes(el, classes), do: %{el | classes: Enum.join([el.classes | classes], " ")}

  # ORG-GRAPH.4: relations between people (counted), referrals to care
  # providers, dependants as their own nodes.
  defp relations(relations, data, on?) do
    providers = MapSet.new(data.providers, & &1.id)

    [
      counted(relations, :duty, "duty_with", on?),
      counted(relations, :approvals, "approves", on?),
      counted(relations, :acknowledgements, "acknowledged", on?),
      if(on?.("referrals") and on?.("providers"),
        do:
          for(
            {person, provider} <- Map.get(relations, :referrals, []),
            MapSet.member?(providers, provider),
            do: edge("h:" <> person, "c:" <> provider, "referred")
          ),
        else: []
      ),
      if(on?.("family"),
        do:
          Enum.flat_map(Map.get(relations, :family, []), fn dependant ->
            [
              node("d:" <> dependant.id, dependant.name || "—", "relative", %{
                relationship: dependant.relationship
              }),
              edge("h:" <> dependant.person_id, "d:" <> dependant.id, "family")
            ]
          end),
        else: []
      )
    ]
  end

  defp counted(relations, key, type, on?) do
    if on?.(to_string(key)) do
      for {from, to, n} <- Map.get(relations, key, []) do
        put_in(edge("h:" <> from, "h:" <> to, type), [:data, :count], n)
      end
    else
      []
    end
  end

  @doc """
  The place node a unit or provider is located in (by country and
  locality), or nil. Units and providers in the same locality share it.
  """
  @spec place_id(map()) :: String.t() | nil
  def place_id(%{locality: locality} = located) when is_binary(locality) and locality != "",
    do: "l:" <> (located.country || "") <> ":" <> String.downcase(String.trim(locality))

  def place_id(_located), do: nil

  @doc "A place's label: \"Locality, CC\"."
  @spec place_label(map()) :: String.t()
  def place_label(located),
    do: Enum.join(Enum.reject([located.locality, located.country], &(&1 in [nil, ""])), ", ")

  @doc """
  Where a unit is (ORG-GRAPH.1): its own place, or the nearest parent
  unit's — `{unit_with_the_place, place_label}`, or nil. `units` are the
  units on the graph.
  """
  @spec unit_place(String.t() | nil, [map()]) :: {map(), String.t()} | nil
  def unit_place(unit_id, units), do: unit_place(unit_id, Map.new(units, &{&1.id, &1}), 0)

  defp unit_place(nil, _by_id, _depth), do: nil
  defp unit_place(_id, _by_id, depth) when depth > 100, do: nil

  defp unit_place(id, by_id, depth) do
    case by_id[id] do
      nil ->
        nil

      unit ->
        if place_id(unit),
          do: {unit, place_label(unit)},
          else: unit_place(unit.parent_id, by_id, depth + 1)
    end
  end

  defp node(id, label, type, extra \\ %{}, classes \\ []) do
    %{
      data: Map.merge(%{id: id, label: label, type: type}, extra),
      classes: Enum.join([type | classes], " ")
    }
  end

  defp edge(source, target, type, classes \\ []) do
    %{
      data: %{id: "#{type}:#{source}>#{target}", source: source, target: target, type: type},
      classes: Enum.join([type | classes], " ")
    }
  end
end
