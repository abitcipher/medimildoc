defmodule App.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :app

  alias App.Demo.Export
  alias App.Documents.Backfill
  alias App.People.{RecordDates, RecordMigrations}
  alias App.Rules.{Library, Reference}
  alias App.Search.Digest

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    migrate_records()
    backfill_search_digests()
    backfill_record_dates()
    backfill_document_recipients()
    sync_rules()
    ensure_storage()
  end

  @doc "Adds the shipped FSDC rule sets not yet in the database (`App.Rules.Library`)."
  def sync_rules do
    start_app()
    added = Library.sync()
    if added > 0, do: IO.puts("Rule sets added: #{added}")
  end

  @doc """
  Checks the rules against the reference dataset (`App.Rules.Reference`)
  after a deployment. Needs the synthetic data seeded with the reference's
  seed and size (`seed_demo/1` with the defaults). Read-only.

      bin/app eval "App.Release.verify_rules()"
  """
  def verify_rules do
    start_app()

    case Reference.verify() do
      {:ok, %{missing: [], unexpected: []} = result} ->
        IO.puts("Reference check passed: #{result.checked} checked, #{result.expected} expected")

      {:ok, result} ->
        IO.puts("Reference check FAILED: #{inspect(result, pretty: true)}")

      {:error, :not_seeded} ->
        IO.puts("Synthetic data is not the reference set; run App.Release.seed_demo() first")
    end
  end

  @doc "Fills search hashes of identifiers written before they existed (`App.Search.Digest`)."
  def backfill_search_digests do
    start_app()
    count = Digest.backfill()
    if count > 0, do: IO.puts("Search hashes filled: #{count}")
  end

  @doc "Fills the plain dates of person records saved before they existed (`App.People.RecordDates`)."
  def backfill_record_dates do
    start_app()
    count = RecordDates.backfill()
    if count > 0, do: IO.puts("Record dates filled: #{count}")
  end

  @doc "Fills the plain recipient of documents saved before it existed (`App.Documents.Backfill`)."
  def backfill_document_recipients do
    start_app()
    count = Backfill.recipients()
    if count > 0, do: IO.puts("Document recipients filled: #{count}")
  end

  @doc "Creates the file storage bucket if it doesn't exist (idempotent)."
  def ensure_storage do
    start_app()

    case App.Storage.ensure_bucket() do
      :ok -> :ok
      {:error, reason} -> IO.puts("File storage not ready: #{inspect(reason)}")
    end
  end

  @doc """
  Upgrades person records to their kinds' current schema versions
  (`App.People.RecordMigrations`). Runs after every `migrate/0`; does
  nothing when all records are current.
  """
  def migrate_records do
    start_app()
    counts = RecordMigrations.migrate_all()
    if counts != %{}, do: IO.puts("Upgraded records: #{inspect(counts)}")
  end

  @doc """
  After a key rotation (infra/README.md): re-encrypts every encrypted field
  under the new default key.

      bin/app eval "App.Release.reencrypt_all()"
  """
  def reencrypt_all do
    start_app()
    IO.puts("Re-encrypted: #{inspect(App.Encryption.reencrypt_all())}")
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Replaces synthetic test data (`App.Demo.seed/1`) in a release:

      bin/app eval "App.Release.seed_demo()"
      bin/app eval "App.Release.seed_demo(people: 300, seed: 2)"
  """
  def seed_demo(opts \\ []) do
    start_app()
    {:ok, counts} = App.Demo.seed(opts)
    IO.puts("Synthetic data created: #{inspect(Map.delete(counts, :planted))}")
  end

  @doc """
  Writes the synthetic data to JSON files in `dir` (`App.Demo.Export`):

      bin/app eval "App.Release.export_demo(\"/tmp/demo-export\")"
  """
  def export_demo(dir) do
    start_app()
    {:ok, counts} = Export.write(dir)
    IO.puts("Synthetic data written to #{dir}: #{inspect(counts)}")
  end

  @doc """
  Removes synthetic test data and demo users (`App.Demo.purge/0`):

      bin/app eval "App.Release.purge_demo()"
  """
  def purge_demo do
    start_app()
    {:ok, counts} = App.Demo.purge()
    IO.puts("Synthetic data removed: #{inspect(counts)}")
  end

  # Seeding and encryption go through Ash actions and the vault, so they
  # need the application, not just the repo migrations use. The HTTP
  # endpoint stays off: these run via `bin/app eval` next to (or right
  # before) the real server, and PHX_SERVER=true would otherwise make this
  # second VM try to bind the same port.
  defp start_app do
    load_app()
    endpoint = Application.get_env(@app, AppWeb.Endpoint, [])
    Application.put_env(@app, AppWeb.Endpoint, Keyword.put(endpoint, :server, false))
    # Nor the notification workers: the running server has them.
    notify = Application.get_env(@app, App.Notify, [])
    Application.put_env(@app, App.Notify, Keyword.put(notify, :workers, false))
    Application.put_env(@app, App.Documents.Reminders, enabled: false)
    {:ok, _} = Application.ensure_all_started(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
