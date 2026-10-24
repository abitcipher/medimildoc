defmodule Mix.Tasks.App.MigrateRecords do
  @shortdoc "Upgrades person records to their kinds' current schema versions"
  @moduledoc """
  See `RecordMigrations.migrate_all/0`. Releases run this
  automatically after migrations (`App.Release.migrate/0`).
  """
  use Mix.Task

  alias App.People.RecordMigrations

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    Logger.configure(level: :info)
    Mix.shell().info("Upgraded: #{inspect(RecordMigrations.migrate_all())}")
  end
end
