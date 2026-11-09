defmodule App.Settings do
  @moduledoc """
  System settings (user, 2026-09-29: FSDC "enabled or disabled via
  parameters in the main system settings"): a small key/value store, read
  often and changed rarely, so values are cached in `:persistent_term` and
  the cache is dropped on every change.

  Known keys and their defaults are declared here; an unknown key raises.
  """
  use Ash.Domain

  resources do
    resource App.Settings.Setting
  end

  @defaults %{
    # docs/design/data-consistency.md: rules are evaluated only when on.
    "fsdc.enabled" => false,
    # docs/design/leave-calendar.md: how much of a unit may be away at once
    # (in per cent; at least one person always may).
    "leave.max_away_percent" => 30,
    # docs/design/inbox-first.md: days an approval or signature step may
    # wait before it is overdue.
    "documents.step_days" => 3,
    # docs/design/sheets-ui.md §Sidebar layout: sidebar items hidden per
    # role (`%{"hr" => ["sheet", ...]}`), AppWeb.SidebarLayout.
    "sheets.sidebar_hidden" => %{},
    # docs/design/events-and-person-login.md: the general event log, and
    # publishing it to external subscribers (switching either is always
    # logged, App.EventLog).
    "events.logging" => true,
    "events.publishing" => false,
    # signing in with a PersonID and a password.
    "auth.person_login" => true
  }

  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@defaults)

  @doc "The value of `key` (its default when never set)."
  @spec get(String.t()) :: term()
  def get(key) do
    default = Map.fetch!(@defaults, key)

    # Tests run in sandboxed transactions: a cached value from one test
    # must not leak into another (config :app, :settings_cache, false).
    cached =
      if Application.get_env(:app, :settings_cache, true),
        do: :persistent_term.get({__MODULE__, key}, :unset),
        else: :unset

    case cached do
      :unset ->
        value =
          case Ash.get(App.Settings.Setting, key, authorize?: false) do
            {:ok, %{value: %{"v" => value}}} -> value
            _ -> default
          end

        if Application.get_env(:app, :settings_cache, true),
          do: :persistent_term.put({__MODULE__, key}, value)

        value

      value ->
        value
    end
  end

  @doc "Sets `key` as `actor` (needs `settings.manage`)."
  @spec put(String.t(), term(), map()) :: :ok | {:error, term()}
  def put(key, value, actor) do
    # Unknown keys raise.
    _default = Map.fetch!(@defaults, key)

    App.Settings.Setting
    |> Ash.Changeset.for_create(:put, %{key: key, value: %{"v" => value}}, actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _} ->
        :persistent_term.erase({__MODULE__, key})
        :ok

      error ->
        error
    end
  end

  @doc "FSDC on? (`fsdc.enabled`), unless switched off for this process (`without_fsdc/1`)."
  @spec fsdc?() :: boolean()
  def fsdc?, do: Process.get({__MODULE__, :fsdc_off}) != true and get("fsdc.enabled") == true

  @doc """
  Runs `fun` with the FSDC checks off in this process only: generating
  synthetic data plants violations on purpose and must not raise
  incidents while it does.
  """
  @spec without_fsdc((-> result)) :: result when result: term()
  def without_fsdc(fun) do
    previous = Process.put({__MODULE__, :fsdc_off}, true)

    try do
      fun.()
    after
      if previous,
        do: Process.put({__MODULE__, :fsdc_off}, previous),
        else: Process.delete({__MODULE__, :fsdc_off})
    end
  end
end
