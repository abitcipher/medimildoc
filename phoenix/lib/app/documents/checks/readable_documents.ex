defmodule App.Documents.Checks.ReadableDocuments do
  @moduledoc """
  Read filter for documents: types whose category the actor may read
  everywhere, types readable only in their unit for people in it or
  handled by it (`handling_unit_id`), the
  actor's own documents of self-service types, their own signed orders of
  types they acknowledge (docs/design/acknowledgements.md — to read what
  they acknowledge), and any document on whose
  route the actor has a step (a board member, a signatory), or whose step
  waits for someone the actor stands in for. Documents outside it never leave the database.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias App.Access.Unit
  alias App.Documents.{Access, Deputies, Types}

  @impl true
  def describe(_opts), do: "document type is readable by the actor (in scope), or on their route"

  @impl true
  def filter(actor, _authorizer, _opts) do
    actor
    |> by_type()
    |> or_own(actor)
    |> or_on_route(actor)
  end

  defp by_type(actor) do
    scopes = Enum.group_by(Types.ids(), &Access.scope(actor, &1, :read))
    global = Map.get(scopes, :global, [])

    case Map.get(scopes, :unit, []) do
      [] ->
        Ash.Expr.expr(type in ^global)

      unit ->
        org_ids = Unit.org_ids(actor)
        in_unit = Unit.person_in_unit(org_ids)

        Ash.Expr.expr(
          type in ^global or (type in ^unit and (^in_unit or handling_unit_id in ^org_ids))
        )
    end
  end

  defp or_own(readable, %{person_id: own}) when is_binary(own) do
    self_types = Types.self_service_types()
    acknowledged = Types.acknowledge_types()

    Ash.Expr.expr(
      ^readable or
        (person_id == ^own and
           (type in ^self_types or (type in ^acknowledged and state == :signed)))
    )
  end

  defp or_own(readable, _actor), do: readable

  # On the route: the actor's own steps, and steps now waiting for someone
  # they stand in for (docs/design/inbox-first.md) — only of types whose
  # route permissions the actor holds, within their unit when that
  # permission is unit-scoped (as `Deputies.holds_step?/3` decides).
  defp or_on_route(readable, %{id: actor_id} = actor) when is_binary(actor_id) do
    # Also what they wrote, and letters they have an instruction on
    # (docs/design/correspondence.md).
    own =
      Ash.Expr.expr(
        ^readable or author_id == ^actor_id or exists(steps, assignee_id == ^actor_id) or
          exists(instructions, executor_id == ^actor_id)
      )

    case Deputies.principals(actor_id) do
      [] ->
        own

      principals ->
        Ash.Expr.expr(
          ^own or
            (^deputy_scope(actor) and
               exists(steps, assignee_id in ^principals and status == :pending))
        )
    end
  end

  defp or_on_route(readable, _actor), do: readable

  defp deputy_scope(actor) do
    scopes =
      Enum.group_by(Types.ids(), fn type ->
        type
        |> Types.route()
        |> Enum.map(&App.Access.permission_scope(actor, &1["permission"]))
        |> Enum.min_by(&scope_rank/1, fn -> :none end)
      end)

    global = Map.get(scopes, :global, [])

    case Map.get(scopes, :unit, []) do
      [] ->
        Ash.Expr.expr(type in ^global)

      unit ->
        org_ids = Unit.org_ids(actor)
        in_unit = Unit.person_in_unit(org_ids)

        Ash.Expr.expr(
          type in ^global or (type in ^unit and (^in_unit or handling_unit_id in ^org_ids))
        )
    end
  end

  defp scope_rank(:global), do: 0
  defp scope_rank(:unit), do: 1
  defp scope_rank(:none), do: 2
end
