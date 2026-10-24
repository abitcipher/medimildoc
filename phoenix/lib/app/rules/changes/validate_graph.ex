defmodule App.Rules.Changes.ValidateGraph do
  @moduledoc "A new graph must be a well-formed JDM decision (checked by the engine itself)."
  use Ash.Resource.Change

  alias App.Rules.Engine
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Engine.validate(Ash.Changeset.get_attribute(changeset, :graph)) do
        :ok -> changeset
        {:error, message} -> Ash.Changeset.add_error(changeset, field: :graph, message: message)
      end
    end)
  end
end
