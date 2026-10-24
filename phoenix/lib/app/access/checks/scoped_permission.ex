defmodule App.Access.Checks.ScopedPermission do
  @moduledoc """
  Read filter for resources belonging to a person (national IDs, identity
  documents): everything when the actor holds `permission` globally, only
  people in their unit when only a unit-scoped profile grants it
  (docs/design/access-control-phase2.md), nothing otherwise.

      authorize_if {App.Access.Checks.ScopedPermission, permission: "people.private.read"}
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias App.Access.Unit

  @impl true
  def describe(opts), do: "actor has #{Keyword.fetch!(opts, :permission)} for this person"

  @impl true
  def filter(actor, _authorizer, opts) do
    case App.Access.permission_scope(actor, Keyword.fetch!(opts, :permission)) do
      :global -> Ash.Expr.expr(true)
      :unit -> Unit.person_in_unit(Unit.org_ids(actor))
      :none -> Ash.Expr.expr(false)
    end
  end
end
