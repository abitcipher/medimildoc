defmodule App.MixProject do
  use Mix.Project

  def project do
    [
      app: :app,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {App.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      # Notifications (docs/design/search-timeline-notifications.md): RabbitMQ
      # carries outbox messages to the dispatcher; Broadway gives the consumer
      # acknowledgements, concurrency and back-pressure; AMQP publishes.
      {:broadway_rabbitmq, "~> 0.8"},
      {:amqp, "~> 4.2"},
      # FHIR API (docs/design/fhir-api.md): clinical times are stored as local
      # time; FHIR needs them with their UTC offset. IANA data compiled in,
      # no runtime downloads.
      {:tz, "~> 0.28"},
      # FHIR API phase 2: verifying external systems' signed JWTs (SMART
      # backend services). Already present through ash_authentication.
      {:jose, "~> 1.11"},
      # File storage in RustFS (S3 API): docs/design/reference-data-and-files.md.
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      # Offline .xlsx import/export (docs/design/assignments-sheets.md);
      # Rust NIF, precompiled (downloaded at compile time).
      {:umya_spreadsheet_ex, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Required by ("mix credo --strict и mix dialyzer");
      # not part of the phx.new default generator.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      # M3: the domain layer (people, orgs,
      # positions, assignments, extensible records) — resource-oriented per
      # explicit stack choice, not hand-rolled Ecto contexts.
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      # SAT solver Ash.Policy.Authorizer needs at compile time to verify
      # policies are satisfiable (every resource here has a policies block).
      {:picosat_elixir, "~> 0.2"},
      # Auth for the standalone forms UI (/people, /organizations,
      # /positions) — Google OAuth per the user's decision. Ash-native
      # (works directly with our actor/Ash.Policy.Authorizer model, unlike
      # e.g. hand-rolled ueberauth) and issues JWTs by default (via Joken),
      # which the user asked for explicitly with a future Envoy+OPA-style
      # gateway in mind — see App.Accounts' moduledoc. Pinned to the latest
      # *stable* releases, not the 5.0/3.0 release-candidate series
      # currently ahead of them on Hex.
      {:ash_authentication, "~> 4.14"},
      # Encryption at rest for sensitive fields (docs/design/
      # access-control-phase1.md): AshCloak is the Ash-native wrapper
      # (supports Ash ~> 3.26; we run 3.33), Cloak provides the vault and
      # AES-256-GCM cipher.
      {:ash_cloak, "~> 0.4"},
      # Document lifecycles (draft → in review → signed / cancelled,
      # docs/design/documents-core.md): Ash's own state machine extension
      # declares allowed transitions on the resource and rejects others,
      # instead of hand-written state checks in every action.
      {:ash_state_machine, "~> 0.2"},
      # FSDC rules engine (docs/design/data-consistency.md): GoRules ZEN
      # (MIT, Rust) in-process as a NIF, native/rules. Rustler builds it in
      # dev and test; the image loads a library prebuilt in its own
      # Dockerfile stage (RULES_NIF_PREBUILT=1).
      {:rustler, "~> 0.36.2", runtime: false},
      {:cloak, "~> 1.1"},
      {:ash_authentication_phoenix, "~> 2.17"},
      # Optional dep of ash_authentication, not pulled in transitively —
      # needed to run its `mix ash_authentication.install`/`add_strategy`
      # generators. Dev/test only; not needed at runtime.
      {:igniter, "~> 0.4", only: [:dev, :test]},
      # Validates App.People.PersonRecord's JSONB `data` against its kind's
      # JSON Schema (JSON Schema is mandatory for every data
      # type) — chosen over json_forms_lv/gleam-fhir per the user's M3-start
      # decision: those are unpublished/cross-language, not worth the risk
      # yet; this is a mature, widely-used, Hex-published validator.
      {:ex_json_schema, "~> 0.11"},
      # UI-kit adoption — verified real/active on hex.pm
      # before adding: Ash-native data table (sort/filter/
      # pagination "for free" on the list-type LiveViews, which are all
      # hand-rolled <table>s right now) and a thin wrapper over the
      # daisyUI classes already used ad-hoc everywhere.
      {:cinder, "~> 0.17"},
      {:daisy_ui_components, "~> 0.9"},
      # User's explicitly preferred Elixir UI kit. Dev-only
      # (Mishka's own docs: "you will only use this library in your
      # development environment... no presence in production") — it's a
      # code generator (`mix mishka.ui.gen.component`), not a runtime
      # dependency: components get copied into lib/ as owned .heex/.ex,
      # same trust model as the hand-written CoreComponents it's
      # replacing, not a black-box library call.
      {:mishka_chelekom, "~> 0.0.9", only: :dev}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind app", "esbuild app", "esbuild org_graph"],
      "assets.deploy": [
        "tailwind app --minify",
        "esbuild app --minify",
        "esbuild org_graph --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
