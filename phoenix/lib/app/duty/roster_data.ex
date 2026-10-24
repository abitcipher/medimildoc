defmodule App.Duty.RosterData do
  @moduledoc """
  What a roster page shows (docs/design/duty-roster.md): the unit's members
  and absences (`App.Leave.CalendarData`, read as the viewer) and the
  shifts of those members in the period, read as the viewer.
  """
  require Ash.Query

  alias App.Duty.Shift
  alias App.Leave.CalendarData

  @spec load(String.t(), Date.t(), Date.t(), map()) :: %{
          members: [map()],
          absences: [map()],
          shifts: [map()]
        }
  def load(unit, from, to, actor) do
    %{members: members, absences: absences} = CalendarData.load(unit, from, to, actor)
    ids = Enum.map(members, & &1.person_id)

    shifts =
      Shift
      |> Ash.Query.filter(person_id in ^ids and date >= ^from and date <= ^to)
      |> Ash.read!(actor: actor)

    %{members: members, absences: absences, shifts: shifts}
  end

  @doc "How many duties `person_id` has from `first` to `last` (read as the system: a count)."
  @spec count(String.t() | nil, Date.t(), Date.t()) :: non_neg_integer()
  def count(nil, _first, _last), do: 0

  def count(person_id, first, last) do
    Shift
    |> Ash.Query.filter(person_id == ^person_id and date >= ^first and date <= ^last)
    |> Ash.count!(authorize?: false)
  end
end
