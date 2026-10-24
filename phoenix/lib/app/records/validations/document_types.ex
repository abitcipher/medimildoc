defmodule App.Records.Validations.DocumentTypes do
  @moduledoc """
  A case's document types exist, and none of them is already filed into
  another case of the same year (docs/design/registers-file-plan.md).
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias App.Documents.Types

  @impl true
  def validate(changeset, _opts, _context) do
    types = Ash.Changeset.get_attribute(changeset, :document_types) || []
    known = Enum.map(Types.ids(), &Atom.to_string/1)

    case types -- known do
      [] ->
        elsewhere(changeset, types)

      unknown ->
        {:error,
         field: :document_types, message: "unknown document types: #{Enum.join(unknown, ", ")}"}
    end
  end

  # Reads other cases, so it runs as a before-action hook (never while
  # only checking whether an action is allowed).
  defp elsewhere(_changeset, []), do: :ok

  defp elsewhere(changeset, types) do
    year = Ash.Changeset.get_attribute(changeset, :year)
    id = changeset.data.id

    taken =
      App.Records.Case
      |> Ash.Query.filter(year == ^year)
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&(&1.id == id))
      |> Enum.flat_map(fn other ->
        Enum.map(other.document_types -- (other.document_types -- types), &{&1, other.index})
      end)

    case taken do
      [] ->
        :ok

      [{type, index} | _] ->
        {:error,
         field: :document_types, message: "#{type} is already filed into case #{index} this year"}
    end
  end
end
