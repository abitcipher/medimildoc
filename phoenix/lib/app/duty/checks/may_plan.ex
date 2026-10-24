defmodule App.Duty.Checks.MayPlan do
  @moduledoc """
  The actor may plan this person's duty (docs/design/duty-roster.md): HR or
  a commander, globally or with a unit that covers the person now.
  """
  use Ash.Policy.SimpleCheck

  alias App.Access.Unit

  @permissions ["people.write", "orders.sign"]

  @impl true
  def describe(_opts), do: "actor plans duties for this person"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    person_id =
      Ash.Changeset.get_attribute(changeset, :person_id) || Map.get(changeset.data, :person_id)

    Enum.any?(@permissions, fn permission ->
      case App.Access.permission_scope(actor, permission) do
        :global -> true
        :unit -> Unit.person_in_unit?(person_id, Unit.org_ids(actor))
        :none -> false
      end
    end)
  end

  def match?(_actor, _context, _opts), do: false
end
