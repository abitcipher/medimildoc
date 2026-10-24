defmodule App.Duty.Roster do
  @moduledoc """
  A roster's checks (docs/design/duty-roster.md), pure: shifts are maps
  with `person_id`, `date`, `duty_type`; absences as
  `App.Leave.CalendarData` gives them (`person_id`, `first`, `last`).

  - `:away` — on duty on a day of leave, sick leave or a business trip
    (recorded or on its way);
  - `:no_rest` — two duties of one person closer than the rest the duty
    types require (`App.Duty.Types.min_rest_days/0`);
  - coverage — per day, duty types with fewer people than they need.
  """

  alias App.Duty.Types

  @doc "Problems of each shift: `%{shift_key => [:away | :no_rest]}`; key `{person_id, date}`."
  @spec problems([map()], [map()], non_neg_integer()) :: %{{String.t(), Date.t()} => [atom()]}
  def problems(shifts, absences, min_rest \\ Types.min_rest_days()) do
    by_person = Enum.group_by(shifts, & &1.person_id)

    shifts
    |> Enum.map(fn shift ->
      found =
        Enum.filter(
          [
            away: away?(shift, absences),
            no_rest: too_close?(shift, Map.get(by_person, shift.person_id, []), min_rest)
          ],
          &elem(&1, 1)
        )

      {{shift.person_id, shift.date}, Keyword.keys(found)}
    end)
    |> Enum.reject(fn {_key, found} -> found == [] end)
    |> Map.new()
  end

  @doc """
  Days of `dates` where a duty type has fewer people than it needs:
  `%{date => [{type_id, have, need}]}` (days fully covered left out).
  """
  @spec gaps([map()], [Date.t()], [map()]) :: %{Date.t() => [{String.t(), integer(), integer()}]}
  def gaps(shifts, dates, types \\ Types.all()) do
    counts = Enum.frequencies_by(shifts, &{&1.date, &1.duty_type})

    dates
    |> Enum.map(fn date ->
      missing =
        for type <- types,
            have = Map.get(counts, {date, type["id"]}, 0),
            have < type["per_day"],
            do: {type["id"], have, type["per_day"]}

      {date, missing}
    end)
    |> Enum.reject(fn {_date, missing} -> missing == [] end)
    |> Map.new()
  end

  defp away?(shift, absences) do
    Enum.any?(absences, fn a ->
      a.person_id == shift.person_id and Date.compare(shift.date, a.first) != :lt and
        Date.compare(shift.date, a.last) != :gt
    end)
  end

  defp too_close?(shift, own, min_rest) do
    Enum.any?(own, fn other ->
      other.date != shift.date and abs(Date.diff(other.date, shift.date)) <= min_rest
    end)
  end
end
