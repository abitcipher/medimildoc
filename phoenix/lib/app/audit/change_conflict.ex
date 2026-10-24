defmodule App.Audit.ChangeConflict do
  @moduledoc """
  One row per detected write collision — never
  written by a user action, only by `App.Audit.DetectChangeConflict`
  running as part of an editable resource's own `:update` action.

  Is explicit that the *resolution* stays simple (last-write-wins,
  never rejected) — this resource exists purely for the "log the incident"
  half of that decision, so an admin can later see that it happened, not
  to change what happens when it does.
  """
  use Ash.Resource,
    otp_app: :app,
    domain: App.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "change_conflicts"
    repo App.Repo
  end

  policies do
    # Only App.Audit.DetectChangeConflict creates these, always with
    # authorize?: false (it runs inside someone else's update action, not
    # as a user-facing create) — so no policy needs to authorize :create
    # for a normal actor; the default (no matching policy) denies it,
    # which is correct: nobody should be able to fabricate a conflict
    # record directly.
    policy action_type(:read) do
      authorize_if {App.Access.Checks.HasPermission, permission: "audit.read"}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # The Ash resource module as a string (e.g. "App.People.Person") — a
    # plain string rather than a closed `one_of` atom, since the set of
    # audited resources can grow ("modular growth") without
    # needing a matching change here every time.
    attribute :resource, :string do
      allow_nil? false
      public? true
    end

    attribute :record_id, :uuid do
      allow_nil? false
      public? true
    end

    # Nullable: the actor is always present in practice (every editable
    # resource's :update policy already requires :admin/:hr,
    # but never assume that holds forever — this table should never
    # itself become the thing that crashes if it doesn't.
    attribute :actor_id, :uuid do
      allow_nil? true
      public? true
    end

    # Denormalized on purpose: readable even if the actor's own User row
    # is later deleted (no user-delete action exists yet, but this
    # shouldn't need revisiting if one ever does).
    attribute :actor_email, :string do
      allow_nil? true
      public? true
    end

    attribute :expected_updated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "The record's updated_at when the write that caused this was loaded/built."
    end

    attribute :found_updated_at, :utc_datetime_usec do
      allow_nil? false
      public? true

      description "The record's actual updated_at at write time — different means someone else wrote in between."
    end

    create_timestamp :detected_at
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :resource,
        :record_id,
        :actor_id,
        :actor_email,
        :expected_updated_at,
        :found_updated_at
      ]
    end
  end
end
