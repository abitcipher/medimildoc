defmodule App.Documents.Reminders do
  @moduledoc """
  Overdue reminders (docs/design/inbox-first.md): once a route step has
  waited longer than `documents.step_days`, its assignee and their active
  deputies get `:document_overdue`, once per step (`reminded_at`). Run
  hourly by `App.Documents.Reminders.Ticker`; safe to run any time.
  Instructions past their due date remind their executor the same way
  (docs/design/correspondence.md).
  """

  require Ash.Query

  alias App.Documents.{Deputies, Instruction, Step}
  alias App.Notify.Changes.DocumentEvents
  alias App.Notify.Emitter

  @doc "Sends the reminders due at `now`; returns how many steps and instructions were reminded."
  @spec run(DateTime.t()) :: non_neg_integer()
  def run(now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)
    # Overdue: pending since before the start of (today − step days).
    cutoff =
      DateTime.new!(Date.add(today, -App.Settings.get("documents.step_days")), ~T[00:00:00])

    steps =
      Step
      |> Ash.Query.filter(
        status == :pending and not is_nil(pending_since) and pending_since < ^cutoff and
          is_nil(reminded_at)
      )
      |> Ash.Query.load(:document)
      |> Ash.read!(authorize?: false)

    deputies = steps |> Enum.map(& &1.assignee_id) |> Deputies.of(today)

    # The mark and the notifications in one transaction (the outbox).
    Enum.each(steps, fn step ->
      recipients = [step.assignee_id | Map.get(deputies, step.assignee_id, [])]
      params = DocumentEvents.params(step.document)

      step
      |> Ash.Changeset.for_update(:update, %{reminded_at: now}, authorize?: false)
      |> Ash.Changeset.after_action(fn _changeset, updated ->
        Emitter.emit(:document_overdue, recipients, params)
        {:ok, updated}
      end)
      |> Ash.update!(authorize?: false)
    end)

    length(steps) + remind_instructions(today, now)
  end

  # Instructions past their due date (docs/design/correspondence.md): the
  # executor, once.
  defp remind_instructions(today, now) do
    Instruction
    |> Ash.Query.filter(
      status == :open and not is_nil(due_on) and due_on < ^today and is_nil(reminded_at)
    )
    |> Ash.Query.load(:document)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn instruction ->
      params = DocumentEvents.params(instruction.document)

      instruction
      |> Ash.Changeset.for_update(:remind, %{reminded_at: now}, authorize?: false)
      |> Ash.Changeset.after_action(fn _changeset, updated ->
        Emitter.emit(:instruction_overdue, [instruction.executor_id], params)
        {:ok, updated}
      end)
      |> Ash.update!(authorize?: false)
    end)
    |> length()
  end
end
