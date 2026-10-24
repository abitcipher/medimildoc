defmodule App.Documents.Checks.AcknowledgeOwn do
  @moduledoc """
  The actor's account is linked to the person the order is about — they
  acknowledge their own order (docs/design/acknowledgements.md).
  """
  use Ash.Policy.SimpleCheck

  alias App.Documents.Checks.CanRecordAcknowledgement

  @impl true
  def describe(_opts), do: "the order is about the actor's own person"

  @impl true
  def match?(%{person_id: own}, %{changeset: %Ash.Changeset{} = changeset}, _opts)
      when is_binary(own) do
    case CanRecordAcknowledgement.document(changeset) do
      %{person_id: ^own} -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
