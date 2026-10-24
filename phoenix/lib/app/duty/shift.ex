defmodule App.Duty.Shift do
  @moduledoc """
  One person on one duty on one day (docs/design/duty-roster.md), in the
  roster of a unit. A person has at most one duty a day. Planned by HR
  (`people.write`) or a commander (`orders.sign`) whose unit covers the
  person (`App.Duty.Checks.MayPlan`); read by them, by those who see
  readiness in scope, and by the person themselves.
  """
  use Ash.Resource,
    domain: App.Duty,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias App.Access.Checks.ScopedPermission
  alias App.Duty.Types

  postgres do
    table "duty_shifts"
    repo App.Repo

    references do
      reference :person, on_delete: :delete
      reference :organization, on_delete: :delete
    end

    custom_indexes do
      index [:organization_id, :date]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(person_id == ^actor(:person_id))
      authorize_if {ScopedPermission, permission: "people.write"}
      authorize_if {ScopedPermission, permission: "orders.sign"}
      authorize_if {ScopedPermission, permission: "readiness.read"}
    end

    policy action_type([:create, :destroy]) do
      authorize_if App.Duty.Checks.MayPlan
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :date, :date, allow_nil?: false, public?: true
    attribute :duty_type, :string, allow_nil?: false, public?: true

    attribute :note, :string do
      public? true
      constraints max_length: 200
    end

    attribute :created_by_email, :string, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :person, App.People.Person, allow_nil?: false, public?: true
    # The unit whose roster it is in.
    belongs_to :organization, App.People.Organization, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:date, :duty_type, :note, :person_id, :organization_id]
      validate one_of(:duty_type, Types.ids())

      change fn changeset, %{actor: actor} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :created_by_email,
          actor && actor.email && to_string(actor.email)
        )
      end
    end
  end

  identities do
    identity :one_duty_a_day, [:person_id, :date]
  end
end
