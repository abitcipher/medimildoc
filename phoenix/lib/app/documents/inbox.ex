defmodule App.Documents.Inbox do
  @moduledoc """
  Deadlines and order of the inbox (docs/design/inbox-first.md). Pure: the
  documents come from `App.Documents.Queries.inbox/1` and `to_acknowledge/1`.

  A document's `due` is its own due date (scheduled drafts) or, for a step
  waiting for the viewer, the day the step became theirs plus the
  `documents.step_days` setting — whichever is earlier.
  """

  @soon_days 3

  @type urgency :: :overdue | :today | :soon | :later | nil
  @type item :: %{document: map(), reason: atom(), due: Date.t() | nil, urgency: urgency()}

  @doc "How urgent a due date is on `today`; nil without one."
  @spec urgency(Date.t() | nil, Date.t()) :: urgency()
  def urgency(nil, _today), do: nil

  def urgency(due, today) do
    case Date.diff(due, today) do
      days when days < 0 -> :overdue
      0 -> :today
      days when days <= @soon_days -> :soon
      _ -> :later
    end
  end

  @doc "The earlier of two optional dates."
  @spec earliest(Date.t() | nil, Date.t() | nil) :: Date.t() | nil
  def earliest(nil, date), do: date
  def earliest(date, nil), do: date
  def earliest(a, b), do: Enum.min([a, b], Date)

  @doc """
  When a step that became pending at `since` is due: `days` later
  (calendar days).
  """
  @spec step_due(DateTime.t(), pos_integer()) :: Date.t()
  def step_due(since, days), do: since |> DateTime.to_date() |> Date.add(days)

  @doc """
  Everything waiting for the viewer as one list, most urgent first:
  overdue, due today, soon, later, then undated — older first within each.
  `inbox` is `Queries.inbox/1`'s map; `to_acknowledge` its own list.
  """
  @spec items(map(), [map()], Date.t()) :: [item()]
  def items(inbox, to_acknowledge, today) do
    [
      {:to_acknowledge, to_acknowledge},
      {:to_decide, inbox.to_decide},
      {:instruction, Map.get(inbox, :instructions, [])},
      {:returned, Enum.filter(inbox.my_drafts, &Map.get(&1, :returned?))},
      {:team, inbox.team}
    ]
    |> Enum.flat_map(fn {reason, documents} ->
      Enum.map(documents, &item(&1, reason, today))
    end)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc "How many of `items` are overdue."
  @spec overdue([item()]) :: non_neg_integer()
  def overdue(items), do: Enum.count(items, &(&1.urgency == :overdue))

  defp item(document, reason, today) do
    due = Map.get(document, :due) || Map.get(document, :due_on)
    %{document: document, reason: reason, due: due, urgency: urgency(due, today)}
  end

  @ranks %{overdue: 0, today: 1, soon: 2, later: 3, nil: 4}

  defp sort_key(%{urgency: urgency, due: due, document: document}) do
    {Map.fetch!(@ranks, urgency), due && Date.to_gregorian_days(due),
     DateTime.to_unix(document.updated_at, :microsecond)}
  end
end
