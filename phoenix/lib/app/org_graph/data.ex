defmodule App.OrgGraph.Data do
  @moduledoc """
  What the org graph shows (docs/design/org-graph.md, task ORG-GRAPH),
  read as the viewer: units (the whole tree or one unit and everything
  under it), their posts, who currently holds each post, care providers
  attached to the units, and current deputies. People the viewer may not
  read are left out (only the vacant post shows); deputies are visible to
  the two people involved and to user managers, as everywhere else.
  """

  require Ash.Query

  alias App.Access.Unit
  alias App.Accounts.User
  alias App.Care.Provider
  alias App.Documents.Deputy
  alias App.OrgGraph.Relations
  alias App.People.{Assignment, Organization, Person, Position}

  @type t :: %{
          units: [Organization.t()],
          posts: [Position.t()],
          holders: [{String.t(), String.t()}],
          people: %{String.t() => Person.t()},
          providers: [Provider.t()],
          deputies: [{String.t(), String.t()}],
          relations: Relations.t(),
          on: Date.t(),
          changes: %{joined: MapSet.t(), left: [{String.t(), String.t()}], since: Date.t()} | nil
        }

  @doc """
  The graph's data under `root` (a unit id, or nil for every unit).
  Options: `relations` — the relation layers to load too (ORG-GRAPH.4,
  `App.OrgGraph.Relations`); `on` — the date the holders and deputies are
  read for (ORG-GRAPH.5, default today; units and posts have no history
  yet and show as they are); `compare` — another date: who joined or left
  the posts between it and `on` (`changes`).
  """
  @spec load(String.t() | nil, map(), keyword()) :: t()
  def load(root, actor, opts \\ []) do
    on = Keyword.get(opts, :on) || Date.utc_today()
    units = units(root, actor)
    unit_ids = Enum.map(units, & &1.id)

    posts =
      Position
      |> Ash.Query.filter(organization_id in ^unit_ids)
      |> Ash.read!(actor: actor)

    post_ids = Enum.map(posts, & &1.id)
    holders = holders(post_ids, on, actor)
    before = if compare = opts[:compare], do: holders(post_ids, compare, actor), else: []
    people = people(Enum.map(holders ++ before, &elem(&1, 0)), actor)

    readable = fn list ->
      Enum.filter(list, fn {person, _post} -> Map.has_key?(people, person) end)
    end

    holders = readable.(holders)

    %{
      units: units,
      posts: posts,
      holders: holders,
      people: people,
      providers: providers(root, unit_ids, actor),
      deputies: deputies(people, actor, on),
      on: on,
      changes: compare && changes(holders, readable.(before), compare),
      relations: Relations.load(Keyword.get(opts, :relations, []), Map.keys(people), actor)
    }
  end

  # Who held which post on `date` (assignment history).
  defp holders(post_ids, date, actor) do
    Assignment
    |> Ash.Query.filter(
      position_id in ^post_ids and starts_on <= ^date and (is_nil(ends_on) or ends_on >= ^date)
    )
    |> Ash.Query.select([:person_id, :position_id])
    |> Ash.read!(actor: actor)
    |> Enum.map(&{&1.person_id, &1.position_id})
    |> Enum.uniq()
  end

  # Between `since` and the graph's date: holders who joined a post, and
  # those who left one (they are shown faded, ORG-GRAPH.5).
  defp changes(now, before, since) do
    now_set = MapSet.new(now)
    before_set = MapSet.new(before)

    %{
      joined: MapSet.difference(now_set, before_set),
      left: before_set |> MapSet.difference(now_set) |> MapSet.to_list(),
      since: since
    }
  end

  defp units(nil, actor), do: Ash.read!(Organization, actor: actor)

  defp units(root, actor) do
    ids = Unit.subtree_ids(root)

    Organization
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(actor: actor)
  end

  defp people([], _actor), do: %{}

  defp people(ids, actor) do
    Person
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.id, &1})
  end

  # Every provider for the whole tree; under one unit, those attached to it.
  defp providers(nil, _unit_ids, actor), do: Ash.read!(Provider, actor: actor)

  defp providers(_root, unit_ids, actor) do
    Provider
    |> Ash.Query.filter(organization_id in ^unit_ids)
    |> Ash.read!(actor: actor)
  end

  # Current deputies as {person, their deputy}, both people on the graph.
  defp deputies(people, _actor, _on) when map_size(people) == 0, do: []

  defp deputies(people, actor, on) do
    deputies =
      Deputy
      |> Ash.Query.filter(starts_on <= ^on and (is_nil(ends_on) or ends_on >= ^on))
      |> Ash.read!(actor: actor)

    user_ids = Enum.flat_map(deputies, &[&1.user_id, &1.deputy_id]) |> Enum.uniq()

    # Only which person each account belongs to; shown only when both
    # people are readable (they are on the graph).
    person_of =
      User
      |> Ash.Query.filter(id in ^user_ids and not is_nil(person_id))
      |> Ash.Query.select([:id, :person_id])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.person_id})

    for deputy <- deputies,
        from = person_of[deputy.user_id],
        to = person_of[deputy.deputy_id],
        Map.has_key?(people, from) and Map.has_key?(people, to),
        uniq: true,
        do: {from, to}
  end
end
