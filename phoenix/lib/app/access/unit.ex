defmodule App.Access.Unit do
  @moduledoc """
  A user's unit for unit-scoped profiles (docs/design/access-control-phase2.md
  the organization of their linked person's current position, and every
  organization below it. Empty when the account has no linked person or the
  person has no current assignment, so unit-scoped access fails closed.
  """
  require Ash.Expr
  require Ash.Query

  alias App.People.{Assignment, Organization}

  # Organization parents are cycle-free (OrganizationParentNotACycle); the
  # limit only guards against a corrupted chain.
  @max_depth 100

  @doc "Ids of the organizations in `user`'s unit (their own and all below)."
  @spec org_ids(map() | nil) :: [Ash.UUID.t()]
  def org_ids(%{person_id: person_id}) when is_binary(person_id) do
    case current_org_id(person_id) do
      nil -> []
      org_id -> subtree([org_id], [org_id], @max_depth)
    end
  end

  def org_ids(_user), do: []

  @doc "The organization of `user`'s linked person's current post, or nil."
  @spec own_org_id(map() | nil) :: Ash.UUID.t() | nil
  def own_org_id(%{person_id: person_id}) when is_binary(person_id),
    do: current_org_id(person_id)

  def own_org_id(_user), do: nil

  @doc "Filter on `App.People.Person`: currently assigned somewhere in `org_ids`."
  @spec assigned_in(list()) :: Ash.Expr.t()
  def assigned_in(org_ids) do
    Ash.Expr.expr(exists(assignments, is_nil(ends_on) and position.organization_id in ^org_ids))
  end

  @doc "Ids of `org_id` and every organization below it."
  @spec subtree_ids(Ash.UUID.t()) :: [Ash.UUID.t()]
  def subtree_ids(org_id), do: subtree([org_id], [org_id], @max_depth)

  @doc """
  Filter on a resource with a `person` relationship: the person is currently
  assigned somewhere in `org_ids`.
  """
  @spec person_in_unit(list()) :: Ash.Expr.t()
  def person_in_unit(org_ids) do
    Ash.Expr.expr(
      exists(person.assignments, is_nil(ends_on) and position.organization_id in ^org_ids)
    )
  end

  @doc "Whether the person with `person_id` is currently assigned in `org_ids`."
  @spec person_in_unit?(Ash.UUID.t() | nil, list()) :: boolean()
  def person_in_unit?(nil, _org_ids), do: false
  def person_in_unit?(_person_id, []), do: false

  def person_in_unit?(person_id, org_ids) do
    Assignment
    |> Ash.Query.filter(
      person_id == ^person_id and is_nil(ends_on) and position.organization_id in ^org_ids
    )
    |> Ash.exists?(authorize?: false)
  end

  defp current_org_id(person_id) do
    Assignment
    |> Ash.Query.filter(person_id == ^person_id and is_nil(ends_on))
    |> Ash.Query.load(:position)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{position: %{organization_id: org_id}}] -> org_id
      _ -> nil
    end
  end

  defp subtree(acc, _frontier, 0), do: acc

  defp subtree(acc, frontier, depth) do
    children =
      Organization
      |> Ash.Query.filter(parent_id in ^frontier)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
      |> Enum.reject(&(&1 in acc))

    if children == [], do: acc, else: subtree(acc ++ children, children, depth - 1)
  end
end
