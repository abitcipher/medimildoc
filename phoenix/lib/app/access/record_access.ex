defmodule App.Access.RecordAccess do
  @moduledoc """
  Which `PersonRecord` kinds an actor may read or write
  (docs/design/access-control-phase1.md): a kind's category maps to a
  permission (`App.Access.record_category_permission/2`), and the actor
  either holds it or not.

  Kept apart from `App.Access` so the permission model doesn't depend on
  the People domain.
  """

  alias App.Access
  alias App.People.PersonRecordSchema

  @doc "Kinds whose records `actor` may read."
  @spec readable_kinds(map() | nil) :: [atom()]
  def readable_kinds(actor),
    do: Enum.filter(PersonRecordSchema.kinds(), &can_read_kind?(actor, &1))

  @doc "Kinds whose records `actor` may create, edit and delete."
  @spec writable_kinds(map() | nil) :: [atom()]
  def writable_kinds(actor),
    do: Enum.filter(PersonRecordSchema.kinds(), &can_write_kind?(actor, &1))

  @spec can_read_kind?(map() | nil, atom()) :: boolean()
  def can_read_kind?(actor, kind), do: can?(actor, kind, :read)

  @spec can_write_kind?(map() | nil, atom()) :: boolean()
  def can_write_kind?(actor, kind), do: can?(actor, kind, :write)

  defp can?(actor, kind, access) do
    Access.can?(
      actor,
      Access.record_category_permission(PersonRecordSchema.category(kind), access)
    )
  end

  @doc """
  How far `actor` may read or write records of `kind`: `:global`, `:unit`
  (only people in their unit, docs/design/access-control-phase2.md) or
  `:none`.
  """
  @spec kind_scope(map() | nil, atom(), :read | :write) :: :global | :unit | :none
  def kind_scope(actor, kind, access) do
    Access.permission_scope(
      actor,
      Access.record_category_permission(PersonRecordSchema.category(kind), access)
    )
  end
end
