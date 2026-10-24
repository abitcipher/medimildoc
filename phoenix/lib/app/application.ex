defmodule App.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Registers config :cinder, :filters (the person_id filter)
    # — a plain config call, not something that needs
    # supervising; must run before any Cinder.collection mounts, so
    # here rather than lazily on first use.
    Cinder.setup()
    warn_if_admin_full_data_access()

    children =
      [
        AppWeb.Telemetry,
        App.Repo,
        # Encryption at rest; must be up before anything reads or writes
        # an encrypted field.
        App.Vault,
        {DNSCluster, query: Application.get_env(:app, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: App.PubSub},
        # Reference data from IHDS (App.IHDS), cached per dataset/language.
        App.Cache,
        # Fire-and-forget work, such as telling IHDS about saved values.
        {Task.Supervisor, name: App.TaskSupervisor},
        # Start a worker by calling: App.Worker.start_link(arg)
        # {App.Worker, arg},
        # Failed PersonID sign-ins (docs/design/events-and-person-login.md).
        App.Accounts.Throttle,
        # Start to serve requests, typically the last entry
        AppWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :app]}
      ] ++ notify_workers() ++ reminders()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: App.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Notifications (docs/design/search-timeline-notifications.md): the
  # outbox publisher and the dispatcher, when RabbitMQ is configured and
  # this is the server (release tasks switch them off).
  defp notify_workers do
    config = Application.get_env(:app, App.Notify, [])

    case {config[:rabbitmq_url], Keyword.get(config, :workers, true)} do
      {url, true} when is_binary(url) ->
        # The event publisher too (docs/design/events-and-person-login.md).
        [
          {App.Notify.Outbox, url: url},
          {App.Notify.Dispatcher, url: url},
          {App.Events.Publisher, url: url}
        ]

      _ ->
        []
    end
  end

  # Overdue reminders (docs/design/inbox-first.md), on the server only:
  # off in tests and release tasks.
  defp reminders do
    if Keyword.get(Application.get_env(:app, App.Documents.Reminders, []), :enabled, true),
      do: [App.Documents.Reminders.Ticker],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AppWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # docs/design/access-control-phase1.md : make the development-only
  # admin override impossible to miss in a production log.
  defp warn_if_admin_full_data_access do
    if Application.get_env(:app, :env) == :prod and App.Access.admin_full_data_access?() do
      require Logger

      Logger.warning(
        "ADMIN_FULL_DATA_ACCESS is on: role :admin can read all medical and vetting data. " <>
          "Turn it off before go-live."
      )
    end
  end
end
