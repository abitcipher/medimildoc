defmodule App.Documents.Route do
  @moduledoc """
  Which steps of a round become pending (docs/design/parallel-approval.md).
  Pure: steps are maps with `position`, `stage`, `parallel` and `status`.

  A round runs stage by stage in position order. A parallel stage's steps
  are pending together and decided in any order; the next stage starts
  only when none of the round is pending any more.
  """

  @doc """
  The positions to make pending now: none while a step of the round is
  still pending; otherwise the first waiting step — with every waiting step
  of its stage when that stage is parallel.
  """
  @spec next_active([map()]) :: [pos_integer()]
  def next_active(steps) do
    if Enum.any?(steps, &(&1.status == :pending)),
      do: [],
      else:
        steps |> Enum.filter(&(&1.status == :waiting)) |> Enum.sort_by(& &1.position) |> start()
  end

  defp start([]), do: []

  defp start([%{parallel: true, stage: stage} | _] = waiting),
    do: waiting |> Enum.filter(&(&1.stage == stage)) |> Enum.map(& &1.position)

  defp start([first | _]), do: [first.position]
end
