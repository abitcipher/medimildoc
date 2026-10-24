defmodule App.Records.Registers do
  @moduledoc """
  Registers (docs/design/registers-file-plan.md): the signed documents of
  a register and year in number order — or of one file plan case — with
  their registration metadata. Numbers, dates, types, signatories and
  cases are shown to anyone allowed on the Registers page; the person a
  document is about only where the viewer may read the document itself
  (a medical register doesn't reveal whose it is). Nothing encrypted is
  read, so nothing goes to the access log.
  """
  require Ash.Query

  alias App.Documents.{Document, Types}
  alias App.People.Person

  @page 100

  @doc """
  Register codes with the document types numbered in them, by code: those
  the document types declare, and any other register documents were
  numbered in (the demo data's test register).
  """
  @spec codes() :: [{String.t(), [atom()]}]
  def codes do
    used =
      Document
      |> Ash.Query.filter(state == :signed)
      |> Ash.Query.select([:register, :type])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.register, &1.type})

    Types.ids()
    |> Enum.map(&{Types.register(&1), &1})
    |> Enum.concat(used)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {code, types} -> {code, Enum.sort(types)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  One page of entries for `filters` — `code` and `year`, or `case_id` —
  optionally narrowed by `type`, as `viewer` sees them; with the total.
  `page` counts from 1; `:all` gives every entry (export).
  """
  @spec entries(map(), map(), pos_integer() | :all) :: %{
          entries: [map()],
          total: non_neg_integer()
        }
  def entries(filters, viewer, page \\ 1) do
    query =
      Document
      |> Ash.Query.filter(state == :signed)
      |> scope(filters)
      |> narrow_type(filters[:type])

    total = Ash.count!(query, authorize?: false)

    documents =
      query
      |> Ash.Query.sort(register_year: :asc, register_seq: :asc)
      |> paginate(page)
      |> Ash.Query.load([:signed_by, :case])
      |> Ash.read!(authorize?: false)

    readable = readable_ids(documents, viewer)
    people = people(documents, readable)

    %{
      total: total,
      entries:
        Enum.map(documents, fn document ->
          %{
            id: document.id,
            number: document.number,
            registered_on: document.registered_on,
            type: document.type,
            readable?: document.id in readable,
            person: Map.get(people, document.person_id),
            signed_by:
              document.signed_by &&
                (document.signed_by.name || to_string(document.signed_by.email)),
            case_index: document.case && document.case.index
          }
        end)
    }
  end

  @doc "Page size of `entries/3`."
  @spec page_size() :: pos_integer()
  def page_size, do: @page

  @doc "Years in which `code` has registered documents, newest first."
  @spec years(String.t()) :: [integer()]
  def years(code) do
    Document
    |> Ash.Query.filter(state == :signed and register == ^code)
    |> Ash.Query.select([:register_year])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.register_year)
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp scope(query, %{case_id: case_id}) when is_binary(case_id),
    do: Ash.Query.filter(query, case_id == ^case_id)

  defp scope(query, %{code: code, year: year}),
    do: Ash.Query.filter(query, register == ^code and register_year == ^year)

  defp narrow_type(query, nil), do: query
  defp narrow_type(query, type), do: Ash.Query.filter(query, type == ^type)

  defp paginate(query, :all), do: query

  defp paginate(query, page),
    do: query |> Ash.Query.limit(@page) |> Ash.Query.offset((page - 1) * @page)

  # Which of `documents` the viewer may read through the documents' own policies.
  defp readable_ids([], _viewer), do: []

  defp readable_ids(documents, viewer) do
    Document
    |> Ash.Query.filter(id in ^Enum.map(documents, & &1.id))
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: viewer)
    |> Enum.map(& &1.id)
  end

  defp people(documents, readable) do
    ids =
      documents
      |> Enum.filter(&(&1.id in readable))
      |> Enum.map(& &1.person_id)
      |> Enum.uniq()

    Person
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, Person.full_name(&1)})
  end
end
