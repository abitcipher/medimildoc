defmodule App.Duty.RosterTest do
  @moduledoc "docs/design/duty-roster.md: the roster's checks (pure)."
  use ExUnit.Case, async: true

  alias App.Duty.Roster

  defp shift(person, day, type \\ "duty_officer"),
    do: %{person_id: person, date: Date.new!(2026, 11, day), duty_type: type}

  test "a duty on a day away; two duties without a day of rest" do
    absences = [%{person_id: "a", first: ~D[2026-11-03], last: ~D[2026-11-05]}]
    shifts = [shift("a", 4), shift("b", 1), shift("b", 2), shift("c", 1), shift("c", 3)]

    assert Roster.problems(shifts, absences, 1) == %{
             {"a", ~D[2026-11-04]} => [:away],
             {"b", ~D[2026-11-01]} => [:no_rest],
             {"b", ~D[2026-11-02]} => [:no_rest]
           }

    # With no rest required, c and b are fine.
    assert Roster.problems(shifts, absences, 0) == %{{"a", ~D[2026-11-04]} => [:away]}
  end

  test "days short of people per duty type" do
    types = [%{"id" => "duty_officer", "per_day" => 1}, %{"id" => "orderly", "per_day" => 2}]
    shifts = [shift("a", 1), shift("b", 1, "orderly"), shift("c", 1, "orderly"), shift("d", 2)]

    assert Roster.gaps(shifts, [~D[2026-11-01], ~D[2026-11-02]], types) == %{
             ~D[2026-11-02] => [{"orderly", 0, 2}]
           }
  end
end
