import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/app start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :app, AppWeb.Endpoint, server: true
end

config :app, AppWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :app, AppWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/app_web/router\.ex$"E,
        ~r"lib/app_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :app, App.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Encryption at rest (App.Vault, docs/design/access-control-phase1.md
  # 32 random bytes, base64: `openssl rand -base64 32`. Losing it
  # makes every encrypted field unreadable — keep a copy outside the VPS.
  # Rotation: infra/README.md.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: openssl rand -base64 32
      """

  # Compose passes an unset variable as an empty string: treat "" as unset.
  env = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  # The zone of local times in records (App.Fhir.Map).
  config :app, app_time_zone: env.("APP_TIME_ZONE") || "Europe/Kyiv"

  # The event log (docs/design/events-and-person-login.md): the
  # instance in each event's source, /hrda/<instance>/<domain>.
  config :app, events_instance: env.("EVENTS_INSTANCE") || env.("PHX_HOST") || "local"

  # Notifications (docs/design/search-timeline-notifications.md): RabbitMQ
  # carries the outbox to the dispatcher, Apprise API delivers. Without
  # RABBITMQ_URL messages stay in the app. Each NOTIFY_*_URL is the Apprise
  # URL of the sender for that channel (see App.Notify.Apprise); unset =
  # that channel is not used. APP_URL (links in messages and in the FHIR
  # API) defaults to https://PHX_HOST.
  config :app, App.Notify,
    rabbitmq_url: env.("RABBITMQ_URL"),
    apprise_url: env.("APPRISE_URL") || "http://apprise:8000",
    app_url: env.("APP_URL") || "https://#{env.("PHX_HOST") || "example.com"}",
    channels:
      %{
        email: System.get_env("NOTIFY_EMAIL_URL"),
        telegram: System.get_env("NOTIFY_TELEGRAM_URL"),
        signal: System.get_env("NOTIFY_SIGNAL_URL"),
        matrix: System.get_env("NOTIFY_MATRIX_URL")
      }
      |> Map.reject(fn {_kind, url} -> url in [nil, ""] end)

  config :app, App.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12}
    ]

  # docs/design/access-control-phase1.md . Off unless explicitly set,
  # so a forgotten variable fails closed; infra/.env sets it to true during
  # development. Turning it off is the first go-live checklist item.
  config :app,
         :admin_full_data_access,
         System.get_env("ADMIN_FULL_DATA_ACCESS") in ~w(true 1)

  # docs/design/access-control-phase2.md. Off while there is a single
  # admin; turn on before go-live (infra/README.md checklist).
  config :app,
         :require_second_approval,
         System.get_env("REQUIRE_SECOND_APPROVAL") in ~w(true 1)

  # Must match the Apps Script shim's `SHARED_SECRET` script
  # property exactly (see apps_script/README.md) — no dev-only fallback here.
  config :app,
         :sheets_shared_secret,
         System.get_env("SHEETS_SHARED_SECRET") ||
           raise("environment variable SHEETS_SHARED_SECRET is missing")

  # IHDS reference-data service (docs/design/reference-data-and-files.md).
  config :app, :ihds_url, System.get_env("IHDS_URL", "http://ihds:4100")

  # File storage in RustFS (App.Storage; infra/docker-compose.yml).
  config :app, :storage,
    bucket: System.get_env("STORAGE_BUCKET", "hrda-files"),
    endpoint: System.get_env("STORAGE_ENDPOINT", "http://rustfs:9000"),
    public_url: System.get_env("STORAGE_PUBLIC_URL") || "https://#{host}",
    access_key:
      System.get_env("STORAGE_ACCESS_KEY") ||
        raise("environment variable STORAGE_ACCESS_KEY is missing"),
    secret_key:
      System.get_env("STORAGE_SECRET_KEY") ||
        raise("environment variable STORAGE_SECRET_KEY is missing"),
    region: "us-east-1"

  config :app, AppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :app,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # Google OAuth for the standalone forms UI (App.Accounts.User) — from
  # Google Cloud Console (APIs & Services -> Credentials). GOOGLE_REDIRECT_URI
  # is this deploy's own https://<host>/auth/ (the *base*, including the
  # router's "/auth" prefix and a trailing slash — see config/dev.exs's
  # comment for why both are required); AshAuthentication appends
  # user/google/callback itself, and the resulting full URL is what goes
  # in Google Cloud Console's "Authorized redirect URIs".
  config :app,
    google_client_id:
      System.get_env("GOOGLE_CLIENT_ID") ||
        raise("Missing environment variable `GOOGLE_CLIENT_ID`!"),
    google_client_secret:
      System.get_env("GOOGLE_CLIENT_SECRET") ||
        raise("Missing environment variable `GOOGLE_CLIENT_SECRET`!"),
    google_redirect_uri:
      System.get_env("GOOGLE_REDIRECT_URI") ||
        raise("Missing environment variable `GOOGLE_REDIRECT_URI`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :app, AppWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :app, AppWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :app, App.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
