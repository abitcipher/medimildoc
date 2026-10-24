defmodule App.Leave.CalendarData do
  @moduledoc """
  What `App.Leave.Calendar` works on (docs/design/leave-calendar.md): the
  people currently assigned in a unit (with its sub-units) — each marked
  `leader?` when their post is one others report to — and their absences
  overlapping a period: recorded leave (`leave` records; sick leave
  included) and business trips (`business_trip` records, type `"trip"`,
  docs/design/business-trips.md), and those on their way (a leave request
  in approval, a leave or business-trip order not signed yet).

  Read as the viewer (`actor:`) for the calendar, so it shows only what
  they may read; or as the system (`actor: :system`) for the counts shown
  on a leave request, which name nobody. Leave records are found by their
  plain start date (`effective_on`) and decrypted only then; leave is not
  a sensitive category, so nothing goes to the access log.
  """

  require Ash.Query

  alias App.Access.Unit
  alias App.Documents.Document
  alias App.Leave.Calendar
  alias App.People.{Assignment, Person, PersonRecord, Position}

  # How far back a leave may have started and still reach the period.
  @reach_days 400

  @doc """
  Members and absences of the unit `org_id` from `from` to `to`.
  `actor` is a user or `:system`.
  """
  @spec load(String.t(), Date.t(), Date.t(), map() | :system) :: %{
          members: [map()],
          absences: [map()]
        }
  def load(org_id, from, to, actor) do
    members = members(Unit.subtree_ids(org_id), actor)
    %{members: members, absences: absences(Enum.map(members, & &1.person_id), from, to, actor)}
  end

  @doc "The unit a person is currently assigned in (their post's organization), or nil."
  @spec unit_of(String.t()) :: String.t() | nil
  def unit_of(person_id) do
    Assignment
    |> Ash.Query.filter(person_id == ^person_id and is_nil(ends_on))
    |> Ash.Query.load(:position)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{position: %{organization_id: org_id}}] -> org_id
      _ -> nil
    end
  end

  defp members(org_ids, actor) do
    assignments =
      Assignment
      |> Ash.Query.filter(is_nil(ends_on) and position.organization_id in ^org_ids)
      |> Ash.Query.load([:person, position: [:organization]])
      |> read(actor)
      |> Enum.uniq_by(& &1.person_id)

    leaders = leader_posts(Enum.map(assignments, & &1.position_id))

    assignments
    |> Enum.map(fn assignment ->
      %{
        person_id: assignment.person_id,
        person: assignment.person,
        position: assignment.position,
        leader?: assignment.position_id in leaders
      }
    end)
    |> Enum.sort_by(&{not &1.leader?, Person.full_name(&1.person)})
  end

  # Posts that other posts report to (the structure is not personal data);
  # a few per unit, so a list.
  defp leader_posts([]), do: []

  defp leader_posts(position_ids) do
    Position
    |> Ash.Query.filter(reports_to_id in ^position_ids)
    |> Ash.Query.select([:reports_to_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.reports_to_id)
    |> Enum.uniq()
  end

  @doc """
  How many others of `person_id`'s unit are away during the leave in
  `data` (`startDate`, `endDate`), against the limit
  (`App.Leave.Calendar.load_for/6`); nil without a unit or valid dates.
  Read as the system: only counts, never who. A request being decided is
  left out (it is on its way, so it would count twice).
  """
  @spec unit_load(String.t() | nil, map()) :: map() | nil
  def unit_load(person_id, data) do
    with unit when is_binary(unit) <- unit_of(person_id),
         {:ok, first} <- Date.from_iso8601(data["startDate"] || ""),
         {:ok, last} <- Date.from_iso8601(data["endDate"] || ""),
         true <- Date.compare(last, first) != :lt do
      %{members: members, absences: absences} = load(unit, first, last, :system)

      Calendar.load_for(
        members,
        absences,
        person_id,
        first,
        last,
        App.Settings.get("leave.max_away_percent")
      )
    else
      _ -> nil
    end
  end

  @doc """
  Which of `person_ids` are away on `date` — recorded leave or business
  trip, not leave on its way (read as the system; for stand-ins,
  docs/design/inbox-first.md).
  """
  @spec away_on([String.t()], Date.t()) :: [String.t()]
  def away_on(person_ids, date) do
    person_ids
    |> Enum.reject(&is_nil/1)
    |> absences(date, date, :system)
    |> Enum.reject(& &1.pending?)
    |> Enum.map(& &1.person_id)
    |> Enum.uniq()
  end

  @doc """
  Who of `person_ids` is away on `date` and how (`%{person_id => type}`:
  a leave type, `"sick"`, or `"trip"`), recorded only, read as `actor`
  (the org graph's overlay, ORG-GRAPH.6).
  """
  @spec away_types([String.t()], Date.t(), map()) :: %{String.t() => String.t()}
  def away_types(person_ids, date, actor) do
    person_ids
    |> Enum.reject(&is_nil/1)
    |> absences(date, date, actor)
    |> Enum.reject(& &1.pending?)
    |> Map.new(&{&1.person_id, &1.type})
  end

  defp absences([], _from, _to, _actor), do: []

  defp absences(person_ids, from, to, actor) do
    earliest = Date.add(from, -@reach_days)

    recorded =
      PersonRecord
      |> Ash.Query.filter(
        person_id in ^person_ids and kind in [:leave, :business_trip] and
          effective_on <= ^to and effective_on >= ^earliest
      )
      |> Ash.Query.load(:data)
      |> read(actor)
      |> Enum.map(&absence(&1.person_id, type_data(&1.kind, &1.data), false))

    pending =
      Document
      |> Ash.Query.filter(
        person_id in ^person_ids and
          ((type in [:leave_request, :business_trip_request] and state == :in_review) or
             (type in [:personnel_order_leave, :personnel_order_business_trip] and
                state in [:draft, :in_review]))
      )
      |> Ash.Query.load(:data)
      |> read(actor)
      |> Enum.map(&absence(&1.person_id, type_data(&1.type, &1.data), true))

    (recorded ++ pending)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(Date.compare(&1.first, to) != :gt and Date.compare(&1.last, from) != :lt))
  end

  # A business trip (record or order) is away as the type "trip".
  defp type_data(kind, %{} = data)
       when kind in [:business_trip, :business_trip_request, :personnel_order_business_trip],
       do: Map.put(data, "leaveType", "trip")

  defp type_data(_kind, data), do: data

  defp absence(person_id, data, pending?) do
    with %{} <- data,
         {:ok, first} <- Date.from_iso8601(data["startDate"] || ""),
         {:ok, last} <- Date.from_iso8601(data["endDate"] || ""),
         true <- Date.compare(last, first) != :lt do
      %{
        person_id: person_id,
        type: data["leaveType"],
        first: first,
        last: last,
        pending?: pending?
      }
    else
      _ -> nil
    end
  end

  defp read(query, :system), do: Ash.read!(query, authorize?: false)
  defp read(query, actor), do: Ash.read!(query, actor: actor)
end
