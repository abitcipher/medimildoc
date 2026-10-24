defmodule App.Records.FilePlan do
  @moduledoc """
  Working with a year's file plan (docs/design/registers-file-plan.md):
  filing documents signed before their case existed, copying last year's
  plan, starting from the template, removing an empty case, and how many
  documents each case holds.
  """
  require Ash.Query

  alias App.Documents.Document
  alias App.Records.Case

  @template "priv/records/file_plan_template.json"

  @doc """
  Files the signed documents of `kase`'s types and year that are in no case
  yet; returns how many.
  """
  @spec file_backlog(Case.t()) :: non_neg_integer()
  def file_backlog(%Case{document_types: []}), do: 0
  def file_backlog(%Case{closed_on: %Date{}}), do: 0

  def file_backlog(%Case{} = kase) do
    types = Enum.map(kase.document_types, &String.to_existing_atom/1)

    Document
    |> Ash.Query.filter(
      state == :signed and register_year == ^kase.year and type in ^types and is_nil(case_id)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn document ->
      document
      |> Ash.Changeset.for_update(:file, %{case_id: kase.id}, authorize?: false)
      |> Ash.update!(authorize?: false)
    end)
    |> length()
  end

  @doc "Cases of `year`, by index, as `actor` may read them."
  @spec cases(integer(), map()) :: [Case.t()]
  def cases(year, actor) do
    Case
    |> Ash.Query.filter(year == ^year)
    |> Ash.Query.load(:organization)
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&index_key(&1.index))
  end

  @doc "How many documents each of `case_ids` holds."
  @spec counts([String.t()]) :: %{String.t() => non_neg_integer()}
  def counts([]), do: %{}

  def counts(case_ids) do
    Document
    |> Ash.Query.filter(case_id in ^case_ids)
    |> Ash.Query.select([:id, :case_id])
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.case_id)
  end

  @doc """
  Creates `year`'s cases from `from_year`'s (or the template's, with
  `:template`), skipping indexes the year already has and types already
  filed elsewhere; files earlier documents. Returns how many were created.
  """
  @spec copy(integer() | :template, integer(), map()) :: non_neg_integer()
  def copy(from, year, actor) do
    existing = year |> cases(actor) |> MapSet.new(& &1.index)

    from
    |> source(actor)
    |> Enum.reject(&MapSet.member?(existing, &1.index))
    |> Enum.count(fn attrs ->
      Case
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :year, year), actor: actor)
      |> Ash.create(actor: actor)
      |> case do
        {:ok, kase} ->
          file_backlog(kase)
          true

        {:error, _} ->
          false
      end
    end)
  end

  @doc "Removes `kase` if no document is filed into it."
  @spec delete(Case.t(), map()) :: :ok | {:error, :not_empty | term()}
  def delete(%Case{} = kase, actor) do
    if Map.get(counts([kase.id]), kase.id, 0) > 0,
      do: {:error, :not_empty},
      else: Ash.destroy(kase, actor: actor)
  end

  @doc """
  Closes every open case of `year` (at the year's end); returns how many.
  Documents signed later of their types stay "not filed" until a case of
  the new year takes them.
  """
  @spec close_year(integer(), map()) :: non_neg_integer()
  def close_year(year, actor) do
    year
    |> cases(actor)
    |> Enum.filter(&is_nil(&1.closed_on))
    |> Enum.count(fn kase ->
      match?(
        {:ok, _},
        kase |> Ash.Changeset.for_update(:close, %{}, actor: actor) |> Ash.update()
      )
    end)
  end

  @doc """
  The retention class of a case, as inventories group them: kept
  `:permanent`ly, `:long` (more than 10 years — personnel files are kept
  75), `:temporary` (up to 10 years), or `:unspecified` (no period given).
  """
  @spec category(Case.t()) :: :permanent | :long | :temporary | :unspecified
  def category(%Case{permanent: true}), do: :permanent
  def category(%Case{retention_years: nil}), do: :unspecified
  def category(%Case{retention_years: years}) when years > 10, do: :long
  def category(%Case{}), do: :temporary

  @doc """
  The inventory (description) of `year`'s closed cases of retention class
  `category`, by index: each with the dates of its first and last
  document and how many it holds.
  """
  @spec inventory(integer(), atom(), map()) :: [map()]
  def inventory(year, category, actor) do
    cases =
      year
      |> cases(actor)
      |> Enum.filter(&(&1.closed_on != nil and category(&1) == category))

    dates = document_dates(Enum.map(cases, & &1.id))

    Enum.map(cases, fn kase ->
      days = Map.get(dates, kase.id, [])

      %{
        case: kase,
        first: Enum.min(days, Date, fn -> nil end),
        last: Enum.max(days, Date, fn -> nil end),
        documents: length(days)
      }
    end)
  end

  @doc """
  Closed cases whose retention period has ended by `today` (counted from
  the 1st of January after the case's year): due for disposal, by year.
  Permanent cases never are.
  """
  @spec due_for_disposal(Date.t(), map()) :: [Case.t()]
  def due_for_disposal(today, actor) do
    Case
    |> Ash.Query.filter(
      not is_nil(closed_on) and permanent == false and not is_nil(retention_years)
    )
    |> Ash.read!(actor: actor)
    |> Enum.filter(&(&1.year + &1.retention_years < today.year))
    |> Enum.sort_by(&{&1.year, index_key(&1.index)})
  end

  defp document_dates([]), do: %{}

  defp document_dates(case_ids) do
    Document
    |> Ash.Query.filter(case_id in ^case_ids)
    |> Ash.Query.select([:id, :case_id, :registered_on])
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&is_nil(&1.registered_on))
    |> Enum.group_by(& &1.case_id, & &1.registered_on)
  end

  @doc "The template's cases (index, title, retention, reference, types, note)."
  @spec template() :: [map()]
  def template do
    Application.app_dir(:app, @template)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("cases")
    |> Enum.map(fn entry ->
      %{
        index: entry["index"],
        title: entry["title"],
        retention: entry["retention"],
        retention_ref: entry["retention_ref"],
        permanent: entry["permanent"] == true,
        retention_years: entry["retention_years"],
        document_types: entry["document_types"],
        note: entry["note"]
      }
    end)
  end

  defp source(:template, _actor), do: template()

  defp source(from_year, actor) do
    from_year
    |> cases(actor)
    |> Enum.map(
      &Map.take(&1, [
        :index,
        :title,
        :retention,
        :retention_ref,
        :permanent,
        :retention_years,
        :document_types,
        :note,
        :organization_id
      ])
    )
  end

  # "03-2" before "03-10": numeric parts compared as numbers.
  defp index_key(index) do
    index
    |> String.split(~r/[^0-9]+/, trim: true)
    |> Enum.map(&String.to_integer/1)
    |> then(&{&1, index})
  end
end
