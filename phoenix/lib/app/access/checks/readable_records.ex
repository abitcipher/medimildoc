defmodule App.Access.Checks.ReadableRecords do
  @moduledoc """
  Read filter for `PersonRecord`: kinds whose category the actor may read
  everywhere, plus kinds they may read only in their unit
  (docs/design/access-control-phase2.md) restricted to people currently
  assigned in that unit — and, in both cases, only records whose
  classification the actor is cleared for. An active emergency access
  (Break the Glass) adds that person's allergy records. Records outside it never leave the database, so
  tables, counts and any future API are covered without UI changes.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias App.Access.{Clearance, RecordAccess, Unit}
  alias App.Audit.EmergencyAccess
  alias App.People.PersonRecordSchema

  @impl true
  def describe(_opts), do: "record kind is readable by the actor (in scope)"

  @impl true
  def filter(actor, _authorizer, _opts) do
    cleared = Clearance.readable_classifications(actor)
    readable = actor |> in_scope() |> with_emergency_access(actor)

    Ash.Expr.expr(^readable and (is_nil(classification) or classification in ^cleared))
  end

  # Kinds readable everywhere, or only for people in the actor's unit.
  defp in_scope(actor) do
    scopes = Enum.group_by(PersonRecordSchema.kinds(), &RecordAccess.kind_scope(actor, &1, :read))
    global = Map.get(scopes, :global, [])

    case Map.get(scopes, :unit, []) do
      [] ->
        Ash.Expr.expr(kind in ^global)

      unit_kinds ->
        in_unit = Unit.person_in_unit(Unit.org_ids(actor))
        Ash.Expr.expr(kind in ^global or (kind in ^unit_kinds and ^in_unit))
    end
  end

  # Break the Glass: allergy records of people with an active grant.
  defp with_emergency_access(readable, actor) do
    case EmergencyAccess.active_person_ids(actor) do
      [] -> readable
      ids -> Ash.Expr.expr(^readable or (kind == :allergy_intolerance and person_id in ^ids))
    end
  end
end
