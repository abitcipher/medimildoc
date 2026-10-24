import Config
config :bcrypt_elixir, log_rounds: 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :app, App.Repo,
  username: "postgres",
  password: "postgres",
  # CI runs tests inside a container where Postgres is the "postgres" service.
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "app_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :app, AppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lgvqk/5AZrUMWRyYR8rpoT/Iw11hVYHd2/x6zdCw/eAmYbjhoSOyBKp84Y7y95ZF",
  server: false

# In test we don't send emails
config :app, App.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# See config/dev.exs — same idea, fixed value so tests can mint fixture
# tokens (test/support/sheets_token_fixtures.ex) without touching env vars.
config :app, :sheets_shared_secret, "test-shared-secret"

# Route every App.Google.Sheets request through a Req.Test stub instead of
# the real Sheets API — see test/app/google/sheets_test.exs.
config :app,
  sheets_req_options: [plug: {Req.Test, App.Google.Sheets}],
  token_signing_secret: "5WjHKxyerg+cBwgkjY8qeHm3k9SncrHx",
  google_client_id: "test-client-id",
  google_client_secret: "test-client-secret",
  # Trailing "/" and the router's "/auth" prefix both required — see
  # config/dev.exs's comment.
  google_redirect_uri: "http://localhost:4002/auth/"

# IHDS answers from the real seed files through a plug
# (test/support/ihds_stub.ex), so pages show real country names in tests.
config :app, ihds_req_options: [plug: App.IHDSStub], ihds_learn_async: false

# File storage: an in-memory S3 stand-in (test/support/storage_stub.ex).
config :app, :storage,
  bucket: "hrda-files",
  endpoint: "http://storage.test",
  public_url: "https://files.test",
  access_key: "test",
  secret_key: "test-secret",
  region: "us-east-1"

config :app, :storage_request_options, http_client: App.StorageStub

# Encryption at rest (App.Vault). A fixed throwaway key: data encrypted
# with it is test fixtures, never real. Production uses CLOAK_KEY
# (config/runtime.exs).
config :app, App.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("oBjoR4dy5Hx8nzst5iR3FVikg2A23EmZI20yI9wC/sA="),
       iv_length: 12}
  ]

# Typst renders printed documents (App.Documents.Pdf): TYPST_PATH, the
# PATH, or ~/.local/bin (docs/design/documents-core.md).
config :app,
  typst_path:
    System.get_env("TYPST_PATH") || System.find_executable("typst") ||
      Path.expand("~/.local/bin/typst")

# System settings are read from the database in every test (no cache that
# would outlive a test's sandbox transaction).
config :app, :settings_cache, false

# Notifications (App.Notify): no RabbitMQ in tests; Apprise is a Req.Test
# stub and the channels have throwaway sender URLs.
config :app, App.Notify,
  req_plug: {Req.Test, App.Notify.Apprise},
  apprise_url: "http://apprise.test",
  app_url: "https://hrda.test",
  channels: %{
    email: "mailtos://sender:secret@smtp.test?from=noreply@hrda.test",
    telegram: "tgram://123456:TESTTOKEN"
  }

# docs/design/inbox-first.md: tests call App.Documents.Reminders.run/1 directly.
config :app, App.Documents.Reminders, enabled: false
