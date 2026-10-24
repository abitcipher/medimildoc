defmodule AppWeb.StartPage do
  @moduledoc """
  What each role needs to act on, for the start page (docs/design/
  ui-plan.md item 8). Every widget is loaded only when the user holds the
  matching permission, and through the normal read policies, so it shows
  only people and records the user may see (unit scope and clearance
  included).
  """
  require Ash.Query

  alias App.Access
  alias App.Accounts.AccessRequest
  alias App.Audit.EmergencyAccess
  alias App.Documents.{Inbox, Queries}
  alias App.People.{IdentityDocument, PersonRecord}

  @soon_days 90
  @list_limit 5
  @inbox_limit 8

  @doc """
  What waits for `user` (docs/design/inbox-first.md), most urgent first:
  the first few items, how many in all and how many are overdue.
  """
  @spec inbox(map()) :: %{
          items: [Inbox.item()],
          count: non_neg_integer(),
          overdue: non_neg_integer()
        }
  def inbox(user) do
    items = Inbox.items(Queries.inbox(user), Queries.to_acknowledge(user), Date.utc_today())
    %{items: Enum.take(items, @inbox_limit), count: length(items), overdue: Inbox.overdue(items)}
  end

  @doc "Widgets for `user`, as `{name, data}` in display order."
  @spec widgets(map()) :: [{atom(), map()}]
  def widgets(user) do
    [
      {:readiness, "readiness.read", &readiness/1},
      {:clearances, "clearance.read", &clearances/1},
      {:documents, "people.private.read", &documents/1},
      {:emergencies, "audit.read", &emergencies/1},
      {:requests, "users.manage", &requests/1}
    ]
    |> Enum.filter(fn {_name, permission, _load} -> Access.can?(user, permission) end)
    |> Enum.map(fn {name, _permission, load} -> {name, load.(user)} end)
  end

  # The widget itself is AppWeb.ReadinessLive; it loads its own data.
  defp readiness(user), do: %{user_id: user.id}

  defp clearances(user) do
    today = Date.utc_today()

    due =
      user
      |> latest_per_person(:security_clearance)
      |> Enum.filter(&expiring?(&1.data["expiryDate"], today))
      |> Enum.sort_by(& &1.data["expiryDate"])

    %{count: length(due), items: Enum.take(due, @list_limit)}
  end

  defp documents(user) do
    cutoff = Date.add(Date.utc_today(), @soon_days)

    due =
      IdentityDocument
      |> Ash.Query.filter(not is_nil(expires_on) and expires_on <= ^cutoff)
      |> Ash.Query.sort(expires_on: :asc)
      |> Ash.Query.load(:person)
      |> Ash.read!(actor: user)

    %{count: length(due), items: Enum.take(due, @list_limit)}
  end

  defp emergencies(user) do
    %{
      count:
        EmergencyAccess
        |> Ash.Query.filter(is_nil(reviewed_at))
        |> Ash.read!(actor: user)
        |> length()
    }
  end

  defp requests(user), do: %{count: user |> AccessRequest.pending() |> length()}

  # The newest record of `kind` for each person the user can see.
  defp latest_per_person(user, kind) do
    PersonRecord
    |> Ash.Query.filter(kind == ^kind)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.load(:person)
    |> Ash.read!(actor: user)
    |> Enum.uniq_by(& &1.person_id)
  end

  defp expiring?(nil, _today), do: false

  defp expiring?(value, today) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.diff(date, today) <= @soon_days
      _ -> false
    end
  end
end
