defmodule App.Demo.Duty do
  @moduledoc """
  Demo duty roster (part of `App.Demo`, docs/design/duty-roster.md): this
  month for the commander's battalion — every duty type covered each day by
  members taken in turn, without random calls. Some land on days of leave,
  so the roster shows real conflicts.
  """

  alias App.Duty.{Shift, Types}
  alias App.Leave.{Calendar, CalendarData}

  @spec build([map()]) :: :ok
  def build(users) do
    commander = Enum.find(users, &String.starts_with?(to_string(&1.email), "commander@"))
    unit = commander && commander.person_id && CalendarData.unit_of(commander.person_id)
    if unit, do: plan(unit)
    :ok
  end

  defp plan(unit) do
    dates = Calendar.month_days(Date.utc_today())
    %{members: members} = CalendarData.load(unit, hd(dates), List.last(dates), :system)
    people = members |> Enum.map(& &1.person_id) |> Enum.sort()
    slots = Enum.flat_map(Types.all(), &List.duplicate(&1["id"], &1["per_day"]))
    count = length(people)

    if count > length(slots) do
      for {date, day} <- Enum.with_index(dates), {type, slot} <- Enum.with_index(slots) do
        person = Enum.at(people, rem(day * length(slots) + slot, count))

        Shift
        |> Ash.Changeset.for_create(
          :create,
          %{date: date, duty_type: type, person_id: person, organization_id: unit},
          authorize?: false
        )
        |> Ash.create!(authorize?: false)
      end
    end
  end
end
