defmodule App.Notify.Checks.CreatesOwn do
  @moduledoc "The actor creates a row for themselves (`user_id` is the actor's id)."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor creates their own row"

  @impl true
  def match?(%{id: actor_id}, %{changeset: %Ash.Changeset{} = changeset}, _opts),
    do: Ash.Changeset.get_attribute(changeset, :user_id) == actor_id

  def match?(_actor, _context, _opts), do: false
end
