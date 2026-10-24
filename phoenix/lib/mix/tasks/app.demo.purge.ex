defmodule Mix.Tasks.App.Demo.Purge do
  @shortdoc "Removes synthetic test data and demo users"
  @moduledoc """
  Removes everything `mix app.demo.seed` created — see `App.Demo.purge/0`.
  Audit trails are kept.

      mix app.demo.purge
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    Logger.configure(level: :info)
    {:ok, counts} = App.Demo.purge()
    Mix.shell().info("Synthetic data removed: #{inspect(counts)}")
  end
end
