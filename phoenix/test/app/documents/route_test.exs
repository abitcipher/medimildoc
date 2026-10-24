defmodule App.Documents.RouteTest do
  @moduledoc "docs/design/parallel-approval.md: which steps become pending."
  use ExUnit.Case, async: true

  alias App.Documents.Route

  defp step(position, stage, status, parallel \\ false),
    do: %{position: position, stage: stage, status: status, parallel: parallel}

  test "one by one: the first waiting step" do
    assert Route.next_active([step(1, 1, :waiting), step(2, 2, :waiting)]) == [1]
    assert Route.next_active([step(1, 1, :approved), step(2, 2, :waiting)]) == [2]
  end

  test "a parallel stage starts all at once and ends when nobody of it is pending" do
    steps = [step(1, 1, :waiting, true), step(2, 1, :waiting, true), step(3, 2, :waiting)]
    assert Route.next_active(steps) == [1, 2]

    assert Route.next_active([
             step(1, 1, :approved, true),
             step(2, 1, :pending, true),
             step(3, 2, :waiting)
           ]) == []

    assert Route.next_active([
             step(1, 1, :approved, true),
             step(2, 1, :approved, true),
             step(3, 2, :waiting)
           ]) == [3]
  end

  test "nothing left" do
    assert Route.next_active([step(1, 1, :signed)]) == []
  end
end
