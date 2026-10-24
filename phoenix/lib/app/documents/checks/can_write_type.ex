defmodule App.Documents.Checks.CanWriteType do
  @moduledoc """
  The actor may write documents of this type about this person (category
  permission, unit scope: the person's unit or the document's handling
  unit). On create both come from the changeset; on
  update from the stored document.
  """
  use Ash.Policy.SimpleCheck

  alias App.Documents.{Access, Instructions, Types}

  @impl true
  def describe(_opts), do: "actor may write documents of this type (in scope)"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    type = Ash.Changeset.get_attribute(changeset, :type)
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)

    type in Types.ids() and
      (Access.can_write?(actor, type, person_id, handling_unit(changeset)) or
         executor_reply?(actor, type, changeset))
  end

  def match?(_actor, _context, _opts), do: false

  # A reply written by the executor of an open instruction on its basis
  # letter (docs/design/correspondence.md).
  defp executor_reply?(%{id: actor_id}, type, changeset) do
    Types.reply_by_executor?(type) and
      Instructions.executor_of?(actor_id, Ash.Changeset.get_attribute(changeset, :basis_id))
  end

  defp executor_reply?(_actor, _type, _changeset), do: false

  # On create, from the fields being written (not stored yet); on update,
  # as stored.
  defp handling_unit(%{action_type: :create} = changeset) do
    case Ash.Changeset.fetch_argument(changeset, :data) do
      {:ok, %{} = data} -> Access.handling_unit(data)
      _ -> nil
    end
  end

  defp handling_unit(changeset), do: Map.get(changeset.data, :handling_unit_id)
end
