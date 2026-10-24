defmodule App.Accounts.AccessRequest do
  @moduledoc """
  Second approval for sensitive access (docs/design/access-control-phase2.md
  When `App.Access.second_approval_required?/0` is on, granting a
  sensitive profile or the admin role creates a pending request; another
  user with `users.manage` — never the requester — approves it, which
  applies the change, or rejects it.
  """
  use Ash.Resource,
    domain: App.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "access_requests"
    repo App.Repo
  end

  policies do
    policy action_type([:read, :create]) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end

    # Four eyes: the requester can't decide their own request.
    policy action([:approve, :reject]) do
      forbid_if expr(requested_by_id == ^actor(:id))
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    # Requested promotion, if any (only :admin needs approval).
    attribute :role, :atom do
      public? true
      constraints one_of: App.Access.roles()
    end

    # Sensitive profiles to add.
    attribute :profiles, {:array, :atom} do
      allow_nil? false
      public? true
      default []
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :rejected]
    end

    attribute :requested_by_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :requested_by_email, :string do
      allow_nil? false
      public? true
    end

    attribute :decided_by_email, :string do
      public? true
    end

    attribute :decided_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :requested_at
  end

  actions do
    defaults [:read]

    create :request do
      accept [:user_id, :role, :profiles]

      change fn changeset, %{actor: actor} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:requested_by_id, actor.id)
        |> Ash.Changeset.force_change_attribute(:requested_by_email, to_string(actor.email))
      end
    end

    update :approve do
      require_atomic? false
      change set_attribute(:status, :approved)
      change {__MODULE__.Decide, apply?: true}
    end

    update :reject do
      require_atomic? false
      change set_attribute(:status, :rejected)
      change {__MODULE__.Decide, apply?: false}
    end
  end

  @doc "Pending requests, oldest first."
  @spec pending(map()) :: [struct()]
  def pending(actor) do
    __MODULE__
    |> Ash.Query.filter(status == :pending)
    |> Ash.Query.sort(requested_at: :asc)
    |> Ash.read!(actor: actor)
  end

  defmodule Decide do
    @moduledoc """
    Records who decided and when; on approval, applies the requested role
    and profiles to the user, as the approver.
    """
    use Ash.Resource.Change

    @impl true
    def change(changeset, opts, %{actor: actor}) do
      changeset
      |> Ash.Changeset.force_change_attribute(:decided_by_email, to_string(actor.email))
      |> Ash.Changeset.force_change_attribute(:decided_at, DateTime.utc_now())
      |> Ash.Changeset.before_action(fn changeset ->
        if changeset.data.status == :pending,
          do: changeset,
          else: Ash.Changeset.add_error(changeset, message: "request already decided")
      end)
      |> Ash.Changeset.after_action(fn _changeset, request ->
        if opts[:apply?], do: apply_to_user(request, actor)
        {:ok, request}
      end)
    end

    defp apply_to_user(request, actor) do
      user = Ash.get!(App.Accounts.User, request.user_id, actor: actor)

      changes = %{
        role: request.role || user.role,
        profiles: Enum.uniq(user.profiles ++ request.profiles)
      }

      user
      |> Ash.Changeset.for_update(:update_access, changes, actor: actor)
      |> Ash.update!()
    end
  end
end
