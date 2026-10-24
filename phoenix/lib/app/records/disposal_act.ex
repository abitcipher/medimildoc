defmodule App.Records.DisposalAct do
  @moduledoc """
  The act of selecting cases for disposal (docs/design/registers-file-plan.md
  §Closing) as a PDF: the closed cases whose retention period has ended
  (`App.Records.FilePlan.due_for_disposal/2`), with how many documents each
  holds. The act is signed on paper by the records officer and the expert
  commission; the app doesn't destroy anything.
  """

  alias App.Documents.Pdf
  alias App.Records.FilePlan

  @spec pdf(Date.t(), map()) :: {:ok, binary()} | {:error, term()}
  def pdf(today, actor) do
    cases = FilePlan.due_for_disposal(today, actor)
    counts = FilePlan.counts(Enum.map(cases, & &1.id))

    rows =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {kase, n} ->
        %{
          "n" => n,
          "index" => kase.index,
          "title" => kase.title,
          "year" => kase.year,
          "documents" => Map.get(counts, kase.id, 0),
          "retention" => kase.retention
        }
      end)

    Pdf.render("disposal_act.typ", %{
      "title" => "Акт про вилучення для знищення документів",
      "rows" => rows,
      "total" => length(rows),
      "generated" => Calendar.strftime(today, "%d.%m.%Y")
    })
  end
end
