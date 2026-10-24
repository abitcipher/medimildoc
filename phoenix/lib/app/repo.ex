defmodule App.Repo do
  use AshPostgres.Repo, otp_app: :app

  # AshPostgres extensions available to resources via `postgres do extensions [...] end`.
  def installed_extensions, do: ["ash-functions", "uuid-ossp", "pg_trgm", "citext"]

  # Postgres 18+ (infra/docker-compose.yml runs 18) per the "use latest
  # stable" decision — not because Ash relies on PG18's native uuidv7():
  # uuid_v7_primary_key generates app-side (Ash.UUIDv7.generate/0), so the
  # column is a plain `uuid` either way. See phoenix/README.md.
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
