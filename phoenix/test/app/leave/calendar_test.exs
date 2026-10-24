defmodule App.Leave.CalendarTest do
  @moduledoc "docs/design/leave-calendar.md: who is away, and when that is too many."
  use ExUnit.Case, async: true

  alias App.Leave.Calendar

  defp member(id, leader? \\ false), do: %{person_id: id, leader?: leader?}

  defp away(id, first, last, pending? \\ false),
    do: %{person_id: id, type: "annual", first: first, last: last, pending?: pending?}

  test "the limit is a share of the unit, but one person may always be away" do
    assert Calendar.limit(10, 30) == 3
    assert Calendar.limit(3, 30) == 1
    assert Calendar.limit(0, 30) == 1
    assert Calendar.limit(7, 50) == 3
  end

  test "days count people away (pending too), flag too many and several leaders" do
    members = [member("a", true), member("b", true), member("c"), member("d"), member("e")]

    absences = [
      away("a", ~D[2026-11-02], ~D[2026-11-04]),
      away("b", ~D[2026-11-03], ~D[2026-11-05], true),
      # Two absences of one person on a day count once.
      away("c", ~D[2026-11-04], ~D[2026-11-04]),
      away("c", ~D[2026-11-04], ~D[2026-11-06])
    ]

    days = Calendar.days(members, absences, Date.range(~D[2026-11-01], ~D[2026-11-06]), 30)
    by_day = Map.new(days, &{&1.date.day, &1})

    # 5 people, 30 % → limit 1.
    assert by_day[1].away == 0 and not by_day[1].over?
    assert by_day[2].away == 1 and not by_day[2].over?
    assert %{away: 2, pending: 1, leaders_away: 2, over?: true, leaders?: true} = by_day[3]
    assert %{away: 3, over?: true} = by_day[4]
    assert %{away: 2, leaders_away: 1, leaders?: false} = by_day[5]

    conflicts = Calendar.conflicts(days)

    assert [
             %{
               from: ~D[2026-11-03],
               to: ~D[2026-11-04],
               over?: true,
               leaders?: true,
               max_away: 3
             },
             %{from: ~D[2026-11-05], to: ~D[2026-11-05], over?: true, leaders?: false}
           ] = conflicts
  end

  test "a leave's load on the unit counts the others, never the person themselves" do
    members = Enum.map(~w(a b c d e f g h i j), &member/1)

    absences = [
      away("a", ~D[2026-11-01], ~D[2026-11-10]),
      away("b", ~D[2026-11-05], ~D[2026-11-06]),
      away("c", ~D[2026-11-05], ~D[2026-11-05]),
      # The person's own other leave doesn't count.
      away("z", ~D[2026-11-01], ~D[2026-11-30])
    ]

    assert %{others_away: 3, limit: 3, over?: true, unit_size: 10} =
             Calendar.load_for(members, absences, "z", ~D[2026-11-04], ~D[2026-11-05], 30)

    assert %{others_away: 1, over?: false} =
             Calendar.load_for(members, absences, "z", ~D[2026-11-07], ~D[2026-11-08], 30)
  end

  test "month days" do
    assert length(Calendar.month_days(~D[2026-02-14])) == 28
    assert hd(Calendar.month_days(~D[2026-10-31])) == ~D[2026-10-01]
  end
end
