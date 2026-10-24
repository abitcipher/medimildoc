defmodule Mix.Tasks.App.Reencrypt do
  @shortdoc "Re-encrypts every encrypted field under the current default key"
  @moduledoc """
  After a key rotation — see `App.Encryption.reencrypt_all/0` and
  `infra/README.md`. In a release: `bin/app eval "App.Release.reencrypt_all()"`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    Logger.configure(level: :info)
    Mix.shell().info("Re-encrypted: #{inspect(App.Encryption.reencrypt_all())}")
  end
end
