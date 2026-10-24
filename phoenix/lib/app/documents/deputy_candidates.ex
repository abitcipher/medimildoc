defmodule App.Documents.DeputyCandidates do
  @moduledoc """
  Who may be named a stand-in (docs/design/inbox-first.md §Stand-ins).
  Kept apart from `App.Documents.Deputies` so the `Deputy` resource can
  check it without a dependency cycle.
  """

  alias App.Access
  alias App.Accounts.User
  alias App.Documents.Types

  @doc """
  Who `actor` may name as a deputy: other users holding at least one of
  the route permissions the actor holds (a deputy without them could act
  on nothing). Empty when the actor approves or signs nothing.
  """
  @spec for_user(map()) :: [map()]
  def for_user(actor) do
    case Enum.filter(route_permissions(), &(Access.permission_scope(actor, &1) != :none)) do
      [] ->
        []

      held ->
        User
        |> Ash.read!(authorize?: false)
        |> Enum.filter(fn user ->
          user.id != actor.id and
            Enum.any?(held, &(Access.permission_scope(user, &1) != :none))
        end)
        |> Enum.sort_by(&String.downcase(&1.name || to_string(&1.email)))
    end
  end

  # Required stages only: an optional co-approval open to anyone
  # (docs/design/parallel-approval.md) needs no deputy.
  defp route_permissions do
    Types.ids()
    |> Enum.flat_map(&Types.route/1)
    |> Enum.reject(&(&1["optional"] == true))
    |> Enum.map(& &1["permission"])
    |> Enum.uniq()
  end
end
