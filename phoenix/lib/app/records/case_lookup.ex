defmodule App.Records.CaseLookup do
  @moduledoc """
  The case a document of a type and year is filed into (docs/design/registers-file-plan.md),
  read as the system — used when a document is signed.
  """
  require Ash.Query

  alias App.Records.Case

  @doc "The id of the open case of `year` that `type` is filed into, or nil (none, or closed)."
  @spec case_id(atom(), integer()) :: String.t() | nil
  def case_id(type, year) do
    type = Atom.to_string(type)

    Case
    |> Ash.Query.filter(year == ^year and ^type in document_types and is_nil(closed_on))
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      found -> found.id
    end
  end
end
