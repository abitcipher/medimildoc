defmodule App.Documents.Checks.CanRecordAcknowledgement do
  @moduledoc """
  The actor may record that someone acknowledged an order on their behalf
  (docs/design/acknowledgements.md): they may write orders of its type for
  the person, or they sign orders (`orders.sign`, a commander) in a scope
  that covers the person or the order's unit.
  """
  use Ash.Policy.SimpleCheck

  alias App.Documents.{Access, Document, Types}

  @impl true
  def describe(_opts), do: "actor may write the order's type or sign orders for the person"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    case document(changeset) do
      %Document{} = document ->
        document.type in Types.ids() and Access.can_record_acknowledgement?(actor, document)

      nil ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false

  @doc "The order an acknowledgement changeset is about (read as the system), or nil."
  @spec document(Ash.Changeset.t()) :: Document.t() | nil
  def document(changeset) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :document_id),
         {:ok, document} <- Ash.get(Document, id, authorize?: false) do
      document
    else
      _ -> nil
    end
  end
end
