defmodule App.Access.PolicyMatrixTest do
  @moduledoc """
  Every base role and access profile against every resource action that
  step 1 of docs/design/access-control-phase1.md puts behind a permission.
  Expectations come from `App.Access` itself (i.e. from
  `priv/access_profiles.json`), so the policies and the config can't
  drift apart. The development admin flag is switched off here so the
  admin row shows the go-live behaviour.
  """
  use ExUnit.Case, async: true

  alias App.Access
  alias App.Access.RecordAccess
  alias App.Accounts.User
  alias App.Audit.{AccessLog, ChangeConflict}
  alias App.People.{Assignment, IdentityDocument, Organization, Person, PersonIdentifier}
  alias App.People.{BiometricRecord, PersonRecord, PersonRecordSchema, Position}

  @people [Person, Organization, Position, Assignment]
  @private [PersonIdentifier, IdentityDocument, BiometricRecord]

  @checks ((for resource <- @people do
              [{resource, :read, "people.read"}, {resource, :create, "people.write"}]
            end) ++
             (for resource <- @private do
                [
                  {resource, :read, "people.private.read"},
                  {resource, :create, "people.private.write"}
                ]
              end))
          |> List.flatten()
          |> Kernel.++([{ChangeConflict, :read, "audit.read"}, {AccessLog, :read, "audit.read"}])

  setup do
    App.Access.put_admin_full_data_access_override(false)
    :ok
  end

  actors =
    Enum.map(Access.roles(), &{"role #{&1}", &1, []}) ++
      Enum.map(Access.profiles(), &{"profile #{&1}", :viewer, [&1]})

  for {name, role, profiles} <- actors do
    @role role
    @profiles profiles

    test "#{name} is allowed exactly what its permissions say" do
      actor = %User{id: Ash.UUIDv7.generate(), role: @role, profiles: @profiles}

      # Without people.read a Person read is still a filter — one's own
      # person (AppWeb.PersonRolePagesTest covers it against real rows).
      for {resource, action, permission} <- @checks,
          {resource, action, Access.can?(actor, permission)} != {Person, :read, false} do
        expected = Access.can?(actor, permission)

        assert Ash.can?({resource, action}, actor, maybe_is: false) == expected,
               "#{inspect(resource)} #{action}: expected #{expected} (#{permission})"
      end

      # PersonRecord: writing needs the kind's category permission. Reads
      # are a filter; App.Access.RecordVisibilityTest covers them against
      # real rows.
      # The target person here is in nobody's unit, so a kind the actor may
      # write only within their unit is refused.
      for kind <- PersonRecordSchema.kinds() do
        expected = RecordAccess.kind_scope(actor, kind, :write) == :global
        input = %{kind: kind, person_id: Ash.UUIDv7.generate(), data: %{}}

        assert Ash.can?({PersonRecord, :create, input}, actor, maybe_is: false) == expected,
               "PersonRecord create #{kind}: expected #{expected}"
      end

      expected = Access.can?(actor, "users.manage")
      target = %User{id: Ash.UUIDv7.generate(), role: :viewer, profiles: []}

      assert Ash.can?({target, :update_access}, actor, maybe_is: false) == expected,
             "User update_access: expected #{expected} (users.manage)"
    end
  end
end
