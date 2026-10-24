defmodule AppWeb.SheetStatus do
  @moduledoc """
  SHEETS-UI.8/5/11 (docs/design/sheets-ui.md): the text of the Status
  column of the Assignments tab — what a check found on each row and,
  after Carry out, what was done. Each text starts with a sign the sheet
  colours (`AppWeb.SheetLayout`): ✓ done, → will be done, ! needs a look,
  ↻ changed in the app, ✗ not done.

  Pure: `App.Google.AssignmentSheets` writes the texts.
  """
  use Gettext, backend: AppWeb.Gettext

  alias AppWeb.{AssignmentPlan, SheetPlan}

  @doc """
  A check's result by sheet row: `%{row => text}` (unchanged rows: none).
  An assignments plan, or a people/records plan (`App.People.SheetSync`,
  it names its `dataset`).
  """
  @spec for_plan(map()) :: %{pos_integer() => String.t()}
  def for_plan(%{dataset: dataset} = plan) do
    labels = SheetPlan.labels(dataset)

    changes =
      Map.new(plan.changes, fn change ->
        fields = Enum.map_join(change.changed, ", ", &(labels[&1] || &1))
        text = SheetPlan.kind_label(change.kind) <> ": " <> fields <> new_id(change)

        {change.row,
         if(change.conflict?,
           do:
             "! " <>
               gettext("%{change}, but changed in the app after the export: check it",
                 change: text
               ),
           else: "→ " <> text
         )}
      end)

    errors =
      Map.new(plan.errors, fn {row, error} -> {row, "✗ " <> SheetPlan.error_text(error)} end)

    changes |> Map.merge(errors) |> Map.merge(stale(plan))
  end

  def for_plan(plan) do
    changes = Map.new(plan.changes, &{&1.row, planned(&1)})

    errors =
      Map.new(plan.errors, fn {row, error} -> {row, "✗ " <> AssignmentPlan.error_text(error)} end)

    changes |> Map.merge(errors) |> Map.merge(stale(plan))
  end

  defp new_id(%{new_id: id}) when is_binary(id), do: " · PersonID " <> id
  defp new_id(_change), do: ""

  defp stale(plan) do
    Map.new(
      plan.stale,
      &{&1, "↻ " <> gettext("Changed in the app after the export: export again to edit it")}
    )
  end

  defp planned(%{conflict?: true} = change),
    do:
      "! " <>
        gettext("%{change}, but changed in the app after the export: check it",
          change: AssignmentPlan.kind_label(change.kind)
        )

  defp planned(change),
    do:
      "→ " <>
        gettext("%{change} from %{date}",
          change: AssignmentPlan.kind_label(change.kind),
          date: AppWeb.DateFormat.display(change.on)
        )

  @doc """
  What Carry out did, by sheet row (`AssignmentSync.apply/2`'s `outcomes`
  with the plan's errors and stale rows): `%{row => text}`.
  """
  @spec for_result(map(), map()) :: %{pos_integer() => String.t()}
  def for_result(plan, result) do
    error_text =
      if Map.has_key?(plan, :dataset),
        do: &SheetPlan.error_text/1,
        else: &AssignmentPlan.error_text/1

    errors =
      Map.new(plan.errors, fn {row, error} ->
        {row, "✗ " <> gettext("Not carried out: %{reason}", reason: error_text.(error))}
      end)

    stale = Map.new(plan.stale, &{&1, "↻ " <> gettext("Updated from the app")})
    done = Map.new(result.outcomes, fn {row, outcome} -> {row, done(outcome)} end)

    errors |> Map.merge(stale) |> Map.merge(done)
  end

  defp done({:drafted, kind, _id}),
    do:
      "✓ " <>
        gettext("Draft %{order} created: complete it in Tasks",
          order: String.downcase(AssignmentPlan.kind_label(kind))
        )

  defp done(:corrected), do: "✓ " <> gettext("Start date corrected")
  defp done({:created, _id, _key}), do: "✓ " <> gettext("Added to the app")
  defp done({:updated, _key}), do: "✓ " <> gettext("Saved in the app")

  defp done(:order_pending),
    do: "! " <> gettext("Skipped: a personnel order for this person is already open")

  defp done({:failed, message}), do: "✗ " <> message

  @doc """
  Re-keys `%{row => text}` by PersonID, for a tab written again from the
  database (rows move): `codes` is `%{row => PersonID}` of the sheet read.
  """
  @spec by_person(%{pos_integer() => String.t()}, %{pos_integer() => String.t()}) ::
          %{String.t() => String.t()}
  def by_person(statuses, codes) do
    for {row, text} <- statuses, code = codes[row], code not in [nil, ""], into: %{} do
      {code, text}
    end
  end
end
