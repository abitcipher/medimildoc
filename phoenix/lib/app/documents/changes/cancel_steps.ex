defmodule App.Documents.Changes.CancelSteps do
  @moduledoc "Cancelling a document cancels its open steps (they stay as history)."
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, document ->
      App.Documents.Step
      |> Ash.Query.filter(document_id == ^document.id and status in [:pending, :waiting])
      |> Ash.read!(authorize?: false)
      |> Enum.each(fn step ->
        step
        |> Ash.Changeset.for_update(:update, %{status: :cancelled}, authorize?: false)
        |> Ash.update!(authorize?: false)
      end)

      {:ok, document}
    end)
  end
end
