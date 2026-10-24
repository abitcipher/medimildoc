defmodule Mix.Tasks.App.Demo.Export do
  @shortdoc "Writes the synthetic data to JSON files"
  @moduledoc """
  Writes the synthetic data (`App.Demo`) to JSON files, one per table —
  see `App.Demo.Export`.

      mix app.demo.export /tmp/demo-export

  In a release: `bin/app eval "App.Release.export_demo(\\"/tmp/demo-export\\")"`.
  """
  use Mix.Task

  alias App.Demo.Export

  @requirements ["app.start"]

  @impl Mix.Task
  def run([dir]) do
    {:ok, counts} = Export.write(dir)
    Mix.shell().info("Synthetic data written to #{dir}: #{inspect(counts)}")
  end

  def run(_args), do: Mix.raise("usage: mix app.demo.export DIR")
end
