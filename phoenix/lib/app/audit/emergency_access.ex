defmodule App.Audit.EmergencyAccess do
  @moduledoc """
  Break the Glass (docs/design/access-control-phase2.md): a user with
  `btg.invoke` who can't otherwise see a person's clinical data (outside
  their unit) gets that person's allergy records for 60 minutes, after
  giving a reason. Every read during it goes to the access log with the
  reason; the CISO reviews each emergency access afterwards.

  Rows are never deleted. `invoke` is the only way to create one and takes
  the actor from the context, not from input.
  """
  use Ash.Resource,
    domain: App.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr
  require Ash.Query

  @duration_minutes 60

  @doc "How long an emergency access lasts."
  def duration_minutes, do: @duration_minutes

  postgres do
    table "emergency_accesses"
    repo App.Repo
  end

  policies do
    policy action(:invoke) do
      authorize_if {App.Access.Checks.HasPermission, permission: "btg.invoke"}
    end

    # The CISO sees all; everyone sees their own.
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
      authorize_if expr(actor_id == ^actor(:id))
    end

    policy action(:review) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :actor_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :actor_email, :string do
      allow_nil? false
      public? true
    end

    attribute :person_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 10, max_length: 500
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :reviewed_by_email, :string do
      public? true
    end

    attribute :reviewed_at, :utc_datetime_usec do
      public? true
    end

    attribute :review_note, :string do
      public? true
    end

    create_timestamp :granted_at
  end

  actions do
    defaults [:read]

    create :invoke do
      accept [:person_id, :reason]

      change fn changeset, context ->
        actor = context.actor

        changeset
        |> Ash.Changeset.force_change_attribute(:actor_id, actor && actor.id)
        |> Ash.Changeset.force_change_attribute(:actor_email, actor && to_string(actor.email))
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(DateTime.utc_now(), @duration_minutes * 60, :second)
        )
      end
    end

    update :review do
      accept [:review_note]
      require_atomic? false

      change fn changeset, context ->
        actor = context.actor

        changeset
        |> Ash.Changeset.force_change_attribute(:reviewed_by_email, to_string(actor.email))
        |> Ash.Changeset.force_change_attribute(:reviewed_at, DateTime.utc_now())
      end
    end
  end

  @doc "Ids of people `actor` currently has emergency access to."
  @spec active_person_ids(map() | nil) :: [Ash.UUID.t()]
  def active_person_ids(%{id: actor_id}) do
    now = DateTime.utc_now()

    __MODULE__
    |> Ash.Query.filter(actor_id == ^actor_id and expires_at > ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.person_id)
    |> Enum.uniq()
  end

  def active_person_ids(_actor), do: []

  @doc "The active emergency access of `actor` for `person_id`, if any."
  @spec active_for(map() | nil, Ash.UUID.t()) :: struct() | nil
  def active_for(%{id: actor_id}, person_id) do
    now = DateTime.utc_now()

    __MODULE__
    |> Ash.Query.filter(actor_id == ^actor_id and person_id == ^person_id and expires_at > ^now)
    |> Ash.Query.sort(expires_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  def active_for(_actor, _person_id), do: nil
end
