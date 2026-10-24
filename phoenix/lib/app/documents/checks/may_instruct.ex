defmodule App.Documents.Checks.MayInstruct do
  @moduledoc """
  The actor may give an instruction on this document
  (docs/design/correspondence.md): it is a registered document of a type
  that takes instructions, the actor may read it, and they are a records
  officer or hold `orders.sign` covering it (a head of its unit).
  """
  use Ash.Policy.SimpleCheck

  alias App.Documents.{Access, Document, Types}

  @impl true
  def describe(_opts), do: "actor may give instructions on the document"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when is_map(actor) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :document_id),
         {:ok, %{state: :signed} = document} <- Ash.get(Document, id, actor: actor),
         true <- Types.instructions?(document.type) do
      App.Access.can?(actor, "records.manage") or Access.holds?(actor, "orders.sign", document)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
