# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cinder, default_theme: AppWeb.Cinder.Theme

# every Cinder.collection's filter panel collapses to a
# single icon/header by default, expanding into an inline panel on click
# (Cinder's own built-in :toggle filter_mode — a real "collapsible ->
# flyout" pattern already, not something hand-built). :toggle_open would
# start expanded instead; not chosen, since the whole point here is a
# minimal default footprint per the user's brief.
config :cinder, show_filters: :toggle

# fixes the person_id filter's known rough edge
# (dash-formatted input didn't match the raw stored value). A keyword
# list, not the map Cinder's own README example shows: `Cinder.setup/0`
# calls `Keyword.keys/1` on this same config value, which raises on a
# map — confirmed by reading its source, not guessed; a keyword list
# works with both that and `Cinder.Filters.Registry`'s own `Enum.into/2`
# read of it.
config :cinder, :filters, person_id: AppWeb.Cinder.Filters.PersonId

config :daisy_ui_components, translate_function: &AppWeb.CoreComponents.translate_error/1

config :spark,
  formatter: ["Ash.Resource": [section_order: [:authentication, :token, :user_identity]]]

config :app,
  ecto_repos: [App.Repo],
  ash_domains: [
    App.Accounts,
    App.People,
    App.Audit,
    App.Events,
    App.Documents,
    App.Rules,
    App.Settings,
    App.Care,
    App.Notify,
    App.Api,
    App.Records,
    App.Duty
  ],
  # Local times in records (clinical forms) are in this zone; the FHIR API
  # gives them with their offset (App.Fhir.Map). APP_TIME_ZONE in runtime.
  app_time_zone: "Europe/Kyiv",
  # Printed documents take their words from the web layer's translations
  # (App.Documents.Labels; the domain never imports the web layer).
  document_labels: AppWeb.DocumentLabels,
  generators: [timestamp_type: :utc_datetime]

# Required by Ash for :string min_length/max_length constraints. Counts
# unicode codepoints, matching how Postgres counts string length, so
# max_length actually bounds stored value size everywhere consistently.
config :ash, default_string_length_count: :codepoints

# Configure the endpoint
config :app, AppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AppWeb.ErrorHTML, json: AppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: App.PubSub,
  live_view: [signing_salt: "XunQOkAc"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :app, App.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # The org graph's Cytoscape module (docs/design/org-graph.md), an ES module
  # the OrgGraph hook imports only on that page.
  org_graph: [
    args:
      ~w(js/org_graph.js --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  app: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# docs/design/access-control-phase1.md : while true, role :admin holds
# every permission (development and testing). Production reads
# ADMIN_FULL_DATA_ACCESS in config/runtime.exs instead.
config :app, :admin_full_data_access, true

# Lets runtime code tell which environment the release was built for
# (Mix.env/0 isn't available inside a release).
config :app, :env, config_env()

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# DICOM (CT/MRI/X-ray) uploads: `.dcm` needs a MIME type for LiveView's
# upload filter. The mime library compiles this in: after changing it run
# `mix deps.compile mime --force`.
config :mime, :types, %{"application/dicom" => ["dcm"]}

# File storage (App.Storage): RustFS through its S3 API, with Req.
config :ex_aws, http_client: ExAws.Request.Req, json_codec: Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
