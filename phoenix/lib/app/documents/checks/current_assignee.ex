defmodule App.Documents.Checks.CurrentAssignee do
  @moduledoc """
  The actor holds one of the document's pending route steps (in a parallel
  stage there are several — docs/design/parallel-approval.md) or their active deputy holding the step's permission
  (docs/design/inbox-first.md), and its action is `opts[:step_action]`
  when given (only the last step signs).
  """
  use Ash.Policy.SimpleCheck

  alias App.Documents.Queries

  @impl true
  def describe(_opts), do: "actor holds the current route step"

  @impl true
  def match?(%{id: _} = actor, %{changeset: %Ash.Changeset{data: document}}, opts) do
    case Queries.step_for(actor, document) do
      nil -> false
      %{action: action} -> opts[:step_action] in [nil, action]
    end
  end

  def match?(_actor, _context, _opts), do: false
end
