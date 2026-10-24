defmodule App.Documents.Deputies do
  @moduledoc """
  Stand-ins (docs/design/inbox-first.md §Stand-ins): who may decide route
  steps for whom on a day. A `App.Documents.Deputy` with dates is active
  between them; one without dates whenever its user is away (recorded
  leave or business trip, `App.Leave.CalendarData.away_on/2`). Read as the
  system: callers show only documents the deputy may act on.
  """

  require Ash.Query

  alias App.Accounts.User
  alias App.Documents.{Access, Deputy, Types}
  alias App.Leave.CalendarData

  @doc "Whether `deputy` is active on `date`; `away?` — its user is away then."
  @spec active?(map(), Date.t(), boolean()) :: boolean()
  def active?(%{starts_on: nil, ends_on: nil}, _date, away?), do: away?

  def active?(%{starts_on: first, ends_on: last}, date, _away?),
    do: Date.compare(date, first) != :lt and Date.compare(date, last) != :gt

  @doc "Users `deputy_id` stands in for on `date`."
  @spec principals(String.t(), Date.t()) :: [String.t()]
  def principals(deputy_id, date \\ Date.utc_today()) do
    Deputy
    |> Ash.Query.filter(deputy_id == ^deputy_id)
    |> Ash.read!(authorize?: false)
    |> only_active(date)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end

  @doc "Active deputies of each of `user_ids` on `date`, as `%{user_id => [deputy_id]}`."
  @spec of([String.t()], Date.t()) :: %{String.t() => [String.t()]}
  def of(user_ids, date \\ Date.utc_today()) do
    Deputy
    |> Ash.Query.filter(user_id in ^Enum.reject(user_ids, &is_nil/1))
    |> Ash.read!(authorize?: false)
    |> only_active(date)
    |> Enum.group_by(& &1.user_id, & &1.deputy_id)
  end

  @doc """
  Whether `actor` may decide `step` of `document` for its assignee: an
  active deputy of the assignee who holds the step's permission for this
  document themselves.
  """
  @spec may_act?(map(), map(), map()) :: boolean()
  def may_act?(actor, step, document) do
    step.assignee_id != nil and step.assignee_id in principals(actor.id) and
      holds_step?(actor, step, document)
  end

  @doc "Whether `actor` holds the permission of `step`'s route entry for `document`."
  @spec holds_step?(map(), map(), map()) :: boolean()
  def holds_step?(actor, step, document) do
    case Enum.find(Types.route(document.type), &(&1["label"] == step.label)) do
      nil -> false
      entry -> Access.holds?(actor, entry["permission"], document)
    end
  end

  @doc """
  The actor's deputies (`:mine`, with `deputy` loaded) and the users they
  stand in for (`:standing_in`, with `user` loaded), each with `active?`
  today. Names only — read as the system after filtering on the actor.
  """
  @spec overview(map()) :: %{mine: [map()], standing_in: [map()]}
  def overview(actor) do
    today = Date.utc_today()
    principals = principals(actor.id, today)

    mine =
      Deputy
      |> Ash.Query.filter(user_id == ^actor.id)
      |> Ash.Query.load(:deputy)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false)

    active_mine = actor.id |> List.wrap() |> of(today) |> Map.get(actor.id, [])

    standing_in =
      Deputy
      |> Ash.Query.filter(deputy_id == ^actor.id)
      |> Ash.Query.load(:user)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false)

    %{
      mine: Enum.map(mine, &Map.put(&1, :active?, &1.deputy_id in active_mine)),
      standing_in: Enum.map(standing_in, &Map.put(&1, :active?, &1.user_id in principals))
    }
  end

  defp only_active([], _date), do: []

  defp only_active(deputies, date) do
    open_ended = deputies |> Enum.filter(&is_nil(&1.starts_on)) |> Enum.map(& &1.user_id)
    away = away_users(open_ended, date)
    Enum.filter(deputies, &active?(&1, date, &1.user_id in away))
  end

  # Users (of `user_ids`) whose person is away on `date`.
  defp away_users([], _date), do: []

  defp away_users(user_ids, date) do
    users =
      User
      |> Ash.Query.filter(id in ^Enum.uniq(user_ids) and not is_nil(person_id))
      |> Ash.read!(authorize?: false)

    away = CalendarData.away_on(Enum.map(users, & &1.person_id), date)
    for user <- users, user.person_id in away, do: user.id
  end
end
