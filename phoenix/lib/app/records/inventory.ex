defmodule App.Records.Inventory do
  @moduledoc """
  The inventory of cases (description) as a printed PDF and as rows for a
  workbook (docs/design/registers-file-plan.md §Closing): a year's closed
  cases of one retention class, from `App.Records.FilePlan.inventory/3`.
  Printed in Ukrainian, like the documents.
  """

  alias App.Documents.Pdf
  alias App.Records.FilePlan

  @kinds %{
    permanent: "постійного зберігання",
    long: "тривалого (понад 10 років) зберігання",
    temporary: "тимчасового (до 10 років включно) зберігання",
    unspecified: "без визначеного строку зберігання"
  }

  @doc "Retention classes an inventory is made for."
  @spec kinds() :: [atom()]
  def kinds, do: [:permanent, :long, :temporary, :unspecified]

  @doc "The table rows: number, index, title, first and last date, documents, retention, note."
  @spec rows(integer(), atom(), map()) :: [map()]
  def rows(year, kind, actor) do
    year
    |> FilePlan.inventory(kind, actor)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, n} ->
      kase = entry.case

      %{
        "n" => n,
        "index" => kase.index,
        "title" => kase.title,
        "first" => date(entry.first),
        "last" => date(entry.last),
        "documents" => entry.documents,
        "retention" =>
          Enum.join(Enum.reject([kase.retention, kase.retention_ref], &is_nil/1), ", "),
        "note" => kase.note || ""
      }
    end)
  end

  @doc "The inventory as a PDF."
  @spec pdf(integer(), atom(), map()) :: {:ok, binary()} | {:error, term()}
  def pdf(year, kind, actor) when is_map_key(@kinds, kind) do
    rows = rows(year, kind, actor)

    Pdf.render("case_inventory.typ", %{
      "title" => "Опис справ #{@kinds[kind]} за #{year} рік",
      "year" => year,
      "kind" => @kinds[kind],
      "rows" => rows,
      "total" => length(rows),
      "generated" => date(Date.utc_today())
    })
  end

  defp date(nil), do: "—"
  defp date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")
end
