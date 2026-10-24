defmodule App.Access do
  @moduledoc """
  Permission model (docs/design/access-control-phase1.md).

  A user's effective permissions are the union of their base `role`'s
  bundle and the bundle of each access profile in `profiles`. Both
  bundles are declared in `priv/access_profiles.json` — data only, never
  logic — and validated here at compile time, so a typo in a permission
  name fails the build instead of silently granting or denying access.

  While `config :app, :admin_full_data_access` is true (development and
  testing, see  of the design), role `:admin` additionally holds every
  permission. Turning it off before go-live is one env change
  (`ADMIN_FULL_DATA_ACCESS=false`).

  Enforcement lives in each resource's Ash policies through
  `App.Access.Checks.HasPermission`; `can?/2` here is also what the web
  layer uses to hide controls, which is UX only.
  """

  @path Application.app_dir(:app, "priv/access_profiles.json")
  @external_resource @path

  @raw @path |> File.read!() |> Jason.decode!()

  @permissions @raw["permissions"] |> Map.keys() |> Enum.sort()

  # :person — an account made for a PersonID sign-in: no permissions, only
  # the person's own data (docs/design/events-and-person-login.md).
  @roles [:admin, :hr, :viewer, :person]

  unless @raw["roles"] |> Map.keys() |> Enum.sort() ==
           @roles |> Enum.map(&Atom.to_string/1) |> Enum.sort() do
    raise "priv/access_profiles.json: \"roles\" must define exactly #{inspect(@roles)}"
  end

  @role_permissions Map.new(@raw["roles"], fn {role, perms} ->
                      {String.to_atom(role), perms}
                    end)

  @profiles @raw["profiles"] |> Map.keys() |> Enum.sort() |> Enum.map(&String.to_atom/1)

  @profile_permissions Map.new(@raw["profiles"], fn {profile, %{"permissions" => perms}} ->
                         {String.to_atom(profile), perms}
                       end)

  @profile_labels Map.new(@raw["profiles"], fn {profile, %{"label" => label}} ->
                    {String.to_atom(profile), label}
                  end)

  # docs/design/access-control-phase2.md: "global" profiles apply to
  # everyone, "unit" profiles only to people in the user's unit and the
  # units below it.
  @profile_scopes Map.new(@raw["profiles"], fn {profile, %{"scope" => scope}} ->
                    unless scope in ["global", "unit"] do
                      raise "priv/access_profiles.json: #{profile} scope must be global or unit"
                    end

                    {String.to_atom(profile), String.to_atom(scope)}
                  end)

  for {owner, perms} <- Map.to_list(@role_permissions) ++ Map.to_list(@profile_permissions),
      perm <- perms,
      perm not in @permissions do
    raise "priv/access_profiles.json: #{owner} lists unknown permission #{inspect(perm)}"
  end

  # Bundles are kept as plain lists here and turned into MapSets at
  # runtime: MapSet is opaque, and a MapSet literal baked into a module
  # attribute trips Dialyzer.

  # Each PersonRecord kind belongs to one category
  # (docs/design/access-control-phase1.md); a category's records are
  # read and written with "<prefix>.read" / "<prefix>.write".
  @record_category_prefixes [
    personnel: "people",
    personnel_private: "people.hr_private",
    readiness: "readiness",
    care: "care",
    clearance: "clearance",
    medical: "medical",
    vetting: "vetting"
  ]

  for {category, prefix} <- @record_category_prefixes,
      suffix <- ["read", "write"],
      "#{prefix}.#{suffix}" not in @permissions do
    raise "record category #{category} needs permission #{prefix}.#{suffix}"
  end

  @type permission :: String.t()

  @doc "Every permission name declared in `priv/access_profiles.json`."
  @spec permissions() :: [permission()]
  def permissions, do: @permissions

  @permission_descriptions @raw["permissions"]

  @doc """
  English description of a permission from `priv/access_profiles.json`
  (also its Gettext msgid, translated at the web layer).
  """
  @spec permission_description(permission()) :: String.t()
  def permission_description(permission), do: Map.fetch!(@permission_descriptions, permission)

  @doc "The base roles, most privileged first."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "The access profile names a user can be given on top of a role."
  @spec profiles() :: [atom()]
  def profiles, do: @profiles

  @doc """
  A profile's English label — also its Gettext msgid, translated at the
  web layer.
  """
  @spec profile_label(atom()) :: String.t()
  def profile_label(profile), do: Map.fetch!(@profile_labels, profile)

  # docs/design/access-control-phase2.md: granting these (or the admin
  # role) needs a second approver when REQUIRE_SECOND_APPROVAL is on.
  @sensitive_profiles for {profile, %{"sensitive" => true}} <- @raw["profiles"],
                          do: String.to_atom(profile)

  @doc "Profiles whose grant needs a second approval (when that is required)."
  @spec sensitive_profiles() :: [atom()]
  def sensitive_profiles, do: @sensitive_profiles

  @second_approval_override_key {__MODULE__, :require_second_approval}

  @doc """
  Whether granting a sensitive profile or the admin role needs a second
  approver (`config :app, :require_second_approval`, from
  `REQUIRE_SECOND_APPROVAL`; off by default while there is one admin).
  """
  @spec second_approval_required?() :: boolean()
  def second_approval_required? do
    case Process.get(@second_approval_override_key) do
      nil -> Application.get_env(:app, :require_second_approval, false)
      value -> value
    end
  end

  @doc "Test helper: process-local override of `second_approval_required?/0`."
  @spec put_second_approval_override(boolean() | nil) :: :ok
  def put_second_approval_override(nil) do
    Process.delete(@second_approval_override_key)
    :ok
  end

  def put_second_approval_override(value) when is_boolean(value) do
    Process.put(@second_approval_override_key, value)
    :ok
  end

  @doc """
  The part of a change from `current` to `requested` (role and profiles)
  that needs a second approval: sensitive profiles being added, and a
  promotion to admin. Removing access never needs approval.
  """
  @spec needs_approval(map(), atom(), [atom()]) :: %{role: atom() | nil, profiles: [atom()]}
  def needs_approval(current, requested_role, requested_profiles) do
    added = requested_profiles -- List.wrap(current.profiles)

    %{
      role: if(requested_role == :admin and current.role != :admin, do: :admin),
      profiles: Enum.filter(added, &(&1 in @sensitive_profiles))
    }
  end

  @doc "Whether a profile applies to everyone (`:global`) or to the user's unit (`:unit`)."
  @spec profile_scope(atom()) :: :global | :unit
  def profile_scope(profile), do: Map.fetch!(@profile_scopes, profile)

  @doc """
  How far `user` holds `permission` (docs/design/access-control-phase2.md
  `:global` if the base role or any global profile grants it (or the
  development admin override is on), `:unit` if only unit-scoped profiles
  grant it, `:none` otherwise.
  """
  @spec permission_scope(map() | nil, permission()) :: :global | :unit | :none
  def permission_scope(nil, _permission), do: :none

  def permission_scope(%{role: role} = user, permission) do
    cond do
      role == :admin and admin_full_data_access?() -> :global
      MapSet.member?(role_permissions(role), permission) -> :global
      granted_by?(user, permission, :global) -> :global
      granted_by?(user, permission, :unit) -> :unit
      true -> :none
    end
  end

  defp granted_by?(user, permission, scope) do
    user
    |> Map.get(:profiles, [])
    |> List.wrap()
    |> Enum.any?(fn profile ->
      profile_scope(profile) == scope and
        MapSet.member?(profile_permissions(profile), permission)
    end)
  end

  @doc "Permissions granted by a base role alone (ignores the admin flag)."
  @spec role_permissions(atom()) :: MapSet.t(permission())
  def role_permissions(role), do: @role_permissions |> Map.fetch!(role) |> MapSet.new()

  @doc "Permissions granted by one access profile."
  @spec profile_permissions(atom()) :: MapSet.t(permission())
  def profile_permissions(profile),
    do: @profile_permissions |> Map.fetch!(profile) |> MapSet.new()

  @doc """
  Effective permissions of `user` (an `App.Accounts.User` or `nil`). `nil`
  — no signed-in actor — has none.
  """
  @spec permissions_for(map() | nil) :: MapSet.t(permission())
  def permissions_for(nil), do: MapSet.new()

  def permissions_for(%{role: :admin} = user) do
    if admin_full_data_access?(), do: MapSet.new(@permissions), else: combined(user)
  end

  def permissions_for(%{role: _role} = user), do: combined(user)

  defp combined(%{role: role} = user) do
    user
    |> Map.get(:profiles, [])
    |> List.wrap()
    |> Enum.reduce(role_permissions(role), &MapSet.union(&2, profile_permissions(&1)))
  end

  @doc """
  Whether `user` holds `permission`. Raises on a permission name that
  isn't declared, so a misspelled check fails loudly in tests instead of
  quietly returning false.
  """
  @spec can?(map() | nil, permission()) :: boolean()
  def can?(user, permission) when permission in @permissions do
    MapSet.member?(permissions_for(user), permission)
  end

  def can?(_user, permission) do
    raise ArgumentError, "unknown permission #{inspect(permission)}"
  end

  @doc "The record categories every `PersonRecord` kind must belong to."
  @spec record_categories() :: [atom()]
  def record_categories, do: Keyword.keys(@record_category_prefixes)

  @doc "The permission needed to read or write records of `category`."
  @spec record_category_permission(atom(), :read | :write) :: permission()
  def record_category_permission(category, access) when access in [:read, :write] do
    "#{Keyword.fetch!(@record_category_prefixes, category)}.#{access}"
  end

  @admin_override_key {__MODULE__, :admin_full_data_access}

  @doc """
  Whether role `:admin` currently holds every permission. Read at
  runtime so the deployed release can switch it off by env var.
  """
  @spec admin_full_data_access?() :: boolean()
  def admin_full_data_access? do
    # A process-local override lets a test see go-live behaviour without
    # changing the global setting under tests running in parallel.
    case Process.get(@admin_override_key) do
      nil -> Application.get_env(:app, :admin_full_data_access, false)
      value -> value
    end
  end

  @doc """
  Test helper: overrides `admin_full_data_access?/0` for the calling process
  only (`nil` removes the override).
  """
  @spec put_admin_full_data_access_override(boolean() | nil) :: :ok
  def put_admin_full_data_access_override(nil) do
    Process.delete(@admin_override_key)
    :ok
  end

  def put_admin_full_data_access_override(value) when is_boolean(value) do
    Process.put(@admin_override_key, value)
    :ok
  end
end
