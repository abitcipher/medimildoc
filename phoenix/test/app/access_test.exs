defmodule App.AccessTest do
  use ExUnit.Case, async: true

  alias App.Access

  defp user(role, profiles \\ []), do: %App.Accounts.User{role: role, profiles: profiles}

  defp with_admin_full_access(value, fun) do
    App.Access.put_admin_full_data_access_override(value)

    try do
      fun.()
    after
      App.Access.put_admin_full_data_access_override(nil)
    end
  end

  test "no actor has no permissions" do
    refute Access.can?(nil, "people.read")
  end

  test "a role grants its own bundle and nothing else" do
    assert Access.can?(user(:viewer), "people.read")
    refute Access.can?(user(:viewer), "people.write")
    refute Access.can?(user(:viewer), "people.private.read")
    assert Access.can?(user(:hr), "people.private.write")
    refute Access.can?(user(:hr), "medical.read")
  end

  test "profiles add their bundles on top of the role" do
    refute Access.can?(user(:viewer), "medical.read")
    assert Access.can?(user(:viewer, [:clinician]), "medical.read")
    assert Access.can?(user(:viewer, [:clinician, :ciso]), "audit.read")
  end

  test "a line commander sees readiness but nothing clinical" do
    commander = user(:viewer, [:line_commander])
    assert Access.can?(commander, "readiness.read")
    refute Access.can?(commander, "medical.read")
    refute Access.can?(commander, "vetting.read")
  end

  test "admin holds every permission only while the development flag is on" do
    with_admin_full_access(true, fn ->
      for permission <- Access.permissions(), do: assert(Access.can?(user(:admin), permission))
    end)

    with_admin_full_access(false, fn ->
      assert Access.can?(user(:admin), "users.manage")
      refute Access.can?(user(:admin), "medical.read")
      refute Access.can?(user(:admin), "audit.read")
    end)
  end

  test "an unknown permission name raises instead of quietly returning false" do
    assert_raise ArgumentError, ~r/unknown permission/, fn ->
      Access.can?(user(:admin), "people.raed")
    end
  end
end
