defmodule Mix.Tasks.App.Rules.Reference do
  @shortdoc "Reseeds synthetic data and rewrites the FSDC reference labels"
  @moduledoc """
  Replaces the synthetic data (`App.Demo.seed/1`, default 150 people,
  seed 1) and writes the labels of its deliberately invalid records to
  `priv/reference/rules.json` (`App.Rules.Reference`), then verifies them
  against the rules (shipped rules synced first). Run after changing the generator or adding a rule;
  commit the file.

      mix app.rules.reference
      mix app.rules.reference --people 300 --seed 2
  """
  use Mix.Task

  alias App.Rules.{Library, Reference}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [people: :integer, seed: :integer])
    opts = Keyword.merge([people: 150, seed: 1], opts)
    Logger.configure(level: :info)

    Library.sync()
    {:ok, counts} = App.Demo.seed(opts)
    reference = Reference.build(opts, counts)
    File.write!(Reference.source_path(), Jason.encode!(reference, pretty: true) <> "\n")

    Mix.shell().info(
      "#{reference["invalid"]} invalid of #{reference["items"]} records and assignments " <>
        "(#{Float.round(100 * reference["invalid"] / reference["items"], 1)} %) " <>
        "written to #{Reference.source_path()}"
    )

    {:ok, result} = Reference.verify(reference)
    Mix.shell().info("Verified: #{inspect(Map.take(result, [:checked, :missing, :unexpected]))}")
  end
end
