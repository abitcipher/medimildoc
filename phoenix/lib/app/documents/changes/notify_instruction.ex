defmodule App.Documents.Changes.NotifyInstruction do
  @moduledoc """
  Notifications about instructions (docs/design/correspondence.md), in the
  same transaction: given → `:instruction_given` to the executor; done →
  `:instruction_done` to whoever gave it. The message names the letter's
  type and number, nothing else.
  """
  use Ash.Resource.Change

  alias App.Notify.Changes.DocumentEvents
  alias App.Notify.Emitter

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, instruction ->
      document = Ash.get!(App.Documents.Document, instruction.document_id, authorize?: false)
      params = DocumentEvents.params(document)

      case changeset.action.name do
        :give -> Emitter.emit(:instruction_given, [instruction.executor_id], params)
        :complete -> Emitter.emit(:instruction_done, [instruction.issued_by_id], params)
      end

      {:ok, instruction}
    end)
  end
end
