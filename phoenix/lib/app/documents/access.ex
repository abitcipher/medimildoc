defmodule App.Documents.Access do
  @moduledoc """
  Who may read and write documents of a type (docs/design/documents-core.md
  §Access): each type names its permissions (`access` in its JSON) — any
  one of its read permissions to read, its write permission to write —
  with the unit scope those permissions have in the actor's profiles. A
  self-service type (`access.self`) is also open to the person's own
  account (`User.person_id`) for their own documents.
  """

  alias App.Access
  alias App.Access.Unit
  alias App.Documents.Types

  @spec scope(map() | nil, atom(), :read | :write) :: :global | :unit | :none
  def scope(actor, type, :write), do: Access.permission_scope(actor, Types.write_permission(type))

  def scope(actor, type, :read) do
    scopes = Enum.map(Types.read_permissions(type), &Access.permission_scope(actor, &1))

    cond do
      :global in scopes -> :global
      :unit in scopes -> :unit
      true -> :none
    end
  end

  @doc "Types `actor` may create (anywhere or in their unit)."
  @spec writable_types(map() | nil) :: [atom()]
  def writable_types(actor), do: Enum.filter(Types.ids(), &(scope(actor, &1, :write) != :none))

  @doc """
  Whether `actor` may write documents of `type` about the person
  `person_id`; unit scope passes for the person's unit or the document's
  handling unit (`handling_unit/1`).
  """
  @spec can_write?(map() | nil, atom(), String.t() | nil, String.t() | nil) :: boolean()
  def can_write?(actor, type, person_id, handling_unit_id \\ nil) do
    own?(actor, type, person_id) or
      case scope(actor, type, :write) do
        :global -> true
        :unit -> covers?(Unit.org_ids(actor), person_id, handling_unit_id)
        :none -> false
      end
  end

  defp covers?([], _person_id, _unit_id), do: false

  defp covers?(org_ids, person_id, unit_id),
    do: unit_id in org_ids or Unit.person_in_unit?(person_id, org_ids)

  @doc """
  The unit that handles a document with these fields: the unit of the
  post it names (`position`) or of the care provider it names
  (`provider`, when it is one of our units); nil otherwise.
  """
  @spec handling_unit(map()) :: String.t() | nil
  def handling_unit(%{"position" => id}) when is_binary(id),
    do: unit_of(App.People.Position, id)

  def handling_unit(%{"provider" => id}) when is_binary(id), do: unit_of(App.Care.Provider, id)

  # A letter's own unit: addressed to or sent from (docs/design/correspondence.md).
  def handling_unit(%{"unit" => id}) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, unit} <- Ash.get(App.People.Organization, id, authorize?: false) do
      unit.id
    else
      _ -> nil
    end
  end

  def handling_unit(_data), do: nil

  @doc "The care provider a document with these fields is addressed to (`provider`), if it exists."
  @spec recipient_provider(map()) :: String.t() | nil
  def recipient_provider(%{"provider" => id}) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, provider} <- Ash.get(App.Care.Provider, id, authorize?: false) do
      provider.id
    else
      _ -> nil
    end
  end

  def recipient_provider(_data), do: nil

  defp unit_of(resource, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Ash.get(resource, id, authorize?: false) do
          {:ok, entity} -> entity.organization_id
          _ -> nil
        end

      :error ->
        nil
    end
  end

  # A self-service type, about the actor's own person.
  defp own?(%{person_id: own}, type, person_id) when is_binary(own),
    do: own == person_id and Types.self_service?(type)

  defp own?(_actor, _type, _person_id), do: false

  @doc """
  Whether `actor` may record that the person acknowledged `document` on
  their behalf (docs/design/acknowledgements.md): they may write its type
  for the person, or sign orders (`orders.sign`) in a scope covering it —
  the latter only for types they may read (a commander records orders, not
  medical board conclusions).
  """
  @spec can_record_acknowledgement?(map() | nil, map()) :: boolean()
  def can_record_acknowledgement?(nil, _document), do: false

  def can_record_acknowledgement?(actor, document) do
    Types.acknowledge?(document.type) and
      (can_write?(actor, document.type, document.person_id, Map.get(document, :handling_unit_id)) or
         (scope(actor, document.type, :read) != :none and holds?(actor, "orders.sign", document)))
  end

  @doc """
  Users who may take a route step for `document`: they hold its permission
  everywhere, or in a unit that covers the document — the person's current
  unit, or its handling unit: the unit of the post it names (an
  appointment of a newcomer, who is in no unit yet, is signed by the
  commander of the unit they join) or of the care provider it names. Sorted by name or e-mail; the actor's own account is
  included (an author may also sign when the route allows).
  """
  @spec eligible_users(map(), map()) :: [App.Accounts.User.t()]
  def eligible_users(%{"permission" => permission}, document) do
    App.Accounts.User
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&holds?(&1, permission, document))
    |> Enum.sort_by(&to_string(&1.name || &1.email))
  end

  @doc "Whether `user` holds `permission` for `document` (scope included, see `eligible_users/2`)."
  @spec holds?(map(), String.t(), map()) :: boolean()
  def holds?(user, permission, document) do
    case Access.permission_scope(user, permission) do
      :global -> true
      :unit -> in_unit?(document, Unit.org_ids(user))
      :none -> false
    end
  end

  defp in_unit?(document, org_ids),
    do: covers?(org_ids, document.person_id, Map.get(document, :handling_unit_id))
end
