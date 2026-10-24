defmodule App.OrgGraph.Overlay do
  @moduledoc """
  ORG-GRAPH.6 (docs/design/org-graph.md): a status laid over the org
  graph, one at a time, read as the viewer:

  - `readiness` — each person's latest fitness-for-duty status (records of
    the readiness category: only for those who may read them; decrypting
    them is logged like everywhere);
  - `absence` — who is away on the graph's date: leave (sick leave
    included) or a business trip, recorded (`App.Leave.CalendarData`);
  - `vacancies` — vacant places per unit, its sub-units included (pure).

  Returns `%{people: %{person_id => value}, units: %{unit_id => count}}`.
  """
  require Ash.Query

  alias App.Leave.CalendarData
  alias App.People.PersonRecord

  @overlays ~w(readiness absence vacancies)

  @doc "The overlays, in the order the page lists them."
  @spec overlays() :: [String.t()]
  def overlays, do: @overlays

  @type t :: %{people: %{String.t() => String.t()}, units: %{String.t() => non_neg_integer()}}

  @doc "The overlay `name` for `data` (`App.OrgGraph.Data`), read as `actor`."
  @spec load(String.t() | nil, map(), map()) :: t()
  def load("readiness", data, actor) do
    statuses =
      PersonRecord
      |> Ash.Query.filter(kind == :fitness_for_duty and person_id in ^Map.keys(data.people))
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.read!(actor: actor)
      |> Enum.uniq_by(& &1.person_id)
      |> Map.new(&{&1.person_id, (&1.data || %{})["status"] || "unknown"})

    %{people: statuses, units: %{}}
  end

  def load("absence", data, actor),
    do: %{
      people: CalendarData.away_types(Map.keys(data.people), data.on, actor),
      units: %{}
    }

  def load("vacancies", data, _actor), do: %{people: %{}, units: vacancies(data)}
  def load(_none, _data, _actor), do: %{people: %{}, units: %{}}

  @doc "Vacant places per unit on the graph, counting its sub-units (pure)."
  @spec vacancies(map()) :: %{String.t() => non_neg_integer()}
  def vacancies(data) do
    held = Enum.frequencies_by(data.holders, &elem(&1, 1))

    own =
      data.posts
      |> Enum.group_by(& &1.organization_id)
      |> Map.new(fn {unit, posts} ->
        {unit, Enum.sum(Enum.map(posts, &max((&1.strength || 1) - Map.get(held, &1.id, 0), 0)))}
      end)

    children = Enum.group_by(data.units, & &1.parent_id, & &1.id)

    total = fn total, id ->
      Map.get(own, id, 0) + Enum.sum(Enum.map(children[id] || [], &total.(total, &1)))
    end

    Map.new(data.units, &{&1.id, total.(total, &1.id)})
  end
end
