defmodule App.Documents.Deputy do
  @moduledoc """
  A stand-in for approvals and signatures (docs/design/inbox-first.md
  §Stand-ins): `deputy` may decide the route steps waiting for `user` —
  between `starts_on` and `ends_on`, or, with neither date, whenever the
  user is away (recorded leave or business trip). The deputy acts only on
  documents where they hold the step's permission themselves; the step
  records who decided (`App.Documents.Deputies`).

  Set by the user for themselves, or by an administrator
  (`users.manage`). Read by both users concerned and administrators.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Accounts.User
  alias App.Documents.DeputyCandidates

  postgres do
    table "document_deputies"
    repo App.Repo

    references do
      reference :user, on_delete: :delete
      reference :deputy, on_delete: :delete
    end

    custom_indexes do
      index [:user_id]
      index [:deputy_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id) or deputy_id == ^actor(:id))
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end

    policy action_type([:create, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :starts_on, :date, public?: true
    attribute :ends_on, :date, public?: true

    attribute :note, :string do
      public? true
      constraints max_length: 200
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, App.Accounts.User, allow_nil?: false, public?: true
    belongs_to :deputy, App.Accounts.User, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:user_id, :deputy_id, :starts_on, :ends_on, :note]

      validate fn changeset, _context ->
        get = &Ash.Changeset.get_attribute(changeset, &1)

        cond do
          get.(:user_id) == get.(:deputy_id) ->
            {:error, field: :deputy_id, message: "a deputy must be someone else"}

          is_nil(get.(:starts_on)) != is_nil(get.(:ends_on)) ->
            {:error, field: :ends_on, message: "give both dates, or neither (whenever away)"}

          get.(:starts_on) && Date.compare(get.(:ends_on), get.(:starts_on)) == :lt ->
            {:error, field: :ends_on, message: "the last day is before the first day"}

          true ->
            :ok
        end
      end

      # A deputy who holds none of the user's route permissions could act
      # on nothing (users are read in a hook, not in the change body).
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          user = Ash.get!(User, changeset.attributes.user_id, authorize?: false)
          deputy_id = changeset.attributes.deputy_id

          if Enum.any?(DeputyCandidates.for_user(user), &(&1.id == deputy_id)),
            do: changeset,
            else:
              Ash.Changeset.add_error(changeset,
                field: :deputy_id,
                message:
                  "the deputy holds none of the permissions needed to approve or sign for you"
              )
        end)
      end
    end
  end
end
