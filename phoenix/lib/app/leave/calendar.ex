defmodule App.Leave.Calendar do
  @moduledoc """
  Who of a unit is away when, and when that is too many
  (docs/design/leave-calendar.md). Pure: the members of a unit and their
  absences go in (`App.Leave.CalendarData` reads them), days, cells and
  conflicts come out.

  An absence is recorded leave of any type (sick leave included) or leave
  on its way (a request in approval, a leave order not signed yet:
  `pending?`). Both count as away — the calendar is for planning.

  Two conflicts on a day:

  - **too many away**: more than the limit — `max_away_percent` of the
    unit, but always at least one person;
  - **leaders away**: two or more holders of key posts are away; a key
    post is one that other posts report to (`leader?`).
  """

  @type member :: %{person_id: String.t(), leader?: boolean()}
  @type absence :: %{
          person_id: String.t(),
          type: String.t() | nil,
          first: Date.t(),
          last: Date.t(),
          pending?: boolean()
        }

  @doc "Every day of the month `date` is in."
  @spec month_days(Date.t()) :: [Date.t()]
  def month_days(date),
    do: Date.range(Date.beginning_of_month(date), Date.end_of_month(date)) |> Enum.to_list()

  @doc "How many of a unit of `size` may be away at once (at least one)."
  @spec limit(non_neg_integer(), number()) :: pos_integer()
  def limit(size, percent), do: max(1, floor(size * percent / 100))

  @doc "The absences of `person_id` on `date`."
  @spec on(Date.t(), [absence()], String.t() | nil) :: [absence()]
  def on(date, absences, person_id \\ nil) do
    Enum.filter(
      absences,
      &((is_nil(person_id) or &1.person_id == person_id) and
          Date.compare(&1.first, date) != :gt and Date.compare(&1.last, date) != :lt)
    )
  end

  @doc """
  Each day of `dates` for the unit: how many members are away (pending
  among them), leaders away, the limit, and the two conflict flags.
  """
  @spec days([member()], [absence()], [Date.t()], number()) :: [map()]
  def days(members, absences, dates, percent) do
    limit = limit(length(members), percent)
    leaders = members |> Enum.filter(& &1.leader?) |> MapSet.new(& &1.person_id)

    for date <- dates do
      away = absences |> then(&on(date, &1)) |> Enum.uniq_by(& &1.person_id)
      pending = Enum.count(away, & &1.pending?)
      leaders_away = Enum.count(away, &MapSet.member?(leaders, &1.person_id))

      %{
        date: date,
        away: length(away),
        pending: pending,
        leaders_away: leaders_away,
        limit: limit,
        over?: length(away) > limit,
        leaders?: leaders_away >= 2
      }
    end
  end

  @doc """
  Conflicting days joined into runs: `%{from, to, over?, leaders?,
  max_away, limit}` for consecutive days with the same flags.
  """
  @spec conflicts([map()]) :: [map()]
  def conflicts(days) do
    days
    |> Enum.filter(&(&1.over? or &1.leaders?))
    |> Enum.chunk_while(
      nil,
      fn day, run ->
        cond do
          is_nil(run) ->
            {:cont, start_run(day)}

          Date.diff(day.date, run.to) == 1 and day.over? == run.over? and
              day.leaders? == run.leaders? ->
            {:cont, %{run | to: day.date, max_away: max(run.max_away, day.away)}}

          true ->
            {:cont, run, start_run(day)}
        end
      end,
      fn
        nil -> {:cont, nil}
        run -> {:cont, run, nil}
      end
    )
  end

  defp start_run(day),
    do: %{
      from: day.date,
      to: day.date,
      over?: day.over?,
      leaders?: day.leaders?,
      max_away: day.away,
      limit: day.limit
    }

  @doc """
  For a leave of `person_id` from `first` to `last`: the most others of
  the unit away on one of those days, the limit, and whether this leave
  would take a day over it. Only counts — no names.
  """
  @spec load_for([member()], [absence()], String.t(), Date.t(), Date.t(), number()) :: map()
  def load_for(members, absences, person_id, first, last, percent) do
    limit = limit(length(members), percent)
    others = Enum.reject(absences, &(&1.person_id == person_id))

    most =
      Date.range(first, last)
      |> Enum.map(fn date ->
        others |> then(&on(date, &1)) |> Enum.uniq_by(& &1.person_id) |> length()
      end)
      |> Enum.max(fn -> 0 end)

    %{others_away: most, limit: limit, over?: most + 1 > limit, unit_size: length(members)}
  end
end
