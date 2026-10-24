defmodule Mix.Tasks.App.Demo.Seed do
  @shortdoc "Replaces synthetic test data (people, records, demo users)"
  @moduledoc """
  Replaces all synthetic data with a fresh, repeatable set — see
  `App.Demo`.

      mix app.demo.seed
      mix app.demo.seed --people 300 --seed 2

  Demo users (`<role or profile>@demo.test`) appear on `/dev/sign-in`.
  In a release use `bin/app eval "App.Release.seed_demo()"`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [people: :integer, seed: :integer])
    Logger.configure(level: :info)

    {:ok, counts} = App.Demo.seed(opts)
    Mix.shell().info("Synthetic data created: #{inspect(Map.delete(counts, :planted))}")
  end
end
